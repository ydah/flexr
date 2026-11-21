# frozen_string_literal: true

require "stringio"

RSpec.describe "language lexer examples" do
  {
    "toml" => ["TomlExample::Lexer", 'title = "flexr" # config', [[:NAME, "title"], [:EQUAL, "="], [:STRING, '"flexr"']]],
    "graphql" => ["GraphqlExample::Lexer", 'query { user(id: 12) { name } }', [
      [:NAME, "query"], [:LBRACE, "{"], [:NAME, "user"], [:LPAREN, "("], [:NAME, "id"], [:COLON, ":"],
      [:NUMBER, "12"], [:RPAREN, ")"], [:LBRACE, "{"], [:NAME, "name"], [:RBRACE, "}"], [:RBRACE, "}"]]],
    "sql" => ["SqlExample::Lexer", "select name from users where id >= 12; -- query", [
      [:KEYWORD, "SELECT"], [:NAME, "name"], [:KEYWORD, "FROM"], [:NAME, "users"], [:KEYWORD, "WHERE"],
      [:NAME, "id"], [:OPERATOR, ">="], [:NUMBER, "12"], [:SEMICOLON, ";"]]]
  }.each do |name, (constant, input, expected)|
    it "keeps #{name} tokens identical in runtime and generated modes" do
      path = File.expand_path("../examples/#{name}/lexer.flexr.rb", __dir__)
      runtime = Module.new
      runtime.module_eval(File.read(path), path)
      generated = Module.new
      generated.module_eval(Flexr::Generator.new(path).generate, path)
      [runtime, generated].each do |scope|
        lexer = constant.split("::").inject(scope) { |parent, part| parent.const_get(part, false) }
        expect(lexer.new(input).tokens).to eq(expected)
        expect(lexer.new(StringIO.new(input), chunk_size: 1).tokens).to eq(expected)
        expect(lexer.compile!.diagnostics.reject { |diagnostic| diagnostic.code == "FLEXR-W016" }).to be_empty
      end
    end
  end
end
