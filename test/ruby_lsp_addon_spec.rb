# frozen_string_literal: true

require "ruby_lsp/internal"
require "ruby_lsp/test_helper"
require "ruby_lsp/flexr/addon"
require "open3"

RSpec.describe "Ruby LSP flexr add-on" do
  include RubyLsp::TestHelper

  def diagnostics(server, uri, id: 1)
    server.process_message(id: id, method: "textDocument/diagnostic", params: { textDocument: { uri: uri } })
    messages = []
    result = server.pop_response
    until result.is_a?(RubyLsp::Result)
      messages << result.inspect
      result = server.pop_response
    end
    expect(result.response).not_to be_nil, messages.join("\n")
    result.response.items
  end

  def open_server(source, path: "unsaved.flexr.rb", encodings: nil, &block)
    uri = URI::Generic.from_path(path: File.join(Dir.pwd, path))
    with_server(source.dup, uri, load_addons: false) do |server, opened_uri|
      server.global_state.apply_options(initializationOptions: { linters: ["flexr"] },
                                        capabilities: { general: { positionEncodings: encodings } })
      addon = RubyLsp::Flexr::Addon.new
      addon.activate(server.global_state, Queue.new)
      RubyLsp::Addon.addons << addon
      begin
        block.call(server, opened_uri)
      ensure
        RubyLsp::Addon.addons.delete(addon)
        addon.deactivate
      end
    end
  end

  { "utf-8" => 18, "utf-32" => 15 }.each do |encoding, column|
    it "uses negotiated #{encoding} positions" do
      source = "class EditorLexer < Flexr::Lexer\n  label = '😀'; rule(/a(?=b)/, skip: true)\nend\n"
      open_server(source, encodings: [encoding]) do |server, uri|
        diagnostic = diagnostics(server, uri).find { |item| item.to_hash[:code] == "FLEXR-E014" }
        expect(diagnostic.range.start.to_hash).to eq(line: 1, character: column)
      end
    end
  end

  it "reports warnings from unsaved source with UTF-16 positions and CRLF" do
    source = "class EditorLexer < Flexr::Lexer\r\n  emits :WORD, :IF\r\n  rule(/[a-z]+/, emit: :WORD)\r\n  label = '😀'; rule(/if/, emit: :IF)\r\nend\r\n"
    open_server(source) do |server, uri|
      diagnostic = diagnostics(server, uri).find { |item| item.to_hash[:code] == "FLEXR-W001" }
      expect(diagnostic.source).to eq("flexr")
      expect(diagnostic.severity).to eq(RubyLsp::Constant::DiagnosticSeverity::WARNING)
      expect(diagnostic.range.start.to_hash).to eq(line: 3, character: 16)
      expect(diagnostic.message).to include("unreachable", "example:", '"if"')
    end
  end

  it "refreshes errors after unsaved edits and clears them when fixed" do
    source = "class EditorLexer < Flexr::Lexer\n  rule(/a(?=b)/, skip: true)\nend\n"
    open_server(source) do |server, uri|
      expect(diagnostics(server, uri).map(&:code)).to include("FLEXR-E014")
      server.process_message(method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [{ range: { start: { line: 0, character: 0 }, end: { line: 3, character: 0 } },
                           text: source.sub("a(?=b)", "ab") }]
      })
      expect(server.instance_variable_get(:@store).get(uri).source).to include("rule(/ab/")
      expect(diagnostics(server, uri, id: 2).map(&:code)).not_to include("FLEXR-E014")
    end
  end

  it "reports invalid configuration repeatedly and recovers after a fixing edit" do
    source = "class EditorLexer < Flexr::Lexer\n  backend :bogus\n  rule(/a/, skip: true)\nend\n"
    open_server(source) do |server, uri|
      [1, 2].each do |id|
        error = diagnostics(server, uri, id: id).find { |item| item.to_hash[:code] == "FLEXR-E017" }
        expect(error.message).to include("unsupported backend", "bogus")
        expect(error.range.start.to_hash).to eq(line: 0, character: 0)
      end
      server.process_message(method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [{ range: { start: { line: 0, character: 0 }, end: { line: 4, character: 0 } }, text: source }]
      })
      expect(diagnostics(server, uri, id: 3).map(&:code)).to include("FLEXR-E017")

      server.process_message(method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 3 },
        contentChanges: [{ range: { start: { line: 0, character: 0 }, end: { line: 4, character: 0 } },
                           text: source.sub(":bogus", ":table") }]
      })
      expect(diagnostics(server, uri, id: 4).map(&:code)).not_to include("FLEXR-E017")
    end
  end

  it "shows counterexamples and overlap information on rule hover without a diagnostics request" do
    source = "class EditorLexer < Flexr::Lexer\n  emits :WORD, :IF\n  rule(/[a-z]+/, emit: :WORD)\n  rule(/if/, emit: :IF)\nend\n"
    open_server(source) do |server, uri|
      server.process_message(id: 1, method: "textDocument/hover", params: {
        textDocument: { uri: uri }, position: { line: 3, character: 3 }
      })
      response = pop_result(server).response
      expect(response.contents.value).to include("FLEXR-W001", "FLEXR-I001", '"if"')
    end
  end

  it "explains an empty absence language in the rule hover" do
    source = "class EditorLexer < Flexr::Lexer\n  rule(/(?~a?)/, skip: true)\nend\n"
    open_server(source) do |server, uri|
      server.process_message(id: 1, method: "textDocument/hover", params: {
        textDocument: { uri: uri }, position: { line: 1, character: 3 }
      })
      hover = pop_result(server).response
      expect(hover.contents.value).to include("FLEXR-W001", "language is empty")
    end
  end

  it "explains hidden token channels in rule hover without warnings" do
    source = <<~RUBY
      class EditorLexer < Flexr::Lexer
        CHANNEL = :comment
        rule(/#[^\\n]*/, channel: CHANNEL)
      end
    RUBY
    open_server(source) do |server, uri|
      server.process_message(id: 1, method: "textDocument/hover", params: {
        textDocument: { uri: uri }, position: { line: 2, character: 3 }
      })
      hover = pop_result(server).response
      expect(hover&.contents&.value).to include(":comment", "trivia")
    end
  end

  it "describes keyword remapping and identifies invalid spellings on keyword hover" do
    source = <<~RUBY
      class EditorLexer < Flexr::Lexer
        rule(/[a-z]+/, emit: :IDENT)
        keywords %w[if if!], among: :IDENT
      end
    RUBY
    open_server(source) do |server, uri|
      server.process_message(id: 1, method: "textDocument/hover", params: {
        textDocument: { uri: uri }, position: { line: 2, character: 4 }
      })
      hover = pop_result(server).response
      expect(hover.contents.value).to include("Keyword table", "FLEXR-E028", '"if!"')
    end
  end

  it "shows named pattern subtraction with its witness on rule hover" do
    source = <<~RUBY
      class EditorLexer < Flexr::Lexer
        NAME = pattern(/[a-z]+/)
        DIGIT = pattern(/[0-9]/)
        rule(NAME - DIGIT, emit: :NAME)
      end
    RUBY
    open_server(source) do |server, uri|
      server.process_message(id: 1, method: "textDocument/hover", params: {
        textDocument: { uri: uri }, position: { line: 3, character: 3 }
      })
      hover = pop_result(server).response
      expect(hover.contents.value).to include("FLEXR-W021", "NAME", "DIGIT", '"0"')
    end
  end

  it "does not diagnose ordinary Ruby files or execute specification code" do
    source = "raise 'must not execute'\nclass EditorLexer < Flexr::Lexer\n  rule(/a(?=b)/, skip: true)\nend\n"
    open_server(source, path: "ordinary.rb") do |server, uri|
      expect(diagnostics(server, uri).map(&:source)).not_to include("flexr")
    end
    open_server(source) do |server, uri|
      expect(diagnostics(server, uri).map(&:code)).to include("FLEXR-E014")
    end
  end

  it "is discovered and activated by Ruby LSP from the gem load path" do
    Dir.mktmpdir do |directory|
      script = File.join(directory, "discover.rb")
      File.write(script, <<~RUBY)
        require "ruby_lsp/internal"
        server = RubyLsp::Server.new(test_mode: true)
        server.global_state.apply_options(initializationOptions: { linters: ["flexr"] })
        server.load_addons
        puts JSON.generate(RubyLsp::Addon.addons.map { |addon| [addon.name, addon.error?] })
        server.run_shutdown
      RUBY
      output, errors, status = Open3.capture3(RbConfig.ruby, "-Ilib", script, chdir: File.expand_path("..", __dir__))
      expect(status).to be_success, errors
      expect(JSON.parse(output)).to include(["flexr", false])
    end
  end
end
