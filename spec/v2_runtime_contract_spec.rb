# frozen_string_literal: true

require "stringio"

RSpec.describe "v2 runtime contracts" do
  it "uses immutable Data records with read-only indexing and replacement" do
    location = Flexr::Runtime::Location.new(byte_begin: 0, byte_end: 1, column_values: [1, 2])
    token = Flexr::Runtime::Token.new(type: :A, value: "a", location: location)
    expect(token).to be_a(Data)
    expect(location).to be_a(Data)
    expect([token[:type], token[1], token["location"], token[-1]])
      .to eq([:A, "a", location, location])
    expect { token[:type] = :B }.to raise_error(NoMethodError)
    expect { token.value = "b" }.to raise_error(NoMethodError)
    expect(token.with(value: "b").value).to eq("b")
    expect(token.value).to eq("a")
    expect([location.column_begin, location.column_end]).to eq([1, 2])
    expect(location.to_h).to include(column_begin: 1, column_end: 2)
    expect(location.with).to eq(location)
    expect(location.with(byte_begin: 9).column_end).to eq(2)
    expect(location.with(column_begin: nil).column_begin).to be_nil
    other_columns = Flexr::Runtime::Location.new(byte_begin: 0, byte_end: 1, column_values: [3, 4])
    expect(other_columns).not_to eq(location)
    expect(location.with.hash).to eq(location.hash)
    expect(Ractor.shareable?(location)).to be(true)
  end

  it "rejects unknown error modes before inspecting input" do
    lexer = Class.new(Flexr::Lexer) { rule(/a/, skip: true) }
    ["", "a", StringIO.new("a")].each do |input|
      expect { lexer.new(input, error_mode: :typo) }.to raise_error(ArgumentError, /unsupported error_mode/)
    end
  end

  it "rejects ABI 1 generated artifacts with regeneration advice" do
    artifact = Flexr::Generated.artifact_metadata.merge(schema_version: 1, runtime_abi_version: 1)
    expect { Flexr::Generated.validate_artifact!(artifact) }.to raise_error(Flexr::CompileError) do |error|
      expect(error.diagnostic.code).to eq("FLEXR-E020")
      expect(error.diagnostic.help).to include("regenerate")
    end
    expect(Flexr::Generated.artifact_metadata).to include(schema_version: 2, runtime_abi_version: 2)
  end

  %i[table direct auto firstmatch].each do |backend|
    it "shares generated #{backend} tables while keeping lexer instances local to each Ractor" do
      Dir.mktmpdir do |directory|
        source = File.join(directory, "ractor.flexr.rb")
        output = File.join(directory, "ractor.rb")
        File.write(source, <<~RUBY)
          class RactorGeneratedFixture < Flexr::Lexer
            backend :#{backend}
            #{'option :experimental' if backend == :firstmatch}
            token_kind :struct
            rule(/[a-z]+/) { emit :WORD }
            rule(/[0-9]+/) { emit :INT, text.to_i }
            rule(/ +/, skip: true)
          end
        RUBY
        Flexr::Generator.new(source, output: output).generate
        load output
        klass = RactorGeneratedFixture
        expect(Flexr::Generated.shareable!(klass)).to eq(klass)
        expect(Ractor.shareable?(klass.__flexr_compiled)).to be(true)
        workers = Array.new(2) do
          Ractor.new(klass) do |shared|
            shared.new("abc 12").tokens.map { |token| [token.type, token.value] }
          end
        end
        results = workers.map { |worker| worker.respond_to?(:value) ? worker.value : worker.take }
        expect(results).to eq(Array.new(2) { [[:WORD, "abc"], [:INT, 12]] })
      ensure
        Object.send(:remove_const, :RactorGeneratedFixture) if Object.const_defined?(:RactorGeneratedFixture, false)
      end
    end
  end

  it "rejects closure-based runtime specifications when requesting Ractor sharing" do
    lexer = Class.new(Flexr::Lexer) { rule(/a/) { emit :A } }
    expect { Flexr::Generated.shareable!(lexer) }.to raise_error(ArgumentError, /generated.*method actions/)
  end

  it "keeps interpolated strings bound to their captured locals and rejects sharing them" do
    Dir.mktmpdir do |directory|
      source = File.join(directory, "closure.flexr.rb")
      output = File.join(directory, "closure.rb")
      File.write(source, <<~'RUBY')
        class CapturedRactorFixture < Flexr::Lexer
          prefix = "captured"
          rule(/a/) { emit :A, "#{prefix}" }
        end
      RUBY
      Flexr::Generator.new(source, output: output).generate
      load output
      expect(CapturedRactorFixture.new("a").tokens).to eq([[:A, "captured"]])
      expect { Flexr::Generated.shareable!(CapturedRactorFixture) }.to raise_error(ArgumentError, /captured closures/)
    ensure
      Object.send(:remove_const, :CapturedRactorFixture) if Object.const_defined?(:CapturedRactorFixture, false)
    end
  end
end
