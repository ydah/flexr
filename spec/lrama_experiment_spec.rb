# frozen_string_literal: true

RSpec.describe "standalone grammar recognizer experiment" do
  it "generates a standalone recognizer without requiring Lrama" do
    require_relative "../benchmark/lrama_lexer"
    lexer = Flexr::Benchmarking::LramaLexer.recognizer([
      [/%token/, :DIRECTIVE], [/[A-Za-z_][A-Za-z_0-9]*/, :IDENTIFIER], [/[0-9]+/, :INTEGER]
    ])
    instance = lexer.new("%tokenINT12")
    expect(instance.next_token).to eq([:DIRECTIVE, "%token"])
    expect(instance.next_token).to eq([:IDENTIFIER, "INT12"])
    expect(instance.next_token).to be_nil
  end
end
