# frozen_string_literal: true

require_relative "../tools/golden"

RSpec.describe FlexrVerification::Golden do
  let(:spec_source) do
    <<~RUBY
      # frozen_string_literal: true
      class GoldenFixture < Flexr::Lexer
        rule(/a/) { emit :A }
      end
    RUBY
  end

  around do |example|
    Dir.mktmpdir("flexr-golden-") do |directory|
      @spec_path = File.join(directory, "lexer.flexr.rb")
      File.binwrite(@spec_path, spec_source)
      example.run
    end
  end

  def generated_source
    Flexr::Generator.new(@spec_path).generate
  end

  it "keeps snapshots stable when only the compiler version changes" do
    before = generated_source
    stub_const("Flexr::VERSION", "99.0.0")
    after = generated_source

    expect(after).not_to eq(before)
    expect(described_class.normalize(after)).to eq(described_class.normalize(before))
  end

  %w[schema_version runtime_abi_version unicode_version].each do |field|
    it "retains changes to #{field}" do
      before = generated_source
      after = before.sub(/#{field}: (?:\d+|"[^"]+")/, "#{field}: 99")

      expect(after).not_to eq(before)
      expect(described_class.normalize(after)).not_to eq(described_class.normalize(before))
    end
  end

  { "pattern" => ["/a/", "/b/"], "action" => ["emit :A", "emit :B"] }.each do |name, (before_text, after_text)|
    it "retains changes to the #{name}" do
      before = generated_source
      File.binwrite(@spec_path, spec_source.sub(before_text, after_text))

      expect(described_class.normalize(generated_source)).not_to eq(described_class.normalize(before))
    end
  end

  it "preserves Unicode and metadata-like text in user constants and heredocs" do
    source = <<~RUBY
      # frozen_string_literal: true
      class GoldenFixture < Flexr::Lexer
        NOTE = '日本語 compiler_version: "2.0.0"'
        TEXT = <<~'TEXT'
          # spec-digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
          Flexr::Generated.install_compiled!(self, { artifact: { compiler_version: "2.0.0" } })
        TEXT
        rule(/a/) { emit :A, NOTE }
      end
    RUBY
    File.binwrite(@spec_path, source)
    before = described_class.normalize(generated_source)

    expect(before).to include('日本語 compiler_version: "2.0.0"', "# spec-digest: sha256:#{'a' * 64}")
    expect(before).to include('artifact: { compiler_version: "2.0.0" }')
    expect(before.valid_encoding?).to be(true)
    File.binwrite(@spec_path, source.sub("日本語", "変更"))
    expect(described_class.normalize(generated_source)).not_to eq(before)
  end

  it "normalizes Windows line endings" do
    source = generated_source

    expect(described_class.normalize(source.gsub("\n", "\r\n"))).to eq(described_class.normalize(source))
  end

  it "rejects a missing compiler version instead of masking a malformed artifact" do
    source = generated_source.sub(/compiler_version: "[^"]+", /, "")

    expect { described_class.normalize(source) }.to raise_error(ArgumentError, /compiler version/)
  end

  it "rejects ambiguous generated installations" do
    source = "#{generated_source}\nFlexr::Generated.install_compiled!(self, {})\n"

    expect { described_class.normalize(source) }.to raise_error(ArgumentError, /one generated installation/)
  end

  it "rejects invalid Ruby instead of producing a golden snapshot" do
    expect { described_class.normalize("#{generated_source}(") }.to raise_error(ArgumentError, /invalid generated Ruby/)
  end

  it "rejects a missing digest header" do
    source = generated_source.sub(/^# spec-digest:.*\n/, "")

    expect { described_class.normalize(source) }.to raise_error(ArgumentError, /digest header/)
  end
end
