class CalculatorParser
  token INTEGER PLUS MINUS

  rule
    expression
      : INTEGER                  { result = val[0] }
      | expression PLUS INTEGER  { result = val[0] + val[2] }
      | expression MINUS INTEGER { result = val[0] - val[2] }
  end

---- inner
  def parse(lexer)
    @lexer = lexer
    do_parse
  end

  def next_token
    @lexer.racc_next_token
  end
