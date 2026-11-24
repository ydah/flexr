# frozen_string_literal: true

require "stringio"
require_relative "../errors"

module Flexr
  module Grammar
    module Lrama
      CHARACTER_ESCAPES = {
        "\\a" => 7, "\\b" => 8, "\\f" => 12, "\\n" => 10, "\\r" => 13, "\\t" => 9, "\\v" => 11,
        '\\"' => 34, "\\'" => 39, "\\?" => 63, "\\\\" => 92
      }.freeze
      private_constant :CHARACTER_ESCAPES

      module_function

      def read(path)
        load_lrama
        source = File.read(path)
        terminal_rows(build_states(source, path.to_s))
      end

      def load_lrama
        require "lrama"
        return if /\A0\.8\./.match?(::Lrama::VERSION)

        raise CompileError, "parser-state generation requires Lrama 0.8.x, found #{::Lrama::VERSION}"
      rescue LoadError => e
        raise CompileError, "parser-state generation requires the optional lrama 0.8 gem (#{e.message})"
      end

      def build_states(source, path)
        grammar = ::Lrama::Parser.new(source, path).parse
        unless grammar.no_stdlib
          stdlib_path = ::Lrama::Command::STDLIB_FILE_PATH
          stdlib = ::Lrama::Parser.new(File.read(stdlib_path), stdlib_path).parse
          grammar.prepend_parameterized_rules(stdlib.parameterized_rules)
        end
        grammar.prepare
        grammar.validate!

        log = StringIO.new
        states = ::Lrama::States.new(grammar, ::Lrama::Tracer.new(log))
        states.compute
        states.compute_ielr if grammar.ielr_defined?
        validate_conflicts(states, log)
        states
      rescue StandardError => e
        raise CompileError.new("cannot build Lrama parser states: #{e.message}", filename: path)
      end

      def validate_conflicts(states, log)
        states.validate!(::Lrama::Logger.new(log))
      rescue SystemExit
        raise CompileError, log.string.strip
      end

      def terminal_rows(states)
        context = ::Lrama::Context.new(states)
        checks = context.yycheck
        actions = context.yytable
        terms = states.terms.to_h { |term| [term.token_id, term] }.values.filter_map do |term|
          next if term.eof_symbol? || term.error_symbol? || term.undef_symbol?

          [term.number, token_kind(term)]
        end

        context.yypact.map.with_index do |base, state|
          terms.filter_map do |number, kind|
            position = base + number
            action = if base != context.yypact_ninf && position.between?(0, context.yylast) && checks[position] == number
              actions.fetch(position)
            else
              -context.yydefact.fetch(state)
            end
            kind if action != 0 && action != context.yytable_ninf
          end.uniq.freeze
        end.freeze
      end

      def token_kind(term)
        return term.name.to_sym unless term.name.start_with?("'")

        literal = term.name[1...-1]
        code = case literal
        when /\A\\([0-7]{1,3})\z/
          Integer(Regexp.last_match(1), 8)
        when /\A\\[xuU]([0-9a-fA-F]+)\z/
          Integer(Regexp.last_match(1), 16)
        else
          CHARACTER_ESCAPES.fetch(literal) { literal.getbyte(0) }
        end
        code.chr(Encoding::BINARY).to_sym
      end

      private_class_method :load_lrama, :build_states, :validate_conflicts, :terminal_rows, :token_kind
    end
  end
end
