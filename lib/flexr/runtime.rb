# frozen_string_literal: true

require "json"
require "monitor"
require_relative "version"
require_relative "errors"
require_relative "diagnostics"
require_relative "action_resolver"
require_relative "configuration"
require_relative "ir"
require_relative "unicode/version"
require_relative "regexp/ast"
require_relative "regexp/parser"
require_relative "regexp/normalizer"
require_relative "regexp/unsupported"
require_relative "regexp/char_class"
require_relative "unicode/utf8_splitter"
require_relative "unicode/data"
require_relative "unicode/property"
require_relative "unicode/reference_regexp"
require_relative "unicode/case_fold"
require_relative "automaton/types"
require_relative "automaton/byte_class_set"
require_relative "automaton/nfa"
require_relative "automaton/dfa"
require_relative "automaton/compiler"
require_relative "automaton/analysis"
require_relative "automaton/minimizer"
require_relative "automaton/backend_cost_model"
require_relative "automaton/accel"
require_relative "runtime/location"
require_relative "runtime/token"
require_relative "runtime/buffer"
require_relative "runtime/errors"
require_relative "runtime/interpreter"
require_relative "runtime/core"
require_relative "dsl"
require_relative "lexer"
require_relative "generated"

module Flexr
  class << self
    def compile_pattern(pattern, options: {})
      regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(pattern.to_s)
      encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : Encoding::UTF_8
      rule = IR::Rule.new(index: 0, patterns: [regexp], action: :skip, states: [:initial])
      state = IR::State.new(name: :initial, inclusive: true, id: 0)
      spec = IR::Spec.new(
        class_name: "Pattern", backend: :table, token_kind: :array,
        encoding: encoding, options: options, declared_tokens: [],
        states: { initial: state }, rules: [rule], eof_rules: {}, verbatim: nil
      )
      Automaton::Compiler.new(spec).compile.machines.fetch(:initial).dfa
    end

    def reference_pattern?(regexp, unicode: false)
      return true if regexp.source.match?(/\\[pP]\{/) || regexp.source.match?(/\[:(?:\^)?[a-z]+:\]/)

      unicode && regexp.encoding != Encoding::BINARY && regexp.source.match?(/\\[dDwWsS]/)
    end

    def parse_pattern(pattern, options: {})
      regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(pattern.to_s)
      encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : Encoding::UTF_8
      ast = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding,
                               unicode: options[:unicode] == true).parse
      Regexp::Normalizer.new(ast, encoding: encoding, options: regexp.options).normalize
    end
  end
end
