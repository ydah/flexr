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
      source = "class EditorLexer < Flexr::Lexer\n  label = '😀'; rule(/(a)\\1/, skip: true)\nend\n"
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

  it "offers the CLI capture edit through textDocument/codeAction" do
    source = "class EditorLexer < Flexr::Lexer\r\n  rule(/😀(a)/, emit: :A)\r\nend\r\n"
    open_server(source) do |server, uri|
      diagnostic = diagnostics(server, uri).find { |item| item.code == "FLEXR-W013" }
      expect(diagnostic).not_to be_nil
      position = { line: 1, character: 11 }
      server.process_message(id: 2, method: "textDocument/codeAction", params: {
        textDocument: { uri: uri }, range: { start: position, end: position },
        context: { diagnostics: [JSON.parse(diagnostic.to_json, symbolize_names: true)] }
      })
      action = pop_result(server).response.find { |entry| entry[:kind] == "quickfix" }
      expect(action).to include(
        title: "Use non-capturing groups",
        edit: { documentChanges: [{
          textDocument: { uri: uri.to_s, version: 1 },
          edits: [{ range: { start: position, end: position }, newText: "?:" }]
        }] }
      )
    end
  end

  it "refreshes errors after unsaved edits and clears them when fixed" do
    source = "class EditorLexer < Flexr::Lexer\n  rule(/(a)\\1/, skip: true)\nend\n"
    open_server(source) do |server, uri|
      expect(diagnostics(server, uri).map(&:code)).to include("FLEXR-E014")
      server.process_message(method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [{ range: { start: { line: 0, character: 0 }, end: { line: 3, character: 0 } },
                           text: source.sub("(a)\\1", "a(?=b)") }]
      })
      expect(server.instance_variable_get(:@store).get(uri).source).to include("rule(/a(?=b)/")
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

  it "explains priority and a trivia channel on the same rule hover" do
    source = "class EditorLexer < Flexr::Lexer\n  rule(\"if\", emit: :IF, channel: :comment, priority: 10)\nend\n"
    open_server(source) do |server, uri|
      server.process_message(id: 1, method: "textDocument/hover", params: {
        textDocument: { uri: uri }, position: { line: 1, character: 3 }
      })
      value = pop_result(server).response.contents.value
      expect(value).to include("priority 10", "equal-length matches", ":comment", "trivia")
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
    source = "raise 'must not execute'\nclass EditorLexer < Flexr::Lexer\n  rule(/(a)\\1/, skip: true)\nend\n"
    open_server(source, path: "ordinary.rb") do |server, uri|
      expect(diagnostics(server, uri).map(&:source)).not_to include("flexr")
    end
    open_server(source) do |server, uri|
      expect(diagnostics(server, uri).map(&:code)).to include("FLEXR-E014")
    end
  end

  def editor_request(server, uri, method, position: nil)
    params = { textDocument: { uri: uri } }
    params[:position] = position if position
    server.process_message(id: 20, method: "textDocument/#{method}", params: params)
    pop_result(server).response
  end

  { "utf-8" => 22, "utf-16" => 20, "utf-32" => 19 }.each do |encoding, column|
    it "jumps from an action to the unsaved state declaration in #{encoding}" do
      source = "class EditorLexer < Flexr::Lexer\r\n  tag = '😀'; state :quoted do\r\n    rule(/q/, skip: true)\r\n  end\r\n" \
        "  rule(/x/) { push :quoted }\r\nend\r\n"
      open_server(source, encodings: [encoding]) do |server, uri|
        definition = editor_request(server, uri, "definition", position: { line: 4, character: 21 })
        locations = JSON.parse(JSON.generate(definition), symbolize_names: true)
        expect(locations).to include(uri: uri.to_s, range: { start: { line: 1, character: column },
                                                              end: { line: 1, character: column + 7 } })
      end
    end
  end

  it "links a quoted state name through self.state= and scopes it to the lexer" do
    source = <<~RUBY
      class Unrelated
        state "quoted" do
        end
      end
      class EditorLexer < Flexr::Lexer
        state :outer, "quoted" do
          rule(/x/, skip: true)
        end
        rule(/y/) { self.state = "quoted" }
      end
    RUBY
    open_server(source) do |server, uri|
      result = editor_request(server, uri, "definition", position: { line: 8, character: 28 })
      expect(JSON.parse(JSON.generate(result), symbolize_names: true)).to include(
        uri: uri.to_s, range: { start: { line: 5, character: 16 }, end: { line: 5, character: 24 } }
      )
    end
    open_server(source, path: "ordinary.rb") do |server, uri|
      result = editor_request(server, uri, "definition", position: { line: 8, character: 28 })
      expect(result).to be_empty
    end
  end

  { "utf-8" => 33, "utf-16" => 31, "utf-32" => 30 }.each do |encoding, column|
    it "completes emit with an exact #{encoding} replacement" do
      source = "class EditorLexer < Flexr::Lexer\n  emits :WORD, :WIDTH, :STRING\n" \
        "  rule(/x/) { tag = '😀'; emit :WI }\nend\n"
      open_server(source, encodings: [encoding]) do |server, uri|
        choices = editor_request(server, uri, "completion", position: { line: 2, character: column + 3 })
        items = choices.select { |choice| choice.label.start_with?(":") }
        tokens = JSON.parse(JSON.generate(items), symbolize_names: true)
        expect(tokens).to match([a_hash_including(
          label: ":WIDTH", textEdit: { range: { start: { line: 2, character: column },
                                               end: { line: 2, character: column + 3 } }, newText: ":WIDTH" }
        )])
      end
    end
  end

  it "completes a bare colon after an unfinished action emit" do
    source = "class EditorLexer < Flexr::Lexer\n  emits :WORD\n  rule(/x/) do\n    emit :\n  end\nend\n"
    open_server(source) do |server, uri|
      choices = editor_request(server, uri, "completion", position: { line: 3, character: 10 })
      expect(choices.map(&:label)).to include(":WORD")
      choice = choices.find { |item| item.label == ":WORD" }
      expect(choice.text_edit.range.start.to_hash).to eq(line: 3, character: 9)
      expect(choice.text_edit.range.end.to_hash).to eq(line: 3, character: 10)
    end
  end

  it "leaves ordinary emit calls alone" do
    source = "class EditorLexer < Flexr::Lexer\n  emits :WORD\n  rule(/x/) { logger.emit :WO }\n" \
      "  def helper; emit :WO; end\nend\n"
    open_server(source) do |server, uri|
      expect(editor_request(server, uri, "completion", position: { line: 2, character: 29 }).map(&:label)).not_to include(":WORD")
      expect(editor_request(server, uri, "completion", position: { line: 3, character: 22 }).map(&:label)).not_to include(":WORD")
    end
    open_server(source.sub("logger.emit", "emit"), path: "ordinary.rb") do |server, uri|
      expect(editor_request(server, uri, "completion", position: { line: 2, character: 23 }).map(&:label)).not_to include(":WORD")
    end
  end

  it "offers literal token declarations and keeps ambiguous value arguments unchanged" do
    source = <<~RUBY
      class EditorLexer < Flexr::Lexer
        emits [:WORD, "WIDTH"]
        keywords %w[while], among: :WORD
        rule("a", emit: :WEIGHT)
        rule(/x/) { emit :W, text }
        rule(/y/) { emit :W, 123 }
      end
    RUBY

    open_server(source) do |server, uri|
      choices = editor_request(server, uri, "completion", position: { line: 4, character: 20 })
      expect(choices.map(&:label).grep(/\A:/)).to contain_exactly(":WEIGHT", ":WHILE", ":WIDTH", ":WORD")
      arguments = editor_request(server, uri, "completion", position: { line: 5, character: 25 })
      expect(arguments.map(&:label).grep(/\A:/)).to be_empty
    end
  end

  it "offers token names for a bare symbol in an incomplete shorthand rule" do
    source = "class EditorLexer < Flexr::Lexer\n  emits :WORD, :NUMBER\n  rule(/x/, emit: :)\nend\n"
    open_server(source) do |server, uri|
      result = editor_request(server, uri, "completion", position: { line: 2, character: 18 })
      expect(result.map(&:label)).to include(":WORD", ":NUMBER")
    end
  end

  it "outlines state blocks and rules in the current unsaved DSL tree" do
    source = <<~RUBY
      raise "specification code must never run"
      class EditorLexer < Flexr::Lexer
        rule(/a/, emit: :A)
        state :quoted do
          rule(/q/, emit: :Q)
          unrelated.rule(/ignored/)
        end
        def helper
          rule(/inside_method/)
        end
      end
    RUBY
    open_server(source) do |server, uri|
      symbols = JSON.parse(JSON.generate(editor_request(server, uri, "documentSymbol")))
      lexer = symbols.find { |symbol| symbol.fetch("name") == "EditorLexer" }
      children = lexer.fetch("children")
      expect(children.map { |symbol| symbol.fetch("name") }).to eq(["rule /a/", "state :quoted", "helper"])
      state = children.find { |symbol| symbol.fetch("name") == "state :quoted" }
      expect(state.fetch("selectionRange").fetch("start")).to eq("line" => 3, "character" => 8)
      expect(state.fetch("children").map { |child| child.fetch("name") }).to eq(["rule /q/"])
      server.process_message(method: "textDocument/didChange", params: {
        textDocument: { uri: uri, version: 2 },
        contentChanges: [{
          range: { start: { line: 3, character: 8 }, end: { line: 3, character: 15 } },
          text: ":replacement"
        }]
      })
      # The server reparses edited documents in its read loop before process_message.
      server.instance_variable_get(:@store).get(uri).parse!
      updated = JSON.parse(JSON.generate(editor_request(server, uri, "documentSymbol")))
      lexer = updated.find { |symbol| symbol.fetch("name") == "EditorLexer" }
      expect(lexer.fetch("children").map { |symbol| symbol.fetch("name") }).to include("state :replacement")
    end
    open_server(source, path: "ordinary.rb") do |server, uri|
      symbols = JSON.parse(JSON.generate(editor_request(server, uri, "documentSymbol")))
      lexer = symbols.find { |symbol| symbol.fetch("name") == "EditorLexer" }
      expect(lexer.fetch("children").map { |symbol| symbol.fetch("name") }).to eq(["helper"])
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
