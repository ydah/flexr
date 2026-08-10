# frozen_string_literal: true

RSpec.describe "acceleration contracts" do
  let(:input) { ("a" * 128).b }

  def runtime_lexer(accel)
    Class.new(Flexr::Lexer) do
      encoding Encoding::BINARY
      self.accel(accel)
      rule(/a+/) { emit :A }
      rule(/b/, followed_by: /c/) { emit :B }
    end
  end

  it "uses StringScanner for auto in the interpreter and preserves tokens" do
    auto = runtime_lexer(:auto)
    regexp = runtime_lexer(:regexp)

    allow(StringScanner).to receive(:new).and_call_original

    expect(auto.new(input).tokens).to eq(regexp.new(input).tokens)
    expect(StringScanner).to have_received(:new).at_least(:once)
  end

  it "uses StringScanner for auto in generated lexers and preserves tokens" do
    source_path = File.join(Dir.tmpdir, "flexr-auto-accel-#{Process.pid}.flexr.rb")
    output_path = "#{source_path}.generated.rb"
    File.write(source_path, <<~RUBY)
      require "flexr"

      class GeneratedAccelerationContractFixture < Flexr::Lexer
        encoding Encoding::BINARY
        accel :auto
        rule(/a+/) { emit :A }
        rule(/b/, followed_by: /c/) { emit :B }
      end
    RUBY

    Flexr::Generator.new(source_path, output: output_path).generate
    load output_path
    regexp = runtime_lexer(:regexp)

    allow(StringScanner).to receive(:new).and_call_original

    expect(GeneratedAccelerationContractFixture.new(input).tokens)
      .to eq(regexp.new(input).tokens)
    expect(StringScanner).to have_received(:new).at_least(:once)
  ensure
    Object.send(:remove_const, :GeneratedAccelerationContractFixture) if
      Object.const_defined?(:GeneratedAccelerationContractFixture, false)
    FileUtils.rm_f(source_path) if source_path
    FileUtils.rm_f(output_path) if output_path
  end

  it "falls back to regexp acceleration when StringScanner is unavailable" do
    hide_const("StringScanner")

    expect(runtime_lexer(:auto).new(input).tokens).to eq(runtime_lexer(:regexp).new(input).tokens)
  end
end
