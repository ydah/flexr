# frozen_string_literal: true

RSpec.describe "embedded grammar recognizer experiment" do
  it "recognizes grammar tokens by byte offset without a lexer instance" do
    require_relative "../benchmark/lrama_lexer"
    recognizer = Flexr::Benchmarking::LramaLexer.recognizer([
      ["%{", :SYMBOL], [/[A-Za-z_][A-Za-z_0-9]*/, :IDENTIFIER], [/[0-9]+/, :INTEGER]
    ])

    expect(recognizer).to be_a(Flexr::Recognizer)
    input = 'é%{INT12 "text" 42'
    expect(recognizer.match(input, 2)).to eq([:SYMBOL, 4])
    expect(recognizer.match(input, 4)).to eq([:IDENTIFIER, 9])
    expect(recognizer.match(input, 10)).to be_nil
    expect(recognizer.match(input, 17)).to eq([:INTEGER, 19])
    expect(recognizer.match(input, 2)).to eq([:SYMBOL, 4])
  end
end
