# frozen_string_literal: true

require "stringio"

RSpec.describe "compiler diagnostic locations" do
  around do |example|
    Dir.mktmpdir("flexr-compiler-locations") do |directory|
      @path = File.join(directory, "lexer.flexr.rb")
      @output_path = File.join(directory, "lexer.rb")
      example.run
    end
  ensure
    Object.send(:remove_const, :CompilerLocationFixture) if Object.const_defined?(:CompilerLocationFixture, false)
  end

  def write_spec(body)
    @source = "# UTF-8: é\nclass CompilerLocationFixture < Flexr::Lexer\n#{body}\nend\n"
    File.binwrite(@path, @source)
  end

  def span(statement)
    offset = @source.b.index(statement.b)
    [offset, offset + statement.bytesize]
  end

  def check
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(["check", @path, "--format", "json"], out: output, err: errors)
    [status, JSON.parse(output.string + errors.string)]
  end

  {
    "FLEXR-E005" => "rule(/a*/, skip: true)",
    "FLEXR-E007" => "rule(/a{1001}/, skip: true)",
    "FLEXR-E009" => "rule(/a^b/, skip: true)",
    "FLEXR-E014" => "rule(/a(?=b)/, skip: true)"
  }.each do |code, statement|
    it "locates #{code} in both check output and generator errors" do
      write_spec("  rule(/z/, skip: true)\n  #{statement}")

      status, diagnostics = check

      expect(status).to eq(1)
      expect(diagnostics.one?).to be(true)
      expect(diagnostics.first).to include("code" => code, "location" => span(statement))
      expect { Flexr::Generator.new(@path).generate }.to raise_error(Flexr::CompileError) do |error|
        expect(error.diagnostic.code).to eq(code)
        expect(error.diagnostic.location).to eq(span(statement))
      end
    end
  end

  it "locates errors in trailing context and preserves their exception class" do
    statement = "rule(/a/, followed_by: /b(?=c)/, skip: true)"
    write_spec("  #{statement}")

    expect { Flexr::Generator.new(@path).generate }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E014")
      expect(error.diagnostic.location).to eq(span(statement))
    end
  end

  it "preserves regexp rewrite examples in check JSON and generator errors" do
    {
      "/a(?=b)/" => "rule(/a/, followed_by: /b/)",
      '/".*?"/' => 'rule(/"[^"\n]*"/)',
      '/"[^"\n]*+"/' => 'rule(/"[^"\n]*"/)',
      '/\011/' => 'rule(/\x09/)',
      '/\R/' => 'rule(/\r\n|[\n\v\f\r\u0085\u2028\u2029]/)',
      '/\q/' => 'rule(/q/)',
      '/"(?>[^"\n]*)"/' => 'rule(/"[^"\n]*"/)',
      '/(a|b)\1/' => 'rule(/(?:aa|bb)/)',
      '/(a|b)\k<1>/' => 'rule(/(?:aa|bb)/)',
      '/[\1]/' => 'rule(/[\x01]/)',
      '/(?<word>ab)/' => 'rule(/(?:ab)/)',
      "/(?'word'ab)/" => 'rule(/(?:ab)/)',
      '/(a)?(?(1)b|c)/' => 'rule(/(?:ab|c)/)',
      '/x(?~a)/' => 'rule(/x[^a]*/)',
      '/foo\b:/' => 'rule(/foo:/)',
      '/foo\Bbar/' => 'rule(/foobar/)',
      '/\Ga/' => 'rule(/a/)',
      '/\Aa/' => 'rule(/^a/)',
      '/a\z/' => 'rule(/a$/)',
      '/a\Z/' => 'rule(/a$/)',
      '/[\A]/' => 'rule(/[A]/)',
      '/[\B]/' => 'rule(/[B]/)',
      '/[\G]/' => 'rule(/[G]/)',
      '/[\z]/' => 'rule(/[z]/)',
      '/[\Z]/' => 'rule(/[Z]/)'
    }.each do |pattern, example|
      write_spec("  rule(#{pattern}, emit: :A)")

      status, diagnostics = check

      expect(status).to eq(1)
      help = diagnostics.first.fetch("help")
      expect(help).to include(example, "keep the action")
      expect { Flexr::Generator.new(@path).generate }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
        expect(error.diagnostic.help).to eq(help)
      end
    end
  end

  it "locates regexp errors when empty matches bypass the initial validation" do
    statement = "rule(/a(?=b)/, skip: true)"
    write_spec("  option :allow_empty_match\n  #{statement}")

    expect { Flexr::Generator.new(@path).generate }.to raise_error(Flexr::UnsupportedRegexpError) do |error|
      expect(error.diagnostic.location).to eq(span(statement))
    end
  end

  it "locates rule warnings and keeps one undeclared-token warning at its first emitting rule" do
    statement = "rule(/(a)+/, followed_by: /b+/, emit: :B)"
    write_spec("  emits :A\n  rule(/z/, emit: :A)\n  #{statement}\n  rule(/c/, emit: :B)")

    status, diagnostics = check
    expected_codes = %w[FLEXR-W003 FLEXR-W012 FLEXR-W013 FLEXR-W014]

    expect(status).to eq(0)
    warnings = diagnostics.reject { |item| item.fetch("code") == "FLEXR-W016" }
    expect(warnings.map { |item| item.fetch("code") }).to match_array(expected_codes)
    expect(warnings.map { |item| item.fetch("location", nil) }.uniq).to eq([span(statement)])
    expect(warnings.to_h { |item| [item.fetch("code"), item.fetch("message")] }).to include(
      "FLEXR-W003" => "rule /(a)+/, followed_by: /b+/ uses variable-length trailing context",
      "FLEXR-W012" => "rule /(a)+/, followed_by: /b+/ cannot use region acceleration with trailing context",
      "FLEXR-W013" => "rule /(a)+/, followed_by: /b+/ uses a capturing group; flexr treats it as non-capturing"
    )

    generator = Flexr::Generator.new(@path, output: @output_path)
    generator.generate
    generated_warnings = generator.diagnostics.reject { |item| item.code == "FLEXR-W016" }
    expect(generated_warnings.map(&:code)).to match_array(expected_codes)
    expect(generated_warnings.map(&:location).uniq).to eq([span(statement)])
    expect(generated_warnings.map(&:message)).to match_array(warnings.map { |item| item.fetch("message") })

    load @output_path
    expect(CompilerLocationFixture.__flexr_compiled.diagnostics.map(&:to_h))
      .to eq(generated_warnings.map(&:to_h))
  end

  it "locates firstmatch warnings at the later rule" do
    statement = "rule(/aa/, skip: true)"
    write_spec("  backend :firstmatch\n  option :experimental\n  rule(/a/, skip: true)\n  #{statement}")

    status, diagnostics = check

    expect(status).to eq(0)
    expect(diagnostics.find { |item| item.fetch("code") == "FLEXR-W010" })
      .to include("location" => span(statement),
                  "message" => "firstmatch rule /a/ and rule /aa/ may change longest-match semantics")
  end

  it "locates the first block emitting a token even when later rules use emit options" do
    statement = "rule(/a/) { emit :B; emit :C }"
    write_spec("  emits :A\n  #{statement}\n  rule(/b/, emit: :B)")

    status, diagnostics = check
    warnings = diagnostics.select { |item| item.fetch("code") == "FLEXR-W014" }

    expect(status).to eq(0)
    expect(warnings.map { |item| item.fetch("message") })
      .to eq(["token :B is not declared by emits", "token :C is not declared by emits"])
    expect(warnings.map { |item| item.fetch("location") }).to eq([span(statement), span(statement)])
  end

  it "renders compiler error source context through the CLI" do
    write_spec("  rule(/a(?=b)/, skip: true)")
    output = StringIO.new
    errors = StringIO.new

    status = Flexr::CLI.run(["check", @path, "--color", "never"], out: output, err: errors)

    expect(status).to eq(1)
    expect(output.string).to be_empty
    expect(errors.string).to include("error[FLEXR-E014]", "  --> #{@path}:3:3\n",
                                    "3 |   rule(/a(?=b)/, skip: true)\n", "  |   ^",
                                    "rule(/a/, followed_by: /b/)", "keep the action")
  end

  it "leaves location absent when compiling a runtime rule without source metadata" do
    lexer = Class.new(Flexr::Lexer) { rule(/a*/, skip: true) }

    expect { lexer.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E005")
      expect(error.diagnostic.message).to eq("rule /a*/ can match an empty string")
      expect(error.diagnostic.location).to be_nil
    end
  end
end
