# frozen_string_literal: true

RSpec.describe "Unicode source generation" do
  it "applies replacement and insertion offsets in bytes while preserving UTF-8" do
    rewritten = Flexr::Source::Passthrough.rewrite("前abc後", [[3, 6, "語"]], insertion: 6, payload: "界")
    expect(rewritten).to eq("前語界後")
    expect(rewritten.encoding).to eq(Encoding::UTF_8)
    expect(rewritten.valid_encoding?).to be(true)
    expect(Flexr::Source::Passthrough.insert_after_preamble("# frozen_string_literal: true\n前\n", "語\n"))
      .to eq("# frozen_string_literal: true\n語\n前\n")
  end

  [false, true].each do |standalone|
    it "preserves Unicode actions and surrounding constants with standalone=#{standalone}" do
      Dir.mktmpdir do |directory|
        path = File.join(directory, "lexer.flexr.rb")
        source = <<~RUBY
          # frozen_string_literal: true
          class UnicodeGenerationFixture < Flexr::Lexer
            NOTE = "日本語"
            rule(/é/) { emit :WORD, "あ" }
          end
        RUBY
        File.binwrite(path, source)
        generated = Flexr::Generator.new(path, options: { standalone: standalone }).generate
        scope = Module.new
        scope.module_eval(generated, path)
        expect(scope::UnicodeGenerationFixture::NOTE).to eq("日本語")
        expect(scope::UnicodeGenerationFixture.new("é").tokens).to eq([[:WORD, "あ"]])
        expect(generated.encoding).to eq(Encoding::UTF_8)
      end
    end
  end
end
