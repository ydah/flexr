# frozen_string_literal: true

raise LoadError, "flexr 2.0 requires Ruby 3.4 or newer" if RUBY_VERSION < "3.4"

require "json"
require "monitor"
require_relative "version"
require_relative "errors"
require_relative "diagnostics"
require_relative "action_resolver"
require_relative "configuration"
require_relative "ir"
require_relative "pattern"
require_relative "unicode/version"
require_relative "regexp/ast"
require_relative "regexp/parser"
require_relative "regexp/normalizer"
require_relative "regexp/unsupported"
require_relative "regexp/char_class"
require_relative "unicode/utf8_splitter"
require_relative "unicode/data"
require_relative "unicode/property"
require_relative "unicode/property_automata"
require_relative "unicode/reference_regexp"
require_relative "unicode/case_fold"
require_relative "regexp/matcher"
require_relative "automaton/types"
require_relative "automaton/end_context"
require_relative "automaton/left_context"
require_relative "automaton/byte_class_set"
require_relative "automaton/nfa"
require_relative "automaton/dfa"
require_relative "runtime/contextual_regexp"
require_relative "automaton/contextual_regexp_compiler"
require_relative "automaton/reference_dfa"
require_relative "automaton/compiler"
require_relative "automaton/analysis"
require_relative "automaton/minimizer"
require_relative "automaton/backend_cost_model"
require_relative "automaton/accel"
require_relative "runtime/record"
require_relative "runtime/location"
require_relative "runtime/token"
require_relative "runtime/buffer"
require_relative "runtime/errors"
require_relative "runtime/firstmatch"
require_relative "runtime/interpreter"
require_relative "runtime/recognizer"
require_relative "runtime/core"
require_relative "runtime/backup_memo"
require_relative "runtime/checkpoint"
require_relative "runtime/input_stack"
require_relative "runtime/indentation"
require_relative "runtime/channels"
require_relative "runtime/captures"
require_relative "runtime/delegation"
require_relative "runtime/delimiters"
require_relative "dsl"
require_relative "runtime/lazy_compilation"
require_relative "keywords"
require_relative "lexer"
require_relative "rules"
require_relative "generated"
require_relative "automaton/lookahead"


module Flexr
  class << self
    attr_reader :cache_dir

    def cache_dir=(directory)
      if directory.nil?
        @cache_dir = nil
      else
        require_relative "automaton/dfa_cache"
        @cache_dir = File.expand_path(directory).freeze
      end
    end

    def compile_pattern(pattern, options: {}, encoding: nil)
      pattern = ::Regexp.new(pattern.to_s) unless pattern.is_a?(::Regexp) || pattern.is_a?(Pattern)
      encoding ||= pattern.is_a?(::Regexp) && pattern.encoding == Encoding::BINARY ? Encoding::BINARY : Encoding::UTF_8
      rule = IR::Rule.new(index: 0, patterns: [pattern], action: :skip, states: [:initial])
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
