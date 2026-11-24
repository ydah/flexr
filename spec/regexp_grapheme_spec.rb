# frozen_string_literal: true

require "open3"
require "stringio"

RSpec.describe "regexp grapheme clusters" do
  it "matches every extended cluster in the Unicode 15.1 grapheme break test" do
    fixture = File.join(__dir__, "fixtures/grapheme_break_test_15_1_0.txt")
    cases = File.foreach(fixture, encoding: "UTF-8").with_index(1).filter_map do |line, lineno|
      specification = line.split("#", 2).first.strip
      next if specification.empty?

      clusters = specification.split("÷").filter_map do |cluster|
        points = cluster.split.reject { |token| token == "×" }
        points.map { |point| Integer(point, 16) }.pack("U*") unless points.empty?
      end
      [lineno, specification, clusters]
    end
    expect(cases.length).to eq(1187)

    # NUL forces a cluster break on both sides, so each case can share the same stream.
    source = cases.map { |_, _, clusters| "#{clusters.join}\0" }.join
    %i[table firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/\X/, emit: :CLUSTER)
      end
      stream = lexer.new(StringIO.new(source), chunk_size: 1, retain_input: false)
      cases.each do |lineno, specification, clusters|
        actual = clusters.map { stream.next_token&.last&.bytes }
        expect(actual).to eq(clusters.map(&:bytes)), "#{mode}, GraphemeBreakTest line #{lineno}: #{specification}"
        expect(stream.next_token).to eq([:CLUSTER, "\0"])
      end
      expect(stream.next_token).to be_nil
    end
  end

  it "takes the longest cluster at its own start and never gives bytes back" do
    [/\X/, /.\X/, /\X\X/, /\X\u0301/, /(?=\X)\X!/, /(?<=a)\X/].each do |pattern|
      native = Regexp.new("\\A(?:#{pattern.source})\\z")
      compiled = Flexr.compile_pattern(pattern)
      ["a", "a\u0301", "a\u0301!", "a\u0301b", "ab", "\u0301", "\r\n", "👩‍👩‍👧‍👦", "🇯🇵🇫"].each do |input|
        expect(compiled.accept?(input)).to eq(native.match?(input)), "#{pattern.inspect} on #{input.inspect}"
      end
    end
  end

  it "compiles a grapheme rule with shadowed scalar rules" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/\X/, emit: :CLUSTER)
      rule(/a/, emit: :LETTER)
      rule(/./m, emit: :SCALAR)
    end

    scan = Thread.new { lexer.new("ae\u0301").tokens }
    expect(scan.join(15)).to be(scan), "lexer did not finish compiling within 15 seconds"
    expect(scan.value).to eq([[:CLUSTER, "a"], [:CLUSTER, "e\u0301"]])
  ensure
    scan.kill.join if scan&.alive?
  end

  it "uses vendored boundaries when selecting and replaying named captures" do
    %i[table direct firstmatch].each do |mode|
      lexer = Class.new(Flexr::Lexer) do
        backend mode
        rule(/(?<before_new_mark>\X)(?=\u0897)|(?<plain>\X)/) { emit :CLUSTER, captures }
      end

      input = StringIO.new("a\u0897e\u0301")
      expect(lexer.new(input, chunk_size: 1, retain_input: false).tokens).to eq([
        [:CLUSTER, {before_new_mark: "a", plain: nil}],
        [:CLUSTER, {before_new_mark: nil, plain: "\u0897"}],
        [:CLUSTER, {before_new_mark: nil, plain: "e\u0301"}]
      ])
    end
  end

  it "embeds grapheme data and keeps only user captures in a standalone lexer" do
    Dir.mktmpdir("flexr-grapheme-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      output = File.join(directory, "lexer.rb")
      File.write(spec, <<~'RUBY')
        require "flexr"
        class GraphemeFixture < Flexr::Lexer
          backend :firstmatch
          rule(/(?<FlexrGrapheme0>\X)/) { emit :CLUSTER, captures }
        end
      RUBY
      Flexr::Generator.new(spec, output: output, options: { standalone: true }).generate
      program = <<~'RUBY'
        require "stringio"
        load ARGV.fetch(0)
        input = StringIO.new("a\u0897\r\n")
        actual = GraphemeFixture.new(input, chunk_size: 1, retain_input: false).tokens
        expected = ["a", "\u0897", "\r\n"].map { |cluster| [:CLUSTER, {FlexrGrapheme0: cluster}] }
        abort actual.inspect unless actual == expected
      RUBY
      _, stderr, status = Open3.capture3(RbConfig.ruby, "-e", program, output)
      expect(status).to be_success, stderr
    end
  end

  it "consumes CRLF and individual bytes in binary mode" do
    lexer = Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      rule(/\X/n, emit: :CLUSTER)
    end

    bytes = "\r\n\xff\0\rA\n".b
    result = lexer.new(StringIO.new(bytes), chunk_size: 1).tokens.map(&:last)
    expect(result).to eq(bytes.scan(/\X/n))
  end
end
