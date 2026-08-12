# frozen_string_literal: true

require "json"
require "digest"
require_relative "flexr/artifact_writer"
require_relative "flexr/version"
require_relative "flexr/errors"
require_relative "flexr/diagnostics"
require_relative "flexr/ir"
require_relative "flexr/regexp/ast"
require_relative "flexr/regexp/parser"
require_relative "flexr/regexp/normalizer"
require_relative "flexr/regexp/unsupported"
require_relative "flexr/regexp/char_class"
require_relative "flexr/unicode/utf8_splitter"
require_relative "flexr/unicode/data/properties"
require_relative "flexr/unicode/data/case_folding"
require_relative "flexr/unicode/property"
require_relative "flexr/unicode/reference_regexp"
require_relative "flexr/unicode/case_fold"
require_relative "flexr/automaton/byte_class_set"
require_relative "flexr/automaton/nfa"
require_relative "flexr/automaton/dfa"
require_relative "flexr/automaton/compiler"
require_relative "flexr/automaton/analysis"
require_relative "flexr/automaton/minimizer"
require_relative "flexr/automaton/accel"
require_relative "flexr/codegen/base"
require_relative "flexr/codegen/table"
require_relative "flexr/codegen/direct"
require_relative "flexr/codegen/firstmatch"
require_relative "flexr/codegen/table_packer"
require_relative "flexr/runtime/location"
require_relative "flexr/runtime/token"
require_relative "flexr/runtime/buffer"
require_relative "flexr/runtime/errors"
require_relative "flexr/runtime/interpreter"
require_relative "flexr/runtime/core"
require_relative "flexr/dsl"
require_relative "flexr/lexer"
require_relative "flexr/generated"
require_relative "flexr/source/static_eval"
require_relative "flexr/source/prism_reader"
require_relative "flexr/source/passthrough"
require_relative "flexr/importer"
require_relative "flexr/generator"
require_relative "flexr/options"
require_relative "flexr/rake_task"
require_relative "flexr/cli"

module Flexr
  class << self
    def compile_pattern(pattern, options: {})
      regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(pattern.to_s)
      return Automaton::ReferenceDFA.new(regexp, unicode: options[:unicode] == true) if
        reference_pattern?(regexp, unicode: options[:unicode] == true)
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
