# frozen_string_literal: true

require "flexr"

module PublicApiTypecheck
  module SharedRules
    extend Flexr::Rules
    rule(/#[^\n]*/, channel: :comment)
  end

  class Cancellation
    def call
      false
    end
  end

  class ContextCancellation
    def call(lexer)
      lexer.byte_pos > 100
    end
  end

  class ErrorHandler
    def call(error)
      error.message.empty? ? :skip : :token
    end
  end

  class EmbeddedLexer < Flexr::Lexer
    rule(/[a-z]+/, emit: :IDENT)
  end
end

Flexr.cache_dir = "tmp/flexr-cache"
Flexr.cache_dir = nil
Flexr::Lexer.rule(/[0-9]+/, emits: [:INTEGER]) { emit :INTEGER, text.to_i }
Flexr::Lexer.rule(/(?<value>[0-9]+)mm/) do
  # @type var value: String?
  value = captures[:value]
  emit :LENGTH, value
end
Flexr::Lexer.state(:quoted) { rule(/x/, emit: :X) }
Flexr::Lexer.all_states { rule(/ /, skip: true) }
Flexr::Lexer.on_eof { skip }
Flexr::Lexer.emits(:INTEGER, :X)
Flexr::Lexer.use(PublicApiTypecheck::SharedRules)
Flexr::Lexer.rule(/[a-z]+/, emit: :IDENT)
Flexr::Lexer.keywords(%w[if else], among: :IDENT)
Flexr::Lexer.keywords({ "yes" => :TRUE, "true" => :TRUE }, among: :IDENT)
Flexr::Lexer.indentation(newline: :NEWLINE, indent: :INDENT, dedent: :DEDENT, brackets: ["()"], tab_width: 4)
Flexr::Lexer.backend(:table)
Flexr::Lexer.token_kind(:array)
Flexr::Lexer.encoding(Encoding::UTF_8)
Flexr::Lexer.option(:unicode)
Flexr::Lexer.accel(:none)
word = Flexr::Lexer.pattern(/[a-z]+/)
reserved = Flexr::Lexer.pattern(%w[if end])
# @type var named_word: Flexr::Pattern
named_word = (word - reserved) & Flexr::Lexer.pattern(/.{1,8}/)
Flexr::Lexer.rule(named_word | ".")
Flexr::Lexer.rule(Flexr::Lexer.pattern("<") + Flexr::Lexer.upto(">"), skip: true)
Flexr::Lexer.rule(/<(?<embedded>[a-z]+)>/) { delegate PublicApiTypecheck::EmbeddedLexer, capture: :embedded }
Flexr::Lexer.rule("<<") { emit :INLINE, scan_until(">>") }
Flexr::Lexer.rule("<<TAG\n") { emit :HEREDOC, scan_until_line("TAG") }

lexer = Flexr::Lexer.new("12", filename: "input.txt", max_steps: 1000)
Flexr::Lexer.new(+"12", freeze_input: false)
Flexr::Lexer.new("12", cancellation: -> { false })
Flexr::Lexer.new("12", cancellation: ->(current) { current.byte_pos > 100 })
Flexr::Lexer.new("12", cancellation: false.method(:!))
Flexr::Lexer.new("12", cancellation: PublicApiTypecheck::Cancellation.new)
Flexr::Lexer.new("12", cancellation: PublicApiTypecheck::ContextCancellation.new)
lexer.on_error = ->(_error) { :skip }
lexer.on_error = PublicApiTypecheck::ErrorHandler.new
lexer.on_error = PublicApiTypecheck::ErrorHandler.new.method(:call)
lexer.on_error = lambda do |error|
  if (continuation = error.continuation)
    puts continuation.byte_pos, continuation.expected_bytes, continuation.suffix, continuation.eof
  end
  :skip
end
lexer.on_error = nil
# @type var bookmark: Flexr::Runtime::Checkpoint
bookmark = lexer.checkpoint
lexer.seek(1).restore(bookmark)
lexer.push_input("included", filename: "defaults.txt")
# @type var tokens: Array[Flexr::token]
tokens = lexer.tokens
# @type var byte_position: Integer
byte_position = lexer.byte_pos
# @type var location: Flexr::Runtime::Location
location = lexer.last_location
# @type var column: Integer?
column = location.column_begin
# @type var next_token: Flexr::token?
next_token = lexer.next_token(expect: [:INTEGER])
lexer.racc_next_token(expect: [:INTEGER])
lexer.each_token { |_token| nil }

# @type var stream: Flexr::Runtime::Push
stream = Flexr::Lexer.push(filename: "stream.txt", chunk_size: 4)
# @type var streamed: Array[Flexr::token]
streamed = stream.feed("12")
stream.feed(" ") { |_token| nil }.finish { |_token| nil }
puts streamed

# @type var document: Flexr::Runtime::Incremental
document = PublicApiTypecheck::EmbeddedLexer.incremental("alpha", filename: "editor.txt")
PublicApiTypecheck::EmbeddedLexer.parallel_tokens("alpha", workers: 1, filename: "editor.txt")
revision = document.relex(Flexr::Runtime::Edit.new(start_byte: 0, end_byte: 5, replacement: "beta"))
puts revision.input, revision.tokens

# @type var structured_token: Flexr::Runtime::Token
structured_token = Flexr::Runtime::Token.new(type: :INTEGER, value: 12, location: location)
# @type var immutable_record: Data
immutable_record = structured_token
# @type var replacement: Flexr::Runtime::Token
replacement = structured_token.with(value: 13)
# @type var token_location: Flexr::Runtime::Location?
token_location = structured_token[:location]
# @type var relocated: Flexr::Runtime::Location
relocated = location.with(byte_begin: 1)
puts immutable_record, replacement, token_location, relocated

diagnostic = Flexr::Diagnostics.error("FLEXR-E001", "invalid pattern", location: [0, 1])
set = Flexr::DiagnosticSet.new << diagnostic
# @type var rendered: String
rendered = set.render(format: :json)
# @type var generation: String
generation = Flexr::Generator.new("lexer.flexr.rb").generate
# @type var status: Integer
status = Flexr::CLI.run(["check", "lexer.flexr.rb"])
# @type var accepted: bool
accepted = Flexr.compile_pattern(/a/).accept?("a")
recognizer = Flexr::Lexer.recognizer
# @type var match: [Flexr::rule_identity, Integer]?
match = recognizer.match("12", 0)
# @type var ending: Integer?
ending = recognizer.match("12", 0) { |_rule, finish| finish }
puts tokens, byte_position, column, next_token, rendered, generation, status, accepted, match, ending
