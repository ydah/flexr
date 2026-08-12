# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe "adversarial boundary coverage" do
  let(:fixture) { File.expand_path("fixtures/generated.flexr.rb", __dir__) }

  def run_cli(*arguments)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(arguments, out: output, err: errors)
    [status, output.string, errors.string]
  end

  def write_spec(name, source)
    path = File.join(Dir.tmpdir, "flexr-adversarial-#{name}-#{Process.pid}.flexr.rb")
    File.binwrite(path, source)
    path
  end

  describe Flexr::Regexp::Parser do
    it "covers inline options, escapes, extended mode, and all binary POSIX classes" do
      patterns = [
        "(?i-mix:a)", "(?imx:a)", "(?i)",
        "\\n\\t\\r\\f\\v\\a\\e\\0\\x41\\x{41}\\u0041\\u{41}",
        "\\d\\D\\w\\W\\s\\S\\h\\H", "[a-zA-Z0-9_]", "[^a-z]"
      ]
      patterns.each { |pattern| expect(described_class.new(pattern).parse).not_to be_nil }

      %w[alnum alpha blank cntrl digit graph lower print punct space upper xdigit].each do |name|
        node = described_class.new("[[:#{name}:]]", encoding: Encoding::BINARY).parse
        expect(node).not_to be_nil
      end

      extended = described_class.new(" a # ignored comment\n b ", options: Regexp::EXTENDED).parse
      expect(extended).to be_a(Flexr::Regexp::AST::Seq)
    end

    it "reports malformed inline options, escapes, ranges, and unsupported groups" do
      invalid = [
        "(?q:a)", "(?i", "[z-a]", "[a-", "[[:unknown:]]", "\\x1", "\\u12",
        "\\x{110000}", "\\u{d800}", "\\p{", "a\\"
      ]
      invalid.each do |pattern|
        expect { described_class.new(pattern).parse }.to raise_error(Flexr::CompileError)
      end

      {
        "(?=a)" => "followed_by",
        "(?>a)" => "DFA-compatible",
        "a*?" => "negated character class",
        "\\1" => "state",
        "\\k<name>" => "split the rule"
      }.each do |pattern, help|
        expect { described_class.new(pattern).parse }
          .to raise_error(Flexr::UnsupportedRegexpError) { |error| expect(error.diagnostic.help).to include(help) }
      end
    end

    it "covers anchor forms and Unicode property branches" do
      [%w[^ $].join, "^a$", "\\p{L}", "\\P{Nd}", "(?-mix:a)"].each do |pattern|
        expect { described_class.new(pattern).parse }.not_to raise_error
      end
      expect { described_class.new("a^b").parse }.to raise_error(Flexr::CompileError)
      expect(described_class.new("[[:^alpha:]]").parse).not_to be_nil
    end
  end

  it "exercises CLI inspection, generation, and error rendering boundaries" do
    expect(run_cli("--help").first).to eq(0)
    expect(run_cli("check", fixture, "--format", "human", "--color", "never").first).to eq(0)

    stats_status, stats, = run_cli("stats", fixture, "--format", "json")
    expect(stats_status).to eq(0)
    expect(JSON.parse(stats).fetch("initial")).to include("table_cells", "table_entries", "acceleration_regions")

    tokens_status, tokens, = run_cli("tokens", fixture)
    expect(tokens_status).to eq(0)
    expect(tokens).to eq("\n")

    dot_status, dot, = run_cli("dot", fixture)
    trace_status, trace, = run_cli("trace", fixture)
    expect(dot_status).to eq(0)
    expect(dot).to start_with("digraph flexr {").and end_with("}\n")
    expect(trace_status).to eq(0)
    expect(trace).to include("state initial", "transitions=")

    explain_status, explanation, = run_cli("explain", fixture)
    expect(explain_status).to eq(0)
    expect(explanation).to include("rule 0:")
    expect(run_cli("explain", fixture, "--rule", "99").first).to eq(2)

    missing_status, _output, missing_errors = run_cli("check", "/tmp/flexr-file-that-does-not-exist.rb", "--format", "json")
    expect(missing_status).to eq(1)
    expect(JSON.parse(missing_errors).first.fetch("code")).to eq("FLEXR-E000")

    usage_status, _usage, usage_errors = run_cli("check", fixture, "--backend", "invalid")
    expect(usage_status).to eq(2)
    expect(usage_errors).to include("unsupported backend")
  end

  it "handles CLI separators, warning levels, output files, and generated options" do
    source = <<~RUBY
      require "flexr"
      class CLIAdversarialLexer < Flexr::Lexer
        emits :A
        rule(/a/) { emit :A }
      end
    RUBY
    path = write_spec("cli", source)
    output_path = "#{path}.generated.rb"

    status, _output, errors = run_cli("check", "--", path)
    expect(status).to eq(0)
    expect(errors).to be_empty

    generated_status, _output, generated_errors = run_cli(
      path, "-o", output_path, "--backend", "direct", "--token-kind", "struct",
      "--accel", "none", "--table-compression", "full", "--table-format", "packed",
      "--standalone", "--warn", "none", "--warn-as-error"
    )
    expect(generated_status).to eq(0)
    expect(generated_errors).to be_empty
    expect(File).to exist(output_path)
    expect(File.read(output_path)).to include("backend: :direct", "token_kind: :struct")
  ensure
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(output_path) if output_path
  end

  it "covers CLI argument failures, eval mode, and human diagnostics" do
    expect(run_cli("check").first).to eq(2)
    expect(run_cli("check", fixture, "extra").first).to eq(2)
    expect(run_cli("check", "/tmp/flexr-file-that-does-not-exist.rb").last).to include("error:")

    source = <<~RUBY
      require "flexr"
      class CLIAdversarialDiagnosticLexer < Flexr::Lexer
        rule(/a/) { skip }
        rule(/a/) { skip }
      end
    RUBY
    path = write_spec("cli-diagnostics", source)
    warning_status, warning_output, warning_errors = run_cli("check", path, "--warn", "all")
    expect(warning_status).to eq(0)
    expect(warning_output).to include("warning[FLEXR-W001]")
    expect(warning_errors).to be_empty

    eval_source = <<~RUBY
      require "flexr"
      class CLIAdversarialEvalLexer < Flexr::Lexer
        rule(/a/) { emit :A }
      end
    RUBY
    eval_path = write_spec("cli-eval", eval_source)
    expect(run_cli("check", eval_path, "--eval").first).to eq(0)

    parsed = Flexr::CLI.send(:read_spec, path)
    expect(Flexr::CLI.send(:compile, parsed, overrides: { allow_empty_match: false })).to be_a(Flexr::Automaton::CompiledSpec)
    expect(Flexr::CLI.generate(path, Flexr::Options.default)).to include("class CLIAdversarialDiagnosticLexer")
  ensure
    FileUtils.rm_f(path) if path
    FileUtils.rm_f(eval_path) if eval_path
  end

  it "covers CLI import output and benchmark dispatch" do
    import_path = File.join(Dir.tmpdir, "flexr-adversarial-#{Process.pid}.l")
    imported_path = "#{import_path}.rb"
    File.write(import_path, <<~LEX)
      %token WORD
      %%
      [a-z]+ { return WORD; }
    LEX

    status, output, errors = run_cli("import", import_path, "-o", imported_path)
    expect(status).to eq(0)
    expect(output).to be_empty
    expect(errors).to be_empty
    expect(File.read(imported_path)).to include("emits :WORD")

    benchmark_status, benchmark_output, = run_cli(
      "bench", File.expand_path("../examples/json/lexer.flexr.rb", __dir__), "--iterations", "1", "--format", "json"
    )
    expect(benchmark_status).to eq(0)
    expect(JSON.parse(benchmark_output)).to include("modes")
  ensure
    FileUtils.rm_f(import_path) if import_path
    FileUtils.rm_f(imported_path) if imported_path
  end

  it "covers runtime buffer boundary behavior" do
    buffer = Flexr::Runtime::Buffer.new("abc\n")
    expect(buffer.getbyte(0)).to eq(97)
    expect(buffer.byteslice(1)).to eq("b")
    expect(buffer.byteslice(1, 2)).to eq("bc")
    expect(buffer.byteslice(1..)).to eq("bc\n")
    expect(buffer.byteslice(1...3)).to eq("bc")
    expect(buffer.eof?(4)).to be(true)
    expect(buffer.eof_loaded?).to be(true)
    expect(buffer.utf8_boundary?(-1)).to be(false)
    expect(buffer.utf8_boundary?(0)).to be(true)
    expect(buffer.valid_utf8_at?(0)).to be(true)
    expect(buffer.valid_utf8_at?(4)).to be(false)
    expect { Flexr::Runtime::Buffer.new("a", chunk_size: 0) }.to raise_error(ArgumentError)
    expect { Flexr::Runtime::Buffer.new(Object.new) }.to raise_error(ArgumentError)

    io = StringIO.new("abあ")
    streamed = Flexr::Runtime::Buffer.new(io, chunk_size: 2)
    expect(streamed.read_to_end).to eq("abあ".b)
    expect(streamed.byteslice(0...2)).to eq("ab")
  end

  it "covers automaton analyses, IR helpers, and diagnostic rendering" do
    lexer_class = Class.new(Flexr::Lexer) do
      rule(/a+/) { skip }
      rule(/b/) { skip }
    end
    compiled = lexer_class.compile!
    dfa = compiled.machines.fetch(:initial).dfa

    expect(Flexr::Automaton::Analysis.unreachable_rules(compiled)).to be_empty
    expect(Flexr::Automaton::Analysis.needs_backup?(dfa)).to be(true).or be(false)
    expect(Flexr::Automaton::Analysis.self_loop_set(dfa, dfa.start)).to be_a(Array)
    expect(Flexr::Automaton::Analysis.dead_states(dfa)).to be_a(Array)
    expect(dfa.accept?("a")).to be(true)
    expect(dfa.accept?("z")).to be(false)
    expect(dfa.stats).to include(:states, :classes, :accepting_states)

    rule = Flexr::IR::Rule.new(index: 0, patterns: [/a/], action: %i[emit A], states: [:initial])
    expect(rule.emit?).to be(true)
    expect(rule.skip?).to be(false)
    expect(Flexr::IR::Spec.new.initial_state).to eq(:initial)

    set = Flexr::DiagnosticSet.new
    diagnostic = Flexr::Diagnostics.warning("FLEXR-W001", "warning", help: "fix", note: "note")
    set << diagnostic
    expect(set.any_error?).to be(false)
    expect(set.empty?).to be(false)
    expect(set.to_a).to eq([diagnostic])
    expect(set.render(format: :human, color: :always)).to include("warning[FLEXR-W001]", "help: fix", "note: note")
    expect(JSON.parse(set.render(format: :json)).first.fetch("code")).to eq("FLEXR-W001")
  end

  it "covers generated installation formats and runtime token kinds" do
    generated = Flexr::Generator.new(fixture, options: { table_compression: :none }).generate
    expect(generated).to include("def scan_one")

    struct_lexer = Class.new(Flexr::Lexer) do
      token_kind :struct
      rule(/a/) { emit :A }
    end
    token = struct_lexer.new("a").tokens.first
    expect(token).to be_a(Flexr::Runtime::Token)
    expect(token.type).to eq(:A)

    yielded = []
    yield_lexer = Class.new(Flexr::Lexer) do
      token_kind :yield
      rule(/a/) { emit :A }
    end
    yield_lexer.new("a").each_token { |type, value| yielded << [type, value] }
    expect(yielded).to eq([[:A, "a"]])
  end

  it "covers low-level AST, Unicode, and representation boundaries" do
    ast = Flexr::Regexp::AST
    expect(ast::Empty.new(loc: nil).to_s).to eq("Empty")
    expect(ast::ByteRange.new(lo: 1, hi: 2, loc: nil).to_s).to eq("ByteRange(1..2)")
    expect(ast::CodepointRange.new(lo: 65, hi: 90, loc: nil).to_s).to eq("CodepointRange(65..90)")
    expect(ast::Anchor.new(kind: :bol, loc: nil).to_s).to eq("Anchor(bol)")
    expect(ast::Star.new(child: ast::Empty.new(loc: nil), loc: nil).to_s).to eq("Star(Empty)")
    expect(ast::Seq.new(children: [ast::Empty.new(loc: nil)], loc: nil).to_s).to eq("Seq(Empty)")
    expect(ast::Alt.new(children: [ast::Empty.new(loc: nil)], loc: nil).to_s).to eq("Alt(Empty)")
    expect(ast::TrailMark.new(rule_id: 1, loc: nil).to_s).to include("TrailMark")
    expect(ast::CharClass.new(ranges: [], negated: false, loc: nil).to_s).to include("CharClass")
    expect(ast::Node.new(:location).loc).to eq(:location)

    property_class = ast::CharClass.new(
      ranges: [[ast::Property, false, "L"]], negated: false, loc: nil
    )
    expect(Flexr::Regexp::Normalizer.new(property_class).normalize).not_to be_nil
    expect { Flexr::Regexp::Normalizer.new(Object.new).normalize }.to raise_error(Flexr::CompileError)
    expect { Flexr::Unicode::Property.ranges("not-a-property") }.to raise_error(Flexr::CompileError)
    expect { Flexr::Unicode::Property.ranges("POSIX_not-a-class") }.to raise_error(Flexr::CompileError)

    walked = []
    Flexr::Unicode::Utf8Splitter.send(:walk, 0x41, 0x41, 1, [0x41], walked)
    expect(walked).to eq([[[0x41, 0x41]]])
  end

  it "covers generated loaders, DFA dispatch, and diagnostics" do
    klass = Class.new(Flexr::Lexer)
    payload = {
      rules: [], backend: :table, token_kind: :array, encoding: Encoding::UTF_8,
      declared_tokens: [], options: { accel: :none, experimental: true }, states: [:state],
      inclusive_states: { state: false }, eof_rules: { initial: proc {} }
    }
    expect(Flexr::Generated.install!(klass, payload)).to eq(klass)
    expect(klass.__flexr_spec.eof_rules).to include(:initial)

    compiled_payload = payload.merge(
      artifact: Flexr::Generated.artifact_metadata,
      compiled: { machines: {}, states: [], stats: {}, diagnostics: [{ code: "FLEXR-W999", severity: :warning,
                                                                        message: "generated warning" }] }
    )
    expect(Flexr::Generated.install_compiled!(klass, compiled_payload)).to eq(klass)

    table = Flexr::Codegen::Table.new(klass.__flexr_compiled)
    expect(table.stats).to eq({})
    expect(table.header(source: "fixture")).to include("Generated by flexr")
    expect(table.source).to include("def scan_one")
    expect { Flexr::Codegen::Firstmatch.new(klass.__flexr_compiled) }
      .to raise_error(Flexr::CompileError, /experimental/)
    expect(Flexr::Codegen::Firstmatch.new(klass.__flexr_compiled, experimental: true).generate).to eq([])

    dfa = Flexr::Automaton::DFA.new(
      transitions: [[nil]], accepts: [[]], ec: Array.new(256, 0), class_count: 1, start: 0, rule_ids: [],
      direct: { nxt: [7], classes: 1 }
    )
    expect(dfa.transition_direct(0, 65)).to eq(7)
    table_dfa = Flexr::Automaton::DFA.new(
      transitions: [[nil]], accepts: [[]], ec: Array.new(256, 0), class_count: 1, start: 0, rule_ids: []
    )
    expect(table_dfa.transition_direct(0, 65)).to be_nil
    expect(Flexr::Automaton::ReferenceDFA.new(/a/).stats).to include(reference: true)
    expect(Flexr::Automaton::ReferenceDFA.new(/a/).accept?("a")).to be(true)
    expect do
      Flexr::Automaton::NFABuilder.new.build([[Object.new, Flexr::Automaton::Acceptance.new(
        rule_index: 0, pattern_index: 0, bol_only: false, end_anchor: false
      )]])
    end.to raise_error(Flexr::CompileError)

    diagnostic = Flexr::Diagnostics.error("FLEXR-E001", "error")
    warning = Flexr::Diagnostics.warning("FLEXR-W001", "warning")
    expect(diagnostic.error?).to be(true)
    expect(warning.warning?).to be(true)
    set = Flexr::DiagnosticSet.new << warning
    expect(set.each.to_a).to eq([warning])
    expect(set.render(color: :auto)).to include("warning[FLEXR-W001]")
    expect { Flexr::Diagnostics.raise!(Flexr::Diagnostics.error("FLEXR-E014", "unsupported")) }
      .to raise_error(Flexr::UnsupportedRegexpError)
    expect { Flexr::Diagnostics.raise!(diagnostic) }.to raise_error(Flexr::CompileError)
  end

  it "covers compiler limits, anchors, and the Rake integration" do
    limited = Class.new(Flexr::Lexer) do
      rule(/a/) { skip }
    end
    limited.__flexr_config.options[:max_dfa_states] = 1
    expect { limited.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E006")
    end

    anchored = Class.new(Flexr::Lexer) do
      rule(/a(?:^)/) { skip }
    end
    expect { anchored.compile! }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E009")
    end

    require "rake"
    task_name = "flexr_adversarial_#{Process.pid}"
    output = File.join(Dir.tmpdir, "flexr-rake-#{Process.pid}.rb")
    Flexr::RakeTask.new(task_name.to_sym) do |task|
      task.spec = fixture
      task.output = output
    end
    Rake::Task[task_name].invoke
    expect(File).to exist(output)
  ensure
    FileUtils.rm_f(output) if output
    Rake::Task[task_name].clear if defined?(Rake) && task_name && Rake::Task.task_defined?(task_name)
  end

  it "covers static evaluation of supported Ruby expressions" do
    evaluate = lambda do |expression, constants: {}, scope: []|
      node = Prism.parse(expression).value.statements.body.first
      Flexr::Source::StaticEval.new(expression, constants: constants, scope: scope).call(node)
    end

    expect(evaluate.call("/a/")).to eq(/a/)
    expect(evaluate.call(%q(/#{'a'}/))).to eq(/a/)
    expect(evaluate.call("'text'")).to eq("text")
    expect(evaluate.call(%q("#{'text'}"))).to eq("text")
    expect(evaluate.call(":token")).to eq(:token)
    expect(evaluate.call("42")).to eq(42)
    expect(evaluate.call("1.5")).to eq(1.5)
    expect(evaluate.call("true")).to be(true)
    expect(evaluate.call("false")).to be(false)
    expect(evaluate.call("nil")).to be_nil
    expect(evaluate.call("[1, 2]")).to eq([1, 2])
    expect(evaluate.call("1..3")).to eq(1..3)
    expect(evaluate.call("1...3")).to eq(1...3)
    expect(evaluate.call("'text'.freeze")).to eq("text")
    expect(evaluate.call("Regexp.union(/a/, /b/)").source).to include("a", "b")
    expect(evaluate.call("Encoding::UTF_8")).to eq(Encoding::UTF_8)
    expect(evaluate.call("VALUE", constants: { "VALUE" => /c/ })).to eq(/c/)
    expect(evaluate.call("Outer::VALUE", constants: { "Outer::VALUE" => /d/ })).to eq(/d/)
    expect(evaluate.call("::Outer::VALUE", constants: { "Outer::VALUE" => /e/ })).to eq(/e/)
    expect(evaluate.call("VALUE", constants: { "Scope::VALUE" => /f/ }, scope: [:Scope])).to eq(/f/)
    expect(evaluate.call("[1, *[2]]")).to eq([1, [2]])

    expect { evaluate.call("unknown.call") }.to raise_error(Flexr::StaticResolutionError)
    expect { evaluate.call("UNKNOWN") }.to raise_error(Flexr::StaticResolutionError)
  end

  it "covers DSL validation and state/configuration contracts" do
    lexer_class = Class.new(Flexr::Lexer)
    lexer_class.emits(:A, :A)
    lexer_class.backend(:auto)
    lexer_class.accel(:regexp)
    lexer_class.option(:experimental)
    lexer_class.state(:word) { rule(/a/, emit: :A) }
    lexer_class.all_states { rule(/b/, skip: true) }
    lexer_class.on_eof { emit :EOF }
    expect(lexer_class.__flexr_config.declared_tokens).to eq([:A])
    expect(lexer_class.__flexr_states.keys).to include(:word)
    expect(lexer_class.new("b").tokens).to eq([[:EOF, ""]])

    expect { Class.new(Flexr::Lexer).state(:missing) }.to raise_error(ArgumentError, /block/)
    expect { Class.new(Flexr::Lexer).state(&:itself) }.to raise_error(ArgumentError, /name/)
    expect { Class.new(Flexr::Lexer).token_kind(:invalid) }.to raise_error(ArgumentError, /token_kind/)
    expect { Class.new(Flexr::Lexer).encoding(Encoding::US_ASCII) }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E011") }
    expect { Class.new(Flexr::Lexer) { rule(123) } }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E018") }
    expect { Class.new(Flexr::Lexer) { rule(/a/, followed_by: 123) } }
      .to raise_error(Flexr::CompileError) { |error| expect(error.diagnostic.code).to eq("FLEXR-E018") }
  end

  it "covers flex and Rexical importer branches and incomplete migrations" do
    flex_path = File.join(Dir.tmpdir, "flexr-importer-coverage-#{Process.pid}.l")
    File.write(flex_path, <<~LEX)
      %{ header }
      %x STRING
      %s INCLUSIVE
      %token A B EOF
      %option yylineno
      %option noyywrap
      DIGIT [0-9]
      # declaration comment
      %%
      <STRING,INITIAL>"<" { BEGIN(STRING); }
      <*>{DIGIT}+ { value = yytext; length = yyleng; yyless(1); yymore(); ECHO; return A; }
      "q"
      return B;
      . ;
      <<EOF>> { return EOF; }
      %%
      footer
    LEX

    result = Flexr::Importer.import(flex_path)
    expect(result.complete?).to be(false)
    expect(result.source).to include("begin_state :STRING", "text.bytesize", "less(1)", "more", "echo", "on_eof")
    expect(result.warnings).to include("unsupported flex option noyywrap")

    rex_path = File.join(Dir.tmpdir, "flexr-importer-coverage-#{Process.pid}.rex")
    File.write(rex_path, <<~REX)
      # Rexical header
      macro
        DIGIT [0-9]
      end
      rule
        /{DIGIT}+/ { return NUMBER; }
        /x/ |;
      end
    REX
    rex_result = Flexr::Importer.import(rex_path)
    expect(rex_result.source).to include("Imported rexical header", "emit :NUMBER")
    expect(rex_result.warnings.first).to include("first-match semantics")

    bad_path = File.join(Dir.tmpdir, "flexr-importer-coverage-#{Process.pid}.txt")
    File.write(bad_path, "not an importer input")
    expect { Flexr::Importer.import(bad_path) }.to raise_error(Flexr::Importer::UnsupportedFormatError)
    missing_rules = File.join(Dir.tmpdir, "flexr-importer-missing-#{Process.pid}.rex")
    File.write(missing_rules, "class MissingRule; end")
    expect { Flexr::Importer.import(missing_rules) }.to raise_error(Flexr::CompileError, /no rule section/)
  ensure
    FileUtils.rm_f(flex_path) if flex_path
    FileUtils.rm_f(rex_path) if rex_path
    FileUtils.rm_f(bad_path) if bad_path
    FileUtils.rm_f(missing_rules) if missing_rules
  end

  it "covers importer helper fallbacks and escaped pattern boundaries" do
    importer = Flexr::Importer.new("manual.l", +"")
    importer.send(:parse_declarations, "%m unsupported\n%option yylineno, noyywrap\n")
    importer.send(:parse_rules, "broken rule without action\n[a-z]+\n")
    importer.send(:collect_action, "{ return A;\n", [], 0)
    importer.send(:normalize_pattern, '"unterminated')
    importer.send(:translate_action, "|")
    importer.send(:translate_action, "call_unknown();")
    importer.send(:rexical_counterexample, "[", "a")
    expect(importer.send(:rexical_dfa, /(?=a)/)).to be_nil
    expect(importer.send(:rexical_candidate_characters, '\\x41\\n\\r\\t\\f\\v\\q\\d')).to include("A", "\n")
    expect(importer.send(:rexical_literal_fragments, 'a\\n[bc]\\d\\q')).to include("a\n", "q")
    expect(importer.send(:normalize_rexical_line, "ordinary line\n")).to eq("ordinary line\n")
  end
end
