# frozen_string_literal: true

begin
  require "prism"
rescue LoadError
  raise Flexr::CompileError, "Prism is required for oedipus_lex import. Install it with gem install prism"
end
require_relative "../source/static_eval"

module Flexr
  class Importer
    class OedipusLex
      REGEXP = %r{\A(/(?:\\.|[^/\\])*/)([a-zA-Z]*)(?:\s+(.*))?\z}
      SECTION = /\A(macros?|rules?|options?|inner|start)\s*(?:#.*)?\z/
      LITERALS = [Prism::SymbolNode, Prism::StringNode, Prism::IntegerNode, Prism::FloatNode,
                  Prism::TrueNode, Prism::FalseNode, Prism::NilNode].freeze

      def initialize(path, source)
        @path = path
        @source = source.force_encoding(Encoding::UTF_8)
        @macros = {}
        @rules = []
        @warnings = []
      end

      def run
        if @source.valid_encoding?
          @source.each_line.with_index(1) { |line, number| read_line(line.strip, number) }
          warn_at(1, "add a lexer class declaration") unless @class_name
          warn_at(1, "close the specification with end") unless @closed
          warn_at(1, "add an importable rule to the rule section") if @rules.empty? && @warnings.empty?
        else
          warn_at(1, "convert the source to UTF-8 before importing")
        end

        complete = @warnings.empty?
        Result.new(source: complete ? render : nil, warnings: @warnings.freeze, complete?: complete)
      end

      private

      def read_line(line, number)
        if line.start_with?("#")
          coding = line[/\b(?:en)?coding:\s*([\w-]+)/i, 1] if number <= 2
          warn_at(number, "convert the source to UTF-8 and update the encoding comment") if coding && coding.upcase != "UTF-8"
          return
        end
        return if line.empty?
        return read_class(line, number) unless @class_name
        return warn_at(number, "move Ruby footer code to a separate file") if @closed

        if line.match?(/\Aend\s*(?:#.*)?\z/)
          @closed = true
        elsif (heading = SECTION.match(line))
          @section = heading[1].delete_suffix("s")
        elsif @section == "macro"
          read_macro(line, number)
        elsif @section == "rule"
          read_rule(line, number)
        elsif @section == "option"
          warn_at(number, "unsupported option #{line.split.first.inspect}. Reproduce its behavior in the lexer or parser wrapper")
        elsif @section
          warn_at(number, "unsupported #{@section} code. Move it to the lexer or parser wrapper")
        else
          warn_at(number, "unexpected section content. Use a macro or rule section")
        end
      end

      def read_class(line, number)
        header = line.match(/\Aclass\s+([A-Z][A-Za-z0-9_]*)\s*([^#]*)(?:#.*)?\z/)
        return warn_at(number, "unsupported Ruby header. Move it to a separate file before the lexer class") unless header

        @class_name = header[1]
        return if header[2].strip.empty?

        warn_at(number, "unsupported superclass or qualified class. Adapt the parser to a separate Flexr lexer")
      end

      def read_macro(line, number)
        name, literal = line.split(/\s+/, 2)
        return warn_at(number, "define a macro as CONSTANT /regexp/") unless name.match?(/\A[A-Z][A-Za-z0-9_]*\z/) && literal
        return warn_at(number, "duplicate macro #{name}. Keep one definition before its uses") if @macros.key?(name)

        regexp, tail = parse_regexp(literal, number)
        return unless regexp
        return warn_at(number, "unexpected text after macro regexp. Remove it or use a comment") unless blank_or_comment?(tail)

        @macros[name] = regexp
      end

      def read_rule(line, number)
        case line
        when /\A:\s/, /\A\|/
          return warn_at(number, "unsupported guard group. Preserve the group guard when rewriting its rules")
        when /\A:\w+/
          return warn_at(number, "unsupported rule state. Migrate state eligibility and transitions together")
        when /\A\w+[?!]?\s/
          return warn_at(number, "unsupported rule predicate. Move the predicate into explicit lexer state or parser logic")
        end

        regexp, action = parse_regexp(line, number)
        return unless regexp

        emission = translate_action(action, number)
        return unless emission
        return unless supported_rule_regexp?(regexp, number)

        pattern = regexp.casefold? ? regexp.to_s : regexp.source
        @rules << if emission == :skip
          "  rule(::Regexp.new(#{pattern.dump}), skip: true)"
        else
          "  rule(::Regexp.new(#{pattern.dump})) { #{emission} }"
        end
      end

      def parse_regexp(line, number)
        match = REGEXP.match(line)
        return warn_at(number, "expected a slash-delimited regexp followed by an optional action") unless match
        return warn_at(number, "unsupported regexp flag #{match[2].inspect}. Use no flag, /i, or /o") unless %w[i o].include?(match[2]) || match[2].empty?

        literal = match[1] + match[2]
        node = expression(literal)
        return warn_at(number, "invalid regexp. Check its delimiters and escapes") unless node.is_a?(Prism::RegularExpressionNode) || node.is_a?(Prism::InterpolatedRegularExpressionNode)
        return if node.is_a?(Prism::InterpolatedRegularExpressionNode) && !valid_macros?(node, number)

        [Source::StaticEval.new(literal, constants: @macros).call(node), match[3].to_s]
      rescue StaticResolutionError => e
        detail = e.diagnostic.note.split("; runtime mode", 2).first
        warn_at(number, "cannot import regexp: #{detail}")
      end

      def valid_macros?(node, number)
        node.parts.each do |part|
          next if part.is_a?(Prism::StringNode)

          body = part.is_a?(Prism::EmbeddedStatementsNode) ? part.statements&.body : nil
          return warn_at(number, "unsupported regexp interpolation. Reference only declared regexp macros") unless body&.one? && body.first.is_a?(Prism::ConstantReadNode)

          name = body.first.name.to_s
          return warn_at(number, "undefined regexp macro #{name}. Declare it before use") unless @macros.key?(name)
        end
        true
      end

      def supported_rule_regexp?(regexp, number)
        return warn_at(number, "rewrite Unicode property or POSIX class patterns before importing because Ruby and flexr may use different Unicode tables") if Regexp::Matcher.reference?(regexp, encoding: Encoding::UTF_8)

        ast = Regexp::Parser.new(regexp.source, options: regexp.options).parse
        return warn_at(number, "rewrite regexp lookahead as separate rules or states before importing") if Regexp::AST.lookahead?(ast)
        return warn_at(number, "rewrite regexp lookbehind as separate rules or states before importing") if Regexp::AST.lookbehind?(ast)
        return warn_at(number, "rewrite regexp anchors against the input position before importing") if anchor?(ast)
        return warn_at(number, "rewrite the regexp to consume input because it can match an empty string") if Regexp::AST.nullable?(ast)
        return warn_at(number, "rewrite absence groups before using the firstmatch backend") if Regexp::AST.absence?(ast)

        true
      rescue CompileError => e
        help = e.diagnostic&.help
        warn_at(number, help ? "#{e.message} (#{help})" : e.message)
      end

      def anchor?(node)
        return true if node.is_a?(Regexp::AST::Anchor)
        return anchor?(node.child) if node.respond_to?(:child)

        node.respond_to?(:children) && node.children.any? { |child| anchor?(child) }
      end

      def translate_action(action, number)
        return :skip if blank_or_comment?(action)
        return warn_at(number, "unsupported state action. Translate the state transition and emitted token together") if
          action.match?(/\A(?::\w+|nil)(?:\s|\z)/)

        call = expression("proc #{action}")
        if call.is_a?(Prism::CallNode) && call.receiver.nil? && call.name == :proc &&
            call.arguments.nil? && call.block.is_a?(Prism::BlockNode) && call.block.parameters.nil?
          body = call.block.body&.body
          return :skip if body.nil? || (body.one? && skip_action?(body.first))
          pair = body.first if body.one?
          converted = convert_pair(pair)
          return converted if converted
        end
        warn_at(number, "unsupported Ruby action. Translate it manually to emit(token, value) or skip")
      end

      def skip_action?(node)
        node.is_a?(Prism::NilNode) || (node.is_a?(Prism::NextNode) && node.arguments.nil?)
      end

      def convert_pair(pair)
        return unless pair.is_a?(Prism::ArrayNode) && pair.elements.length == 2

        kind, value = pair.elements
        return unless kind.is_a?(Prism::StringNode) || kind.is_a?(Prism::SymbolNode) || simple_call?(kind, :text)
        return if kind.is_a?(Prism::SymbolNode) && kind.unescaped == "state"
        return unless LITERALS.any? { |literal| value.is_a?(literal) } || simple_call?(value, :text) || text_conversion?(value)

        "emit(#{kind.slice}, #{value.slice})"
      end

      def text_conversion?(node)
        node.is_a?(Prism::CallNode) && %i[to_i to_f to_sym].include?(node.name) &&
          node.arguments.nil? && node.block.nil? && simple_call?(node.receiver, :text)
      end

      def simple_call?(node, name)
        node.is_a?(Prism::CallNode) && node.slice == name.to_s
      end

      def expression(source)
        parsed = Prism.parse(source)
        statements = parsed.value.statements.body
        statements.first if parsed.success? && statements.one?
      end

      def blank_or_comment?(text)
        text.empty? || text.start_with?("#")
      end

      def warn_at(number, message)
        @warnings << "#{@path}:#{number}: #{message}"
        nil
      end

      def render
        lines = ["# frozen_string_literal: true", "", 'require "flexr"', "",
                 "class #{@class_name} < Flexr::Lexer", "  backend :firstmatch", *@rules, "end", ""]
        lines.join("\n")
      end
    end
  end
end
