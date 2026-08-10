---
title: Getting started
description: Build and run your first flexr lexer, then compare runtime and generated output.
---

flexr is a Ruby-native lexer generator. You write rules in a Ruby class, run the specification directly during development, and generate Ruby when deployment benefits from a deterministic artifact.

## Install

```sh
gem install flexr
```

## Write a specification

Create `lexer.flexr.rb`:

```ruby
class Lexer < Flexr::Lexer
  emits :INTEGER, :PLUS, :EQ, :ASSIGN, :IF, :IDENT

  rule(/[ \t\n]+/, skip: true)
  rule(/[0-9]+/) { emit :INTEGER, text.to_i }
  rule(/==/) { emit :EQ }
  rule(/=/) { emit :ASSIGN }
  rule(/if/) { emit :IF }
  rule(/[a-z_][a-z0-9_]*/) { emit :IDENT }
end
```

`==` wins over `=` because it consumes more input. `if` wins over the identifier rule for the same reason that a rule defined first wins when match lengths are equal.

## Run it

```ruby
require 'flexr'
require_relative 'lexer.flexr'

lexer = Lexer.new('if total == 42')
p lexer.each_token.to_a
```

Validate the specification before handing tokens to a parser:

```sh
bundle exec flexr check lexer.flexr.rb
```

## Generate Ruby

```sh
bundle exec flexr generate lexer.flexr.rb -o lexer.rb
ruby -I. -e "require './lexer'; p Lexer.new('if total == 42').each_token.to_a"
```

The [runtime guide](/flexr/learn/runtime-mode/) and [generation guide](/flexr/learn/generation/) cover the deployment trade-off. The repository contains a complete [calculator tutorial](https://github.com/ydah/flexr/blob/main/docs/tutorial/build-a-calculator-lexer.md).
