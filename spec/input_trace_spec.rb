# frozen_string_literal: true

require "stringio"

RSpec.describe "input tracing" do
  def trace_class(backend = :table)
    Class.new(Flexr::Lexer) do
      backend backend
      option :experimental if backend == :firstmatch
      rule(/if/, emit: :IF)
      rule(/[a-z]+/, emit: :IDENT)
      rule(/==/, emit: :EQ)
      rule(/=/, emit: :ASSIGN)
      rule(/ +/, skip: true)
    end
  end

  it "reports actual candidates, longest matches, ties, and skipped actions" do
    lexer = trace_class.new("if == total")
    trace = Flexr::Trace.new(lexer)

    expect(trace.run).to eq([[:IF, "if"], [:EQ, "=="], [:IDENT, "total"]])
    expect(trace.steps.map { |step| step.values_at(:byte_begin, :text, :action, :reason) })
      .to eq([[0, "if", "emit", "rule_order"], [2, " ", "skip", "only_match"],
              [3, "==", "emit", "longest"], [5, " ", "skip", "only_match"],
              [6, "total", "emit", "only_match"]])
    expect(trace.steps[0][:candidates].map { |candidate| candidate.values_at(:rule, :length, :total_length) })
      .to eq([[0, 2, 2], [1, 2, 2]])
    expect(trace.steps[2][:candidates].map { |candidate| candidate.values_at(:rule, :length) })
      .to eq([[2, 2], [3, 1]])
  end

  it "uses firstmatch priority and Ruby alternation rather than DFA longest matching" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      option :experimental
      rule(/a|ab/, emit: :FIRST)
      rule(/ab/, emit: :SECOND)
      rule(/b/, emit: :B)
    end
    trace = Flexr::Trace.new(lexer.new("ab"))
    expect(trace.run).to eq([[:FIRST, "a"], [:B, "b"]])
    expect(trace.steps[0][:reason]).to eq("first_match")
    expect(trace.steps[0][:candidates].map { |candidate| candidate.values_at(:rule, :length) })
      .to eq([[0, 1], [1, 2]])
    streamed = Flexr::Trace.new(lexer.new(StringIO.new("ab"), chunk_size: 1))
    streamed.run
    expect(streamed.steps).to eq(trace.steps)
  end

  it "traces complete firstmatch candidates within the runtime step limit" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a+/, emit: :FIRST)
      rule(/(?:aa)+/, emit: :SECOND)
    end

    input = "a" * 50
    trace = Flexr::Trace.new(lexer.new(input, max_steps: 5))
    expect(trace.run).to eq([[:FIRST, input]])
    expect(trace.steps.first[:candidates].map { |candidate| candidate[:length] }).to eq([50, 50])
  end

  it "counts trailing context without consuming it and excludes false anchor matches" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/^x$/, emit: :LINE)
      rule(/a/, followed_by: /bc/, emit: :CONTEXT)
      rule(/ab/, emit: :AB)
      rule(/./, emit: :OTHER)
    end
    trace = Flexr::Trace.new(lexer.new("abcx"))
    expect(trace.run).to eq([[:CONTEXT, "a"], [:OTHER, "b"], [:OTHER, "c"], [:OTHER, "x"]])
    expect(trace.steps[0][:candidates].map { |candidate| candidate.values_at(:rule, :length, :total_length) })
      .to eq([[1, 1, 3], [2, 2, 2], [3, 1, 1]])
    expect(trace.steps.last[:candidates].map { |candidate| candidate[:rule] }).to eq([3])
  end

  it "excludes partial UTF-8 lookahead matches from both tokens and trace candidates" do
    lexer = Class.new(Flexr::Lexer) do
      rule("x", followed_by: /y(?~ab)\xC3/n, emit: :BYTE)
      rule(/./m, emit: :OTHER)
    end
    trace = Flexr::Trace.new(lexer.new(StringIO.new("xyé"), chunk_size: 1, retain_input: false))

    expect(trace.run).to eq([[:OTHER, "x"], [:OTHER, "y"], [:OTHER, "é".b]])
    expect(trace.steps.first[:candidates].map { |candidate| candidate[:rule] }).to eq([1])
  end

  it "uses saved line-start state for empty-body lookahead after discarding the previous byte" do
    lexer = Class.new(Flexr::Lexer) do
      option :allow_empty_match
      rule("\n", skip: true)
      rule(//, followed_by: /^y(?~ab)ab/, emit: :AT_LINE)
      rule(/./m, emit: :OTHER)
    end
    trace = Flexr::Trace.new(lexer.new(StringIO.new("xyab\nyab"), chunk_size: 1, retain_input: false))

    expect(trace.run).to eq([[:OTHER, "x"], [:OTHER, "y"], [:OTHER, "a"], [:OTHER, "b"],
                             [:AT_LINE, ""], [:OTHER, "a"], [:OTHER, "b"]])
    expect(trace.steps[1][:candidates].map { |candidate| candidate[:rule] }).to eq([2])
    expect(trace.steps[5][:candidates].map { |candidate| candidate[:rule] }).to eq([1, 2])
  end

  it "records each state action once, including actions that emit nothing" do
    calls = 0
    lexer = Class.new(Flexr::Lexer) do
      rule(/</) do
        calls += 1
        begin_state :word
      end
      state(:word) do
        rule(/[a-z]+/) do
          calls += 1
          emit :WORD
        end
        rule(/>/) do
          calls += 1
          begin_state :initial
        end
      end
    end
    trace = Flexr::Trace.new(lexer.new("<hi>"))
    expect(trace.run).to eq([[:WORD, "hi"]])
    expect(calls).to eq(3)
    expect(trace.steps.map { |step| step.values_at(:state, :next_state, :action) })
      .to eq([[:initial, :word, "skip"], [:word, :word, "emit"], [:word, :initial, "skip"]])
  end

  it "reports the longest consumed body when trailing-context totals are tied" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/a+/, followed_by: /a+/, emit: :A)
      rule(/a/, emit: :LAST)
    end
    trace = Flexr::Trace.new(lexer.new("aaa"))
    expect(trace.run).to eq([[:A, "aa"], [:LAST, "a"]])
    expect(trace.steps[0][:candidates][0]).to include(length: 2, trailing_length: 1, total_length: 3)
  end

  it "records EOF actions and consumed positions after less" do
    lexer = Class.new(Flexr::Lexer) do
      rule(/ab/) do
        less(1)
        emit :A
      end
      rule(/b/, emit: :B)
      on_eof { emit :EOF }
    end
    trace = Flexr::Trace.new(lexer.new("ab"))
    expect(trace.run).to eq([[:A, "a"], [:B, "b"], [:EOF, ""]])
    expect(trace.steps[0]).to include(byte_begin: 0, byte_end: 2, next_byte: 1)
    expect(trace.steps.last).to include(byte_begin: 2, byte_end: 2, action: "emit", reason: "eof")
  end

  it "keeps firstmatch candidates before invalid UTF-8 and records error recovery" do
    lexer = Class.new(Flexr::Lexer) do
      backend :firstmatch
      option :experimental
      rule(/a/, emit: :A)
      rule(/abcdef/, emit: :LONG)
      rule(/./, emit: :OTHER)
    end
    trace = Flexr::Trace.new(lexer.new(StringIO.new("abcdef"), chunk_size: 1))
    trace.run
    expect(trace.steps[0][:candidates].map { |candidate| candidate[:length] }).to eq([1, 6, 1])
    trace = Flexr::Trace.new(lexer.new("a\xff".b, error_mode: :token))
    expect(trace.run).to eq([[:A, "a"], [:error, "\xff".b]])
    expect(trace.steps[0][:candidates].map { |candidate| candidate[:length] }).to eq([1, 1])
    expect(trace.steps.last).to include(bytes: [255], reason: "unmatched", action: "emit")
  end

  it "traces runtime and generated actions identically through the CLI" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "trace.flexr.rb")
      input = File.join(directory, "input.txt")
      File.write(path, <<~RUBY)
        class InputTraceFixture < Flexr::Lexer
          option :experimental
          rule(/if/, emit: :IF)
          rule(/[a-z]+/, emit: :IDENT)
          rule(/ +/, skip: true)
        end
      RUBY
      File.write(input, "if hi")
      %w[table direct auto firstmatch].each do |backend|
        traces = [[], ["--generated"]].map do |mode|
          output = StringIO.new
          errors = StringIO.new
          status = Flexr::CLI.run(["trace", path, "--input-file", input, "--format", "json", "--backend", backend, *mode], out: output, err: errors)
          expect(status).to eq(0), errors.string
          JSON.parse(output.string)
        end
        expect(traces[0]).to eq(traces[1])
        expect(traces[0].fetch("steps").map { |step| step.fetch("text") }).to eq(["if", " ", "hi"])
      end
      output = StringIO.new
      errors = StringIO.new
      expect(Flexr::CLI.run(["trace", path, "--input", "if hi"], out: output, err: errors)).to eq(0), errors.string
      expect(output.string).to include('@0 "if"', "rule_order", '-> rule 0 emit', '@2 " "', 'skip')
    end
  end

  it "rejects ambiguous input sources and trace-only options on other commands" do
    output = StringIO.new
    errors = StringIO.new
    expect(Flexr::CLI.run(["trace", "missing.rb", "--input", "a", "--input-file", "x"], out: output, err: errors)).to eq(2)
    expect(errors.string).to include("choose --input or --input-file")
    errors = StringIO.new
    expect(Flexr::CLI.run(["check", "missing.rb", "--input", "a"], out: output, err: errors)).to eq(2)
    expect(errors.string).to include("only valid for the trace command")
  end

  it "applies DFA limits before compilation in both tracing modes" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "limited.flexr.rb")
      File.write(path, "class LimitedTraceFixture < Flexr::Lexer\n  rule(/abc/, emit: :ABC)\nend\n")
      [[], ["--generated"]].each do |mode|
        output = StringIO.new
        errors = StringIO.new
        status = Flexr::CLI.run(["trace", path, "--input", "abc", "--max-dfa-states", "1", "--format", "json", *mode], out: output, err: errors)
        expect(status).to eq(1), "#{mode.inspect}: #{output.string} #{errors.string}"
        expect(JSON.parse(errors.string).first.fetch("code")).to eq("FLEXR-E006")
      end
    end
  end

  it "applies warning compilation options in both tracing modes" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "warnings.flexr.rb")
      File.write(path, "class WarningTraceFixture < Flexr::Lexer\n  emits :OTHER\n  rule(/a/, emit: :A)\nend\n")
      [[], ["--generated"]].each do |mode|
        output = StringIO.new
        errors = StringIO.new
        status = Flexr::CLI.run(["trace", path, "--input", "a", "--warn", "all", "--warn-as-error", "--format", "json", *mode], out: output, err: errors)
        expect(status).to eq(1), "#{mode.inspect}: #{output.string} #{errors.string}"
        expect(JSON.parse(errors.string).first.fetch("code")).to eq("FLEXR-W014")
      end
    end
  end

  it "resolves absolute lexer class names in both tracing modes" do
    Dir.mktmpdir do |directory|
      path = File.join(directory, "absolute.flexr.rb")
      File.write(path, "class ::AbsoluteTraceFixture < Flexr::Lexer\n  rule(/a/, emit: :A)\nend\n")
      [[], ["--generated"]].each do |mode|
        Object.send(:remove_const, :AbsoluteTraceFixture) if Object.const_defined?(:AbsoluteTraceFixture, false)
        output = StringIO.new
        errors = StringIO.new
        status = Flexr::CLI.run(["trace", path, "--input", "a", "--format", "json", *mode], out: output, err: errors)
        expect(status).to eq(0), errors.string
        expect(JSON.parse(output.string).fetch("steps").first.fetch("text")).to eq("a")
      end
    end
  ensure
    Object.send(:remove_const, :AbsoluteTraceFixture) if Object.const_defined?(:AbsoluteTraceFixture, false)
  end
end
