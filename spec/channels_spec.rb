# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "stringio"

RSpec.describe "token channels" do
  it "hides trivia from the parser and preserves two-item array and yield tokens" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :yield
      rule(/[ \t]+/, channel: :whitespace)
      rule(/#[^\n]*/, channel: :comment)
      rule(/\n+/, channel: :skip)
      rule(/[a-z]+/, emit: :IDENT)
    end

    input = "foo # note\nbar"
    parser = lexer.new(input)
    expect(parser.racc_next_token).to eq([:IDENT, "foo"])
    expect(parser.racc_next_token).to eq([:IDENT, "bar"])
    expect(parser.racc_next_token).to eq([false, "$end"])
    expect(lexer.new(input).each_token.map { |type, value| [type, value] })
      .to eq([[:IDENT, "foo"], [:IDENT, "bar"]])
    expect(lexer.new(input).tokens(channels: :all))
      .to eq([[:IDENT, "foo"], [:whitespace, " "], [:comment, "# note"], [:IDENT, "bar"]])
  end

  it "attaches located trivia to the next structured token including an EOF token" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/#[^\n]*/, channel: :comment) { emit(:NOTE, text) }
      rule(/ +/, channel: :whitespace)
      rule(/\n/, skip: true)
      rule(/[a-z]+/, emit: :IDENT)
      on_eof { emit(:EOF, "") }
    end

    input = "# note\nfoo # tail"
    tokens = lexer.new(input, filename: "trivia.txt").tokens
    expect(tokens.map(&:type)).to eq(%i[IDENT EOF])
    comment = tokens.first.leading_trivia.fetch(0)
    expect([comment.type, comment.channel, comment.value]).to eq([:NOTE, :comment, "# note"])
    expect(comment.location).to have_attributes(filename: "trivia.txt", byte_begin: 0, byte_end: 6, line_begin: 1)
    expect(tokens.first.location).to have_attributes(byte_begin: 7, byte_end: 10, line_begin: 2)
    expect(tokens.first.leading_trivia).to be_frozen
    expect(tokens.first.with(value: "other").leading_trivia).to eq(tokens.first.leading_trivia)
    expect(tokens.last.leading_trivia.map(&:value)).to eq([" ", "# tail"])
    expect(lexer.new(input).tokens(channels: :all).map(&:channel))
      .to eq(%i[comment default whitespace comment default])
  end

  it "returns recovery tokens on the default channel when trivia raises a lexical error" do
    lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/ +/, channel: :whitespace)
      rule("!", channel: :comment) { error!("invalid comment") }
    end

    token = lexer.new(" !", error_mode: :token).next_token
    expect(token).to have_attributes(type: :error, value: "!", channel: :default)
    expect(token.leading_trivia.map(&:value)).to eq([" "])
  end

  it "validates channel names and token collection modes" do
    expect do
      Class.new(Flexr::Lexer) { rule(/a/, channel: "comment") }
    end.to raise_error(Flexr::CompileError, /channel/)
    lexer = Class.new(Flexr::Lexer) { rule(/a/, emit: :A) }
    expect { lexer.new("a").tokens(channels: :unknown) }.to raise_error(ArgumentError, /channels/)
    expect(lexer.new("a").tokens(channels: :all)).to eq([[:A, "a"]])
  end

  it "uses evaluated channels, priorities and action precedence in generated and standalone scanners" do
    source = <<~SPEC
      require "flexr"
      class EvaluatedChannels < Flexr::Lexer
        def self.trivia_channel = :comment
        def self.trivia_priority = 2
        def self.discard_channel = :skip
        def self.skip_comment = true
        def self.note_type = :NOTE
        rule("#", channel: trivia_channel)
        rule(":", channel: trivia_channel) { emit(:COLON, text) }
        rule("!", channel: discard_channel) { raise "discarded action" }
        rule("$", channel: :comment, skip: skip_comment) { raise "discarded action" }
        rule("@", channel: :comment, emit: note_type)
        rule("x", emit: :WORD)
        rule("x", channel: trivia_channel, priority: trivia_priority)
      end
    SPEC
    runner = 'load ARGV.fetch(0); puts JSON.generate(EvaluatedChannels.new("#:@!$x").tokens(channels: :all))'
    Dir.mktmpdir do |directory|
      path = File.join(directory, "evaluated-channels.flexr.rb")
      File.binwrite(path, source)
      expect { Flexr::Generator.new(path).generate }.to raise_error(Flexr::StaticResolutionError)
      [false, true].each do |standalone|
        target = File.join(directory, "evaluated-channels-#{standalone}.rb")
        Flexr::Generator.new(path, output: target, eval_mode: true, options: { standalone: standalone }).generate
        command = [RbConfig.ruby]
        command << "-Ilib" unless standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", runner, target)
        expect(status).to be_success, stderr
        expect(JSON.parse(stdout)).to eq([["comment", "#"], ["COLON", ":"], ["NOTE", "@"], ["comment", "x"]])
      end
    end
  ensure
    Object.send(:remove_const, :EvaluatedChannels) if Object.const_defined?(:EvaluatedChannels, false)
  end

  it "labels hidden rules in explain, DOT and both trace views" do
    source = <<~'SPEC'
      require "flexr"
      class ChannelViews < Flexr::Lexer
        CHANNEL = :comment
        emits :WORD
        rule(/#[^\n]*/, channel: CHANNEL)
        rule(/[a-z]+/, emit: :WORD)
      end
    SPEC
    Dir.mktmpdir do |directory|
      path = File.join(directory, "channels.flexr.rb")
      File.binwrite(path, source)
      [["explain"], ["dot"], ["trace"], ["trace", "--input", "# hi"]].each do |command, *flags|
        output = StringIO.new
        errors = StringIO.new
        expect(Flexr::CLI.run([command, path, *flags], out: output, err: errors)).to eq(0), errors.string
        expect(output.string).to include("channel=:comment")
      end
      output = StringIO.new
      expect(Flexr::CLI.run(["check", path, "--format", "json"], out: output)).to eq(0)
      expect(JSON.parse(output.string)).to be_empty
    end
  end

  it "remaps only default-channel identifiers for runtime, generated and standalone lexers" do
    source = <<~'SPEC'
      require "flexr"
      class ChannelledKeywords < Flexr::Lexer
        IDENT = pattern(/[a-z]+/)
        rule("(") { push :annotation }
        state :annotation do
          rule(")") { pop }
          rule(IDENT, emit: :PLAIN_ANNOTATION)
          rule(IDENT, channel: :comment, emit: :IDENT, priority: 2)
        end
        rule(/\s+/, skip: true)
        rule(IDENT, emit: :IDENT)
        keywords %w[if], among: :IDENT
      end
    SPEC
    runner = <<~RUBY
      load ARGV.fetch(0)
      input = "(if) if"
      all = ChannelledKeywords.new(input).tokens(channels: :all)
      tokens = ChannelledKeywords.new(input).tokens
      parser = ChannelledKeywords.new(input)
      puts JSON.generate([all, tokens, parser.racc_next_token, parser.racc_next_token])
    RUBY
    Dir.mktmpdir do |directory|
      path = File.join(directory, "channel-keywords.flexr.rb")
      generated = File.join(directory, "channel-keywords.generated.rb")
      standalone = File.join(directory, "channel-keywords.standalone.rb")
      File.binwrite(path, source)
      Flexr::Generator.new(path, output: generated).generate
      Flexr::Generator.new(path, output: standalone, options: { standalone: true }).generate

      [path, generated, standalone].each do |file|
        command = [RbConfig.ruby]
        command << "-Ilib" unless file == standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", runner, file)
        expect(status).to be_success, stderr
        keyword = %w[IF if]
        expect(JSON.parse(stdout)).to eq([[%w[IDENT if], keyword], [keyword], keyword, [false, "$end"]])
      end
    end
  end

  it "requires keyword tables to target a default-channel rule" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/[a-z]+/, channel: :comment, emit: :IDENT)
      keywords %w[if], among: :IDENT
    end
    expect { lexer.compile! }.to raise_error(Flexr::CompileError) { |error|
      expect(error.diagnostic.code).to eq("FLEXR-E028")
      expect(error.diagnostic.note).to include('"if"')
    }
  end

  it "allows hidden rules to shadow default-channel keywords" do
    lexer = Class.new(Flexr::Lexer) do
      rule("if", channel: :comment, emit: :IDENT)
      rule(/[a-z]+/, emit: :IDENT)
      keywords %w[if], among: :IDENT
    end
    warning = lexer.compile!.diagnostics.find { |diagnostic| diagnostic.code == "FLEXR-W022" }
    expect(warning&.note).to include('"if"')
  end

  it "excludes hidden literals and identifier rules from keyword grouping suggestions" do
    source = <<~SPEC
      require "flexr"
      class ChannelKeywordGrouping < Flexr::Lexer
        rule("if", emit: :IF)
        rule("end", emit: :END)
        rule(/[a-z]+/, emit: :IDENT)
      end
    SPEC
    Dir.mktmpdir do |directory|
      path = File.join(directory, "channel-keyword-grouping.flexr.rb")
      variants = [source, source.sub("emit: :IF", "channel: :comment, emit: :IF"),
                  source.sub("emit: :IDENT", "channel: :comment, emit: :IDENT")]
      diagnostics = variants.map do |variant|
        File.binwrite(path, variant)
        output = StringIO.new
        expect(Flexr::CLI.run(["check", path, "--format", "json"], out: output)).to eq(0)
        JSON.parse(output.string).map { |diagnostic| diagnostic.fetch("code") }
      end
      expect(diagnostics.first).to include("FLEXR-I003")
      expect(diagnostics.drop(1).flatten).not_to include("FLEXR-I003")
    end
  end

  it "reconstructs generated inputs on runtime, generated and standalone streaming paths" do
    source = <<~'SPEC'
      require "flexr"
      class ChannelRoundTrip < Flexr::Lexer
        token_kind :struct
        rule(/#[^\n]*/, channel: :comment)
        rule(/[ \t\n]+/, channel: :whitespace)
        rule(/[a-z]+|é/, emit: :WORD)
      end
    SPEC
    compare = <<~RUBY
      require "json"
      require "stringio"
      load ARGV.fetch(0)
      inputs = JSON.parse(ARGV.fetch(1))
      result = inputs.map do |input|
        all = ChannelRoundTrip.new(StringIO.new(input), retain_input: false, chunk_size: 1).tokens(channels: :all)
        visible = ChannelRoundTrip.new(StringIO.new(input), retain_input: false, chunk_size: 1).tokens
        [
          all.map { |token| [token.channel, token.value.bytes, token.location.byte_begin, token.location.byte_end] },
          visible.map { |token| [token.value.bytes, token.leading_trivia.map { |item| item.value.bytes }] }
        ]
      end
      puts JSON.generate(result)
    RUBY
    random = Random.new(31)
    substrings = ["ab", " c ", "é\t", "# note\n", "\n", " # é\n"].freeze
    inputs = ["", "# trailing é"] + Array.new(16) { Array.new(10) { substrings.sample(random: random) }.join }

    Dir.mktmpdir do |directory|
      spec = File.join(directory, "channel.flexr.rb")
      generated = File.join(directory, "channel.generated.rb")
      standalone = File.join(directory, "channel.standalone.rb")
      File.binwrite(spec, source)
      Flexr::Generator.new(spec, output: generated).generate
      Flexr::Generator.new(spec, output: standalone, options: { standalone: true }).generate

      outcomes = [spec, generated, standalone].map do |path|
        command = [RbConfig.ruby]
        command.push("-I", File.expand_path("../lib", __dir__)) unless path == standalone
        stdout, stderr, status = Open3.capture3(*command, "-e", compare, path, JSON.generate(inputs))
        expect(status).to be_success, stderr
        JSON.parse(stdout)
      end
      expect(outcomes.uniq.length).to eq(1)
      bytes = outcomes.first.map { |all, _visible| all.flat_map { |token| token.fetch(1) } }
      expect(bytes).to eq(inputs.map(&:bytes))
      outcomes.first.each do |all, visible|
        expect(visible.map(&:first)).to eq(all.select { |token| token.first == "default" }.map { |token| token.fetch(1) })
      end
    end
  end
end
