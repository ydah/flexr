# frozen_string_literal: true

require "json"
require_relative "flexr/version"
require_relative "flexr/errors"
require_relative "flexr/diagnostics"
require_relative "flexr/ir"
require_relative "flexr/regexp/ast"
require_relative "flexr/regexp/parser"
require_relative "flexr/regexp/normalizer"
require_relative "flexr/unicode/utf8_splitter"
require_relative "flexr/unicode/property"
require_relative "flexr/automaton/byte_class_set"
require_relative "flexr/automaton/nfa"
require_relative "flexr/automaton/dfa"
require_relative "flexr/automaton/compiler"
require_relative "flexr/runtime/location"
require_relative "flexr/runtime/token"
require_relative "flexr/runtime/interpreter"
require_relative "flexr/runtime/core"
require_relative "flexr/dsl"
require_relative "flexr/lexer"
require_relative "flexr/generated"
require_relative "flexr/source/static_eval"
require_relative "flexr/source/prism_reader"
require_relative "flexr/source/passthrough"
require_relative "flexr/generator"
require_relative "flexr/options"
require_relative "flexr/cli"

module Flexr
  class << self
    def compile_pattern(pattern, options: {})
      regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(pattern.to_s)
      ast = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: regexp.encoding).parse
      Regexp::Normalizer.new(ast, encoding: regexp.encoding, options: regexp.options).normalize
    end
  end
end
