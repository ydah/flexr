# frozen_string_literal: true

class Lexer < Flexr::Lexer
  rule(/<<(?<tag>[A-Z_]+)\r?\n/) do
    body = scan_until_line(captures.fetch(:tag))
    if body
      emit :HEREDOC, body
    else
      error!("missing heredoc terminator")
    end
  end

  rule(/[a-z]+/, emit: :WORD)
  rule(/[ \t\r\n]+/, skip: true)
end
