# frozen_string_literal: true

require "stringio"

RSpec.describe "generated automatic region acceleration" do
  let(:input) { "#{'a' * 32}!#{'b' * 32}".freeze }
  let(:tokens) { [[:WORD, "a" * 32], [:PUNCTUATION, "!"], [:WORD, "b" * 32]] }

  def generated_lexer(accel, declarations: "")
    Dir.mktmpdir("flexr-generated-auto-accel-") do |directory|
      spec = File.join(directory, "lexer.flexr.rb")
      File.write(spec, <<~RUBY)
        class GeneratedAutoAccelerationLexer < Flexr::Lexer
          backend :direct
          accel :#{accel}
          rule(/[a-z]+/, emit: :WORD)
          rule("!", emit: :PUNCTUATION)
          rule(/\\x00/, emit: :NUL)
          #{declarations}
        end
      RUBY
      scope = Module.new
      scope.module_eval(Flexr::Generator.new(spec).generate, spec, 1)
      scope.const_get(:GeneratedAutoAccelerationLexer, false)
    end
  end

  it "stays on the DFA for frozen, unguarded strings in auto mode" do
    lexer = generated_lexer(:auto).new(input)

    expect(lexer).not_to receive(:__flexr_generated_acceleration_region)
    expect(lexer.tokens).to eq(tokens)
  end

  it "emits a NUL byte at the end of frozen input" do
    lexer = generated_lexer(:auto).new("a\0")

    expect(lexer.tokens).to eq([[:WORD, "a"], [:NUL, "\0"]])
  end

  it "reuses the direct scan layout when a lexical state resumes" do
    declarations = <<~RUBY
      rule("@") { begin_state :inside }
      state :inside do
        rule("x", emit: :INSIDE)
        rule("!") { begin_state :initial }
      end
    RUBY
    lexer = generated_lexer(:auto, declarations: declarations).new("a@x!b")

    expect(lexer.next_token).to eq([:WORD, "a"])
    initial_layout = lexer.instance_variable_get(:@__flexr_generated_scan_layout)
    expect(initial_layout).to be_a(Array)
    expect(lexer.next_token).to eq([:INSIDE, "x"])
    expect(lexer.instance_variable_get(:@__flexr_generated_scan_layout)).not_to equal(initial_layout)
    expect(lexer.next_token).to eq([:WORD, "b"])
    expect(lexer.instance_variable_get(:@__flexr_generated_scan_layout)).to equal(initial_layout)
  end

  it "keeps the auto region path for streaming, borrowed strings, and runtime limits" do
    generated = generated_lexer(:auto)
    cases = [
      [StringIO.new(input), { chunk_size: 3, retain_input: false }],
      [input.dup, { freeze_input: false }],
      [input, { max_steps: 1000 }],
      [input, { max_token_size: 32 }]
    ]

    cases.each do |source, options|
      lexer = generated.new(source, **options)

      expect(lexer).to receive(:__flexr_generated_acceleration_region).at_least(:once).and_call_original
      expect(lexer.tokens).to eq(tokens)
    end
  end

  it "uses the frozen DFA path for a snapshot of mutable input" do
    lexer = generated_lexer(:auto).new(input.dup)

    expect(lexer).not_to receive(:__flexr_generated_acceleration_region)
    expect(lexer.tokens).to eq(tokens)
  end

  it "uses native scanning for explicitly accelerated frozen strings" do
    lexer = generated_lexer(:strscan).new(input)

    expect_any_instance_of(StringScanner).to receive(:skip).at_least(:once).and_call_original
    expect(lexer.tokens).to eq(tokens)
  end
end
