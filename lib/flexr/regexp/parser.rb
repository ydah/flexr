# frozen_string_literal: true

module Flexr
  module Regexp
    class Parser
      ESCAPES = {
        "n" => 0x0a, "t" => 0x09, "r" => 0x0d, "f" => 0x0c,
        "v" => 0x0b, "a" => 0x07, "e" => 0x1b, "0" => 0
      }.freeze
      PROPERTY_ALIASES = {
        "digit" => "Nd", "alpha" => "Alphabetic", "alnum" => "Alnum",
        "word" => "Word", "space" => "Space"
      }.freeze
      POSIX_CLASSES = %w[alnum alpha blank cntrl digit graph lower print punct space upper xdigit].freeze

      attr_reader :source

      def initialize(source, options: 0, encoding: Encoding::UTF_8, unicode: false)
        @source = source
        @options = options
        @encoding = encoding
        @unicode = unicode
        @index = 0
        @class_depth = 0
      end

      def parse
        node = parse_expression
        raise_syntax("unexpected `#{current}`") unless eof?
        validate_anchor_positions(node)
        node
      end

      private

      def parse_expression
        branches = [parse_sequence]
        branches << parse_sequence while consume?("|")
        return branches.first if branches.length == 1

        AST::Alt.new(children: branches, loc: nil)
      end

      def parse_sequence
        children = []
        children << parse_quantified until eof? || [")", "|"].include?(current)
        return AST::Empty.new(loc: nil) if children.empty?
        return children.first if children.length == 1

        AST::Seq.new(children: children, loc: nil)
      end

      def parse_quantified
        atom = parse_atom
        return atom unless ["*", "+", "?", "{"].include?(current)

        if consume?("*")
          reject_postfix_quantifier
          return AST::Star.new(child: atom, loc: nil)
        end
        if consume?("+")
          reject_postfix_quantifier
          return AST::Seq.new(children: [atom, AST::Star.new(child: atom, loc: nil)], loc: nil)
        end
        if consume?("?")
          reject_postfix_quantifier
          return AST::Alt.new(children: [atom, AST::Empty.new(loc: nil)], loc: nil)
        end

        parse_repetition(atom)
      end

      def parse_repetition(atom)
        consume?("{")
        min = read_number
        max = if consume?(",")
          read_number unless current == "}"
        else
          min
        end
        expect("}")
        raise_syntax("invalid repetition") if min.nil? || (!max.nil? && max < min)
        raise_syntax("open repetition is not supported") if max.nil?
        if max > 1000
          raise_diagnostic(
            diagnostic("FLEXR-E007", "repetition limit exceeds 1000",
                       help: "split the rule or use a smaller bounded repetition")
          )
        end
        reject_postfix_quantifier

        required = Array.new(min) { atom }
        optional = Array.new(max - min) do
          AST::Alt.new(children: [atom, AST::Empty.new(loc: nil)], loc: nil)
        end
        children = required + optional
        return AST::Empty.new(loc: nil) if children.empty?
        return children.first if children.length == 1

        AST::Seq.new(children: children, loc: nil)
      end

      def parse_atom
        @escaped_value = false
        @last_ranges = nil
        return parse_group if consume?("(")
        return parse_class if consume?("[")
        return parse_anchor if ["^", "$"].include?(current)

        if consume?(".")
          upper = @options.nobits?(::Regexp::MULTILINE) ? 0x0a - 1 : 0x10ffff
          return AST::CharClass.new(ranges: [[0, upper], [0x0b, 0x10ffff]], negated: false, loc: nil)
        end

        if consume?("\\")
          parse_escape
          return AST::CharClass.new(ranges: @last_ranges, negated: false, loc: nil) if @last_ranges
          return codepoint_node(read_codepoint) if @escaped_value
        end

        char = advance
        raise_syntax("unexpected end of expression") unless char
        codepoint_node(char.ord)
      end

      def parse_group
        saved_options = @options
        if consume?("?")
          prefix = parse_group_prefix
          return AST::Empty.new(loc: nil) if prefix == :global
        else
          warn_capture
        end
        node = parse_expression
        expect(")")
        @options = saved_options if prefix
        node
      end

      def parse_group_prefix
        return true if consume?(":")
        if peek_prefix?("-mix:")
          @index += 5
          @options &= ~(::Regexp::IGNORECASE | ::Regexp::MULTILINE | ::Regexp::EXTENDED)
          return true
        end
        if ["i", "m", "x", "-"].include?(current)
          add = true
          flags = []
          while ["i", "m", "x", "-"].include?(current)
            if consume?("-")
              add = false
            else
              flags << [advance, add]
            end
          end
          if consume?(":")
            flags.each { |flag, enabled| update_option(flag, enabled) }
            return true
          end
          if consume?(")")
            flags.each { |flag, enabled| update_option(flag, enabled) }
            return :global
          end
          raise_syntax("invalid inline option group")
        end
        raise unsupported("look-around", "use followed_by: or a state instead") if peek_prefix?("=") || peek_prefix?("!") || peek_prefix?("<=") || peek_prefix?("<!")
        raise unsupported("atomic groups", "rewrite the expression as a DFA-compatible expression") if consume?(">")
        raise unsupported("unsupported group syntax", "use a non-capturing group (?:...)")
      end

      def update_option(flag, enabled)
        bit = { "i" => ::Regexp::IGNORECASE, "m" => ::Regexp::MULTILINE, "x" => ::Regexp::EXTENDED }.fetch(flag)
        @options = enabled ? (@options | bit) : (@options & ~bit)
      end

      def codepoint_node(codepoint)
        return AST::CodepointRange.new(lo: codepoint, hi: codepoint, loc: nil) if @options.nobits?(::Regexp::IGNORECASE)

        AST::CharClass.new(ranges: fold_ranges([[codepoint, codepoint]]), negated: false, loc: nil)
      end

      def fold_ranges(ranges)
        folded = ranges.flat_map do |range|
          next [range] if range.first.is_a?(Module)

          Unicode::CaseFold.ranges(range.first, range.last)
        end
        merge_ranges(folded)
      end

      def parse_class
        negated = consume?("^")
        ranges = []
        @class_depth += 1
        until eof? || current == "]"
          if current == "[" && @source[@index, 2] == "[:"
            ranges.concat(parse_posix_class)
            next
          end
          first = parse_class_atom
          if consume?("-") && current != "]"
            last = parse_class_atom
            ranges.concat(expand_class_range(first, last))
          else
            ranges.concat(first)
          end
        end
        expect("]")
        @class_depth -= 1
        ranges = merge_ranges(ranges)
        ranges = fold_ranges(ranges) if @options.anybits?(::Regexp::IGNORECASE)
        AST::CharClass.new(ranges: ranges, negated: negated, loc: nil)
      ensure
        @class_depth -= 1 if @class_depth.positive? && current != "]"
      end

      def parse_posix_class
        expect("[:")
        raw_name = read_until(":]")
        inner_negated = raw_name.start_with?("^")
        name = raw_name.delete_prefix("^")
        return [[AST::Property, inner_negated, "POSIX_#{name}"]] if
          @encoding != Encoding::BINARY && POSIX_CLASSES.include?(name)

        ranges = case name
        when "alnum" then [[48, 57], [65, 90], [97, 122]]
        when "alpha" then [[65, 90], [97, 122]]
        when "blank" then [[9, 9], [32, 32]]
        when "cntrl" then [[0, 31], [127, 127]]
        when "digit" then [[48, 57]]
        when "graph" then [[33, 126]]
        when "lower" then [[97, 122]]
        when "print" then [[32, 126]]
        when "punct" then [[33, 47], [58, 64], [91, 96], [123, 126]]
        when "space" then [[9, 13], [32, 32]]
        when "upper" then [[65, 90]]
        when "xdigit" then [[48, 57], [65, 70], [97, 102]]
        else
          raise_syntax("unknown POSIX character class: #{name}")
        end
        inner_negated ? complement_ranges(ranges) : ranges
      end

      def parse_class_atom
        if consume?("\\")
          parse_escape
          return [[@last_codepoint, @last_codepoint]] if @escaped_value
          return @last_ranges
        end
        char = advance
        raise_syntax("unterminated character class") unless char
        [[char.ord, char.ord]]
      end

      def expand_class_range(first, last)
        raise_syntax("character class range endpoints must be single characters") if first.length != 1 || last.length != 1
        lo = first.first.first
        hi = last.first.first
        raise_syntax("invalid character class range") if lo > hi
        [[lo, hi]]
      end

      def parse_escape
        @escaped_value = false
        @last_ranges = nil
        char = advance_raw
        raise_syntax("trailing backslash") unless char
        if ESCAPES.key?(char)
          @escaped_value = true
          @last_codepoint = ESCAPES.fetch(char)
          return
        end
        case char
        when "d", "D", "w", "W", "s", "S", "h", "H"
          ranges = shorthand_ranges(char)
          @last_ranges = ranges
          nil
        when "p", "P"
          expect("{")
          name = read_until("}")
          ranges = [[AST::Property, char == "P", name]]
          @last_ranges = ranges
          nil
        when "x"
          digits = if consume?("{")
            read_until("}")
          else
            read_exact(2)
          end
          assign_codepoint(digits)
          nil
        when "u"
          digits = if consume?("{")
            value = read_until("}")
            value
          else
            read_exact(4)
          end
          assign_codepoint(digits)
          nil
        when "G", "K", "b", "B", "A", "z", "Z", "1", "2", "3", "4", "5", "6", "7", "8", "9"
          raise unsupported("\\#{char}", "use a state or followed_by: instead")
        when "k"
          read_until(">") if consume?("<")
          raise unsupported("backreferences", "split the rule into DFA-compatible states")
        else
          @escaped_value = true
          @last_codepoint = char.ord
        end
      end

      def shorthand_ranges(char)
        if @unicode && @encoding != Encoding::BINARY
          property = { "d" => "Nd", "w" => "Word", "s" => "Space" }.fetch(char.downcase, nil)
          return [[AST::Property, char == char.upcase, property]] if property
        end

        base = {
          "d" => [[48, 57]],
          "w" => [[48, 57], [65, 90], [95, 95], [97, 122]],
          "s" => [[9, 13], [32, 32]],
          "h" => [[9, 9], [32, 32]]
        }.fetch(char.downcase)
        return base unless char == char.upcase

        complement_ranges(base)
      end

      def complement_ranges(ranges)
        out = []
        cursor = 0
        ranges.sort.each do |lo, hi|
          out << [cursor, lo - 1] if cursor < lo
          cursor = hi + 1
        end
        out << [cursor, 0x10ffff] if cursor <= 0x10ffff
        out
      end

      def parse_anchor
        char = advance
        return AST::Anchor.new(kind: :bol, loc: nil) if char == "^"

        AST::Anchor.new(kind: :eol, loc: nil)
      end

      def validate_anchor_positions(node)
        anchors = anchor_nodes(node)
        return if anchors.empty?

        sequence = flatten_sequence(node)
        allowed = [sequence.first, sequence.last].compact
        boundaries_valid = if sequence.length == 1 && sequence.first.is_a?(AST::Anchor)
          %i[bol eol].include?(sequence.first.kind)
        else
          (!sequence.first.is_a?(AST::Anchor) || sequence.first.kind == :bol) &&
            (!sequence.last.is_a?(AST::Anchor) || sequence.last.kind == :eol)
        end
        valid = !anchor_nested_in_alternative?(node) && anchors.all? { |anchor| allowed.include?(anchor) } && boundaries_valid
        return if valid

        raise_diagnostic(
          diagnostic("FLEXR-E009", "anchors are only valid at the outermost pattern boundaries",
                     help: "split alternatives into separate rules or move ^/$ outside the alternation")
        )
      end

      def flatten_sequence(node)
        return [] if node.is_a?(AST::Empty)
        return node.children.flat_map { |child| flatten_sequence(child) } if node.is_a?(AST::Seq)

        [node]
      end

      def anchor_nodes(node)
        return [node] if node.is_a?(AST::Anchor)
        return anchor_nodes(node.child) if node.is_a?(AST::Star)
        return [] unless node.respond_to?(:children)

        node.children.flat_map { |child| anchor_nodes(child) }
      end

      def anchor_nested_in_alternative?(node)
        return node.children.any? { |child| anchor_nodes(child).any? } if node.is_a?(AST::Alt)
        return anchor_nested_in_alternative?(node.child) if node.is_a?(AST::Star)
        return false unless node.respond_to?(:children)

        node.children.any? { |child| anchor_nested_in_alternative?(child) }
      end

      def warn_capture
        # The parser intentionally treats captures as non-capturing. Diagnostics
        # are exposed by the source compiler where a source location is known.
      end

      def reject_postfix_quantifier
        return unless ["?", "+"].include?(current)

        raise unsupported("lazy or possessive quantifier", "use a negated character class")
      end

      def merge_ranges(ranges)
        properties, concrete = ranges.partition { |range| range.first.is_a?(Module) }
        merged = concrete.sort_by(&:first).each_with_object([]) do |range, result|
          if result.empty? || range.first > result.last.last + 1
            result << range.dup
          else
            result.last[1] = [result.last.last, range.last].max
          end
        end
        merged + properties
      end

      def current
        skip_extended_space if @options.anybits?(::Regexp::EXTENDED) && @class_depth.zero?
        @source[@index]
      end

      def advance
        skip_extended_space if @options.anybits?(::Regexp::EXTENDED) && @class_depth.zero?
        advance_raw
      end

      def advance_raw
        char = @source[@index]
        @index += 1 if char
        char
      end

      def consume?(value)
        return false unless @source[@index, value.length] == value

        @index += value.length
        true
      end

      def expect(value)
        return if consume?(value)

        raise_syntax("expected `#{value}`")
      end

      def peek_prefix?(value)
        @source[@index, value.length] == value
      end

      def read_number
        start = @index
        advance while current&.match?(/[0-9]/)
        return nil if start == @index

        @source[start...@index].to_i
      end

      def read_exact(count)
        value = @source[@index, count]
        raise_syntax("invalid escape") unless value&.length == count && value.match?(/\A[0-9a-fA-F]+\z/)
        @index += count
        value
      end

      def read_until(terminator)
        start = @index
        finish = @source.index(terminator, @index)
        raise_syntax("unterminated escape") unless finish
        @index = finish + terminator.length
        @source[start...finish]
      end

      def eof?
        @index >= @source.length
      end

      def diagnostic(code, message, help: nil)
        Diagnostics.error(code, message, help: help)
      end

      def raise_diagnostic(diagnostic)
        raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
      end

      def raise_syntax(message)
        raise CompileError.new(message, diagnostic: diagnostic("FLEXR-E001", message))
      end

      def unsupported(feature, help)
        diagnostic = Diagnostics.error("FLEXR-E014", "#{feature} is not supported by flexr", help: help)
        raise UnsupportedRegexpError.new(diagnostic.message, diagnostic: diagnostic)
      end

      def read_codepoint
        @last_codepoint
      end

      def assign_codepoint(digits)
        raise_syntax("invalid escape") unless digits.match?(/\A[0-9a-fA-F]+\z/)

        codepoint = digits.to_i(16)
        raise_syntax("invalid Unicode codepoint") if codepoint > 0x10ffff || codepoint.between?(0xd800, 0xdfff)

        @escaped_value = true
        @last_codepoint = codepoint
      end

      def skip_extended_space
        loop do
          @index += 1 while @source[@index]&.match?(/\s/)
          break unless @source[@index] == "#"

          @index += 1
          @index += 1 while @source[@index] && @source[@index] != "\n"
        end
      end
    end
  end
end
