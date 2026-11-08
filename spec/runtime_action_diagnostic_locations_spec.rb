# frozen_string_literal: true

require "stringio"

RSpec.describe "runtime action diagnostic locations" do
  around do |example|
    Dir.mktmpdir("flexr-action-locations") do |directory|
      @path = File.join(directory, "lexer.flexr.rb")
      @input_path = File.join(directory, "input.txt")
      @input = "é\r\néab"
      File.binwrite(@input_path, @input)
      example.run
    end
  ensure
    Object.send(:remove_const, :ActionDiagnosticFixture) if Object.const_defined?(:ActionDiagnosticFixture, false)
  end

  def write_spec(action, eof: false)
    File.binwrite(@path, <<~RUBY)
      class ActionDiagnosticFixture < Flexr::Lexer
        rule(/é|\\r|\\n/, skip: true)
        rule(/[ab]/) { #{eof ? 'skip' : action} }
        #{"on_eof { #{action} }" if eof}
      end
    RUBY
  end

  {
    "push :missing" => "FLEXR-E003",
    "begin_state :missing" => "FLEXR-E003",
    "self.state = :missing" => "FLEXR-E003",
    "reject" => "FLEXR-E013"
  }.each do |action, code|
    it "locates #{action} at the current input position after streaming discards" do
      write_spec(action)
      load @path
      lexer = ActionDiagnosticFixture.new(StringIO.new(@input), filename: @input_path,
                                           chunk_size: 1, retain_input: false)

      expect { lexer.tokens }.to raise_error(Flexr::CompileError) do |error|
        expect(error).to be_instance_of(Flexr::CompileError)
        expect(error.diagnostic.code).to eq(code)
        expect(error.diagnostic.location).to eq([7, 7])
        expect([error.filename, error.byte_pos]).to eq([@input_path, 7])
        expect(lexer.buffer.base_offset).to eq(6)
      end
    end
  end

  it "locates a failing EOF action at the end of the input" do
    write_spec("push :missing", eof: true)
    load @path

    expect { ActionDiagnosticFixture.new(@input, filename: @input_path).tokens }
      .to raise_error(Flexr::CompileError) do |error|
        expect(error.diagnostic.location).to eq([@input.bytesize, @input.bytesize])
        expect(error.byte_pos).to eq(@input.bytesize)
      end
  end

  it "locates direct calls before and after scanning at the current cursor" do
    write_spec("skip")
    load @path
    lexer = ActionDiagnosticFixture.new(@input, filename: @input_path)

    expect { lexer.begin_state(:missing) }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.location).to eq([0, 0])
    end
    lexer.tokens
    expect { lexer.reject }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.location).to eq([@input.bytesize, @input.bytesize])
    end
  end

  def check(*args)
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(["check", @path, "--color", "never", *args], out: output, err: errors)
    expect(status).to eq(1)
    expect(output.string).to be_empty
    errors.string
  end

  { "push :missing" => "FLEXR-E003", "reject" => "FLEXR-E013" }.each do |action, code|
    it "renders #{code} against the input file when raised during eval" do
      write_spec(action)
      File.open(@path, "ab") do |file|
        file.puts "ActionDiagnosticFixture.new(#{@input.dump}, filename: #{@input_path.inspect}).tokens"
      end

      rendered = check("--eval")

      expect(rendered).to include("error[#{code}]", "  --> #{@input_path}:2:3\n", "2 | éab\n", "  |   ^\n")
      expect(rendered).not_to include(@path)
    end
  end

  it "does not use the specification as input context when the input has no filename" do
    write_spec("push :missing")
    File.open(@path, "ab") { |file| file.puts "ActionDiagnosticFixture.new(#{@input.dump}).tokens" }

    rendered = check("--eval")

    expect(rendered).to include("error[FLEXR-E003]")
    expect(rendered).not_to include("-->", @path)
  end

  it "keeps static reject errors tied to the specification" do
    write_spec("reject")

    rendered = check

    expect(rendered).to include("error[FLEXR-E013]", "  --> #{@path}:3:3\n", "3 |   rule(/[ab]/) { reject }\n")
    expect(rendered).not_to include(@input_path)
  end
end
