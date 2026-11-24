# frozen_string_literal: true

require "flexr"

module PushStreamExamples
  class HttpHeaderLexer < Flexr::Lexer
    encoding Encoding::BINARY

    rule(%r{[A-Z]+ [^ \r\n]+ HTTP/1\.[01]\r\n}) do
      emit :REQUEST_LINE, text.delete_suffix("\r\n")
      begin_state :headers
    end

    state :headers do
      rule(/[A-Za-z0-9-]+:[^\r\n]*\r\n/) { emit :HEADER, text.delete_suffix("\r\n") }
      rule("\r\n", emit: :HEADERS_END)
    end
  end

  class RespLineLexer < Flexr::Lexer
    encoding Encoding::BINARY

    rule(/\+[^\r\n]*\r\n/) { emit :STRING, text.byteslice(1...-2) }
    rule(/-[^\r\n]*\r\n/) { emit :ERROR, text.byteslice(1...-2) }
    rule(/:[+-]?[0-9]+\r\n/) { emit :INTEGER, text.byteslice(1...-2).to_i }
  end

  class EventStreamLexer < Flexr::Lexer
    rule(/[^\r\n]+(?:\r\n|\r|\n)/) { emit :LINE, text.sub(/\r\n?\z|\n\z/, "") }
    rule(/\r\n|\r|\n/, emit: :EVENT_END)
  end

  def self.show_tokens(type, chunks)
    lexer = type.push
    chunks.each { |bytes| lexer.feed(bytes) { |token| p token } }
    lexer.finish { |token| p token }
  end
end

if $PROGRAM_NAME == __FILE__
  PushStreamExamples.show_tokens(PushStreamExamples::HttpHeaderLexer, ["GET / HT", "TP/1.1\r\nHost: example", ".test\r\n\r", "\n"])
  PushStreamExamples.show_tokens(PushStreamExamples::RespLineLexer, ["+O", "K\r\n:4", "2\r", "\n"])
  PushStreamExamples.show_tokens(PushStreamExamples::EventStreamLexer, ["data: he", "llo\n", "\n"])
end
