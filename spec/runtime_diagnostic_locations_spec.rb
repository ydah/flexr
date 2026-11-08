# frozen_string_literal: true

require "stringio"

RSpec.describe "runtime diagnostic locations" do
  around do |example|
    Dir.mktmpdir("flexr-runtime-locations") do |directory|
      @path = File.join(directory, "lexer.flexr.rb")
      @generated_path = File.join(directory, "lexer.rb")
      @input_path = File.join(directory, "input.txt")
      @input = "é\r\néaaaa"
      File.binwrite(@input_path, @input)
      File.binwrite(@path, <<~'RUBY')
        class RuntimeDiagnosticFixture < Flexr::Lexer
          rule(/é|\r|\n/, skip: true)
          rule(/a+/, skip: true)
        end
      RUBY
      example.run
    end
  ensure
    Object.send(:remove_const, :RuntimeDiagnosticFixture) if Object.const_defined?(:RuntimeDiagnosticFixture, false)
  end

  {
    TokenTooLargeError: "FLEXR-E012", NonProgressError: "FLEXR-E021",
    BufferTooLargeError: "FLEXR-E022", StepLimitError: "FLEXR-E023",
    LookaheadTooLargeError: "FLEXR-E024", StateStackOverflowError: "FLEXR-E025",
    CancelledError: "FLEXR-E026", InvalidRecoveryActionError: "FLEXR-E027"
  }.each do |name, code|
    it "reports #{code} at the supplied input offset and leaves unknown offsets absent" do
      error_class = Flexr::Runtime.const_get(name)
      options = name == :InvalidRecoveryActionError ? { action: :continue } : {}
      error = error_class.new(**options, filename: "input.txt", byte_pos: 0)
      set = Flexr::DiagnosticSet.new << error.diagnostic

      expect(JSON.parse(set.render(format: :json)).first).to include("code" => code, "location" => [0, 0])
      expect(error_class.new(**options).diagnostic.to_h).not_to have_key(:location)
    end
  end

  %i[runtime generated].each do |mode|
    it "renders absolute input coordinates after streaming discards in #{mode} mode" do
      if mode == :generated
        Flexr::Generator.new(@path, output: @generated_path).generate
        load @generated_path
      else
        load @path
      end
      lexer = RuntimeDiagnosticFixture.new(StringIO.new(@input), filename: @input_path,
                                            chunk_size: 1, max_token_size: 2, retain_input: false)

      expect { lexer.tokens }.to raise_error(Flexr::Runtime::TokenTooLargeError) do |error|
        expect(lexer.buffer.base_offset).to eq(6)
        expect(error.byte_pos).to eq(6)
        expect(error.diagnostic.location).to eq([6, 6])
        set = Flexr::DiagnosticSet.new << error.diagnostic
        expect(set.render(color: :never, source: @input, path: error.filename)).to eq(<<~TEXT.chomp)
          error[FLEXR-E012]: token exceeds max_token_size
            --> #{@input_path}:2:2
            |
          2 | éaaaa
            |  ^
            help: increase max_token_size or split the input token
            note: rule 1 at byte 6
        TEXT
      end
    end
  end

  def check_with_runtime_error(filename, *args)
    File.open(@path, "a") do |file|
      file.puts "RuntimeDiagnosticFixture.new(#{@input.dump}, filename: #{filename.inspect}, max_token_size: 2).tokens"
    end
    output = StringIO.new
    errors = StringIO.new
    status = Flexr::CLI.run(["check", @path, "--eval", "--color", "never", *args], out: output, err: errors)
    expect(status).to eq(1)
    expect(output.string).to be_empty
    errors.string
  end

  it "renders CLI runtime failures against the input file without normalizing CRLF" do
    rendered = check_with_runtime_error(@input_path)

    expect(rendered).to include("error[FLEXR-E012]", "  --> #{@input_path}:2:2\n", "2 | éaaaa\n", "  |  ^\n")
    expect(rendered).not_to include(@path)
  end

  it "keeps absolute input offsets in CLI JSON" do
    rendered = check_with_runtime_error(@input_path, "--format", "json")

    expect(JSON.parse(rendered).first).to include("code" => "FLEXR-E012", "location" => [6, 6])
  end

  it "keeps CLI reporting bounded when a guard fails on a large input file" do
    @input += "a" * (64 * 1024)
    File.binwrite(@input_path, @input)

    rendered = check_with_runtime_error(@input_path)

    expect(rendered).to include("error[FLEXR-E012]", "note: rule 1 at byte 6")
    expect(rendered).not_to include("-->")
  end

  [nil, "missing.txt"].each do |filename|
    it "omits the excerpt instead of using the specification when input filename is #{filename.inspect}" do
      path = filename && File.join(File.dirname(@path), filename)
      rendered = check_with_runtime_error(path)

      expect(rendered).to include("error[FLEXR-E012]", "help: increase max_token_size")
      expect(rendered).not_to include("-->", @path)
    end
  end
end
