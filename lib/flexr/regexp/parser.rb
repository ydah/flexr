# frozen_string_literal: true

module Flexr
  module Regexp
    class Parser
      ESCAPES = {
        "n" => 0x0a, "t" => 0x09, "r" => 0x0d, "f" => 0x0c,
        "v" => 0x0b, "a" => 0x07, "e" => 0x1b
      }.freeze
      PROPERTY_ALIASES = {
        "digit" => "Nd", "alpha" => "Alphabetic", "alnum" => "Alnum",
        "word" => "Word", "space" => "Space"
      }.freeze
      POSIX_CLASSES = %w[alnum alpha blank cntrl digit graph lower print punct space upper xdigit].freeze
      LITERAL_ESCAPES = (%w[. [ ] { } ( ) * + ? | ^ $ \\ / - #] + [" "]).freeze
      MAX_BACKREFERENCE = 1000

      attr_reader :source

      def initialize(source, options: 0, encoding: Encoding::UTF_8, unicode: false, preserve_captures: false,
                     capture_offsets: nil)
        @source = source
        @options = options
        @encoding = encoding
        @unicode = unicode
        @capture_offsets = capture_offsets
        @preserve_captures = preserve_captures
        @index = 0
        @class_depth = 0
        @capture_count = 0
        offset = 0
        @byte_offsets = [0]
        source.each_char do |character|
          offset += character.bytesize
          @byte_offsets << offset
        end
      end

      def parse
        node = parse_expression
        raise_syntax("unexpected `#{current}`") unless eof?
        validate_anchor_positions(node)
        node
      end

      private

      def parse_expression
        starting = @index
        branches = [parse_sequence]
        branches << parse_sequence while consume?("|")
        return branches.first if branches.length == 1

        AST::Alt.new(children: branches, loc: span(starting))
      end

      def parse_sequence
        starting = @index
        children = []
        children << parse_quantified until eof? || [")", "|"].include?(current)
        return AST::Empty.new(loc: span(starting)) if children.empty?
        return children.first if children.length == 1

        AST::Seq.new(children: children, loc: span(starting))
      end

      def parse_quantified
        starting = @index
        atom = parse_atom
        return atom unless ["*", "+", "?", "{"].include?(current)

        if consume?("*")
          reject_postfix_quantifier
          return AST::Repeat.new(child: atom, minimum: 0, maximum: nil, loc: span(starting))
        end
        if consume?("+")
          reject_postfix_quantifier
          return AST::Repeat.new(child: atom, minimum: 1, maximum: nil, loc: span(starting))
        end
        if consume?("?")
          reject_postfix_quantifier
          return AST::Repeat.new(child: atom, minimum: 0, maximum: 1, loc: span(starting))
        end

        parse_repetition(atom, starting)
      end

      def parse_repetition(atom, starting)
        consume?("{")
        min = read_number
        max = if consume?(",")
          read_number unless current == "}"
        else
          min
        end
        expect("}")
        raise_syntax("invalid repetition") if min.nil? || (!max.nil? && max < min)
        if (max || min) > 1000
          raise_diagnostic(
            diagnostic("FLEXR-E007", "repetition limit exceeds 1000",
                       help: "split the rule or use a smaller bounded repetition")
          )
        end
        reject_postfix_quantifier

        AST::Repeat.new(child: atom, minimum: min, maximum: max, loc: span(starting))
      end

      def parse_atom
        starting = @index
        @escaped_value = false
        @escaped_byte = false
        @last_ranges = nil
        return parse_group if consume?("(")
        return parse_class if consume?("[")
        return parse_anchor if ["^", "$"].include?(current)

        if consume?(".")
          upper = @options.nobits?(::Regexp::MULTILINE) ? 0x0a - 1 : 0x10ffff
          return AST::CharClass.new(
            ranges: [[0, upper], [0x0b, 0x10ffff]], negated: false, loc: span(starting)
          )
        end

        if consume?("\\")
          case current
          when "R"
            advance
            return parse_linebreak(starting)
          when "z", "Z"
            kind = advance == "z" ? :eof : :final_eol
            return AST::Anchor.new(kind: kind, loc: span(starting))
          end

          parse_escape
          return AST::CharClass.new(ranges: @last_ranges, negated: false, loc: span(starting)) if @last_ranges
          return AST::ByteRange.new(lo: @last_byte, hi: @last_byte, loc: span(starting)) if @escaped_byte
          return codepoint_node(read_codepoint, span(starting)) if @escaped_value
        end

        char = advance
        raise_syntax("unexpected end of expression") unless char
        codepoint_node(char.ord, span(starting))
      end

      def parse_group
        starting = @index - 1
        saved_options = @options
        if consume?("?")
          prefix = parse_group_prefix
          return AST::Empty.new(loc: span(starting)) if prefix == :global
        else
          @capture_count += 1
          @capture_offsets&.push(@byte_offsets.fetch(starting))
        end
        node = parse_expression
        expect(")")
        @options = saved_options if prefix
        return AST::Absence.new(child: node, loc: span(starting)) if prefix == :absence
        return AST::Lookahead.new(child: node, negative: prefix == :negative_lookahead, loc: span(starting)) if
          %i[positive_lookahead negative_lookahead].include?(prefix)
        return AST::NamedCapture.new(opening: prefix, child: node) if prefix.is_a?(String)

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
        return :positive_lookahead if consume?("=")
        return :negative_lookahead if consume?("!")
        raise unsupported("lookbehind", "use separate rules or lexer states to track the preceding input") if
          peek_prefix?("<=") || peek_prefix?("<!")
        if consume?(">")
          raise unsupported("atomic groups",
                            'for unescaped single-line quoted text, a DFA-compatible rewrite is rule(/"[^"\n]*"/); keep the action; removing atomic groups can change matches')
        end
        return named_capture_prefix("<", ">") if consume?("<")
        return named_capture_prefix("'", "'") if consume?("'")
        if peek_prefix?("(")
          raise unsupported("conditional groups",
                            "for this optional-prefix conditional, rewrite rule(/(a)?(?(1)b|c)/) as rule(/(?:ab|c)/); keep the action; other conditions need separate rules or state checks")
        end
        if consume?("~")
          raise unsupported("extended absence operators", "use an absence group (?~X) to exclude a subexpression") if peek_prefix?("|")

          return :absence
        end
        raise unsupported("unsupported group syntax", "use a non-capturing group (?:...)")
      end

      def named_capture_prefix(opener, closer)
        name = read_until(closer)
        @capture_count += 1
        @preserve_captures ? "#{opener}#{name}#{closer}" : true
      end

      def update_option(flag, enabled)
        bit = { "i" => ::Regexp::IGNORECASE, "m" => ::Regexp::MULTILINE, "x" => ::Regexp::EXTENDED }.fetch(flag)
        @options = enabled ? (@options | bit) : (@options & ~bit)
      end

      def codepoint_node(codepoint, location)
        return AST::CodepointRange.new(lo: codepoint, hi: codepoint, loc: location) if
          @options.nobits?(::Regexp::IGNORECASE)

        AST::CharClass.new(ranges: fold_ranges([[codepoint, codepoint]]), negated: false, loc: location)
      end

      def fold_ranges(ranges)
        folded = ranges.flat_map do |range|
          next [range] if range.first.is_a?(Module)
          next fold_binary_range(range) if @encoding == Encoding::BINARY

          Unicode::CaseFold.ranges(range.first, range.last)
        end
        merge_ranges(folded)
      end

      def fold_binary_range(range)
        alternatives = [[65, 90, 32], [97, 122, -32]].filter_map do |first, last, offset|
          lo = [range.first, first].max
          hi = [range.last, last].min
          [lo + offset, hi + offset] if lo <= hi
        end
        [range, *alternatives]
      end

      def parse_class
        starting = @index - 1
        @class_depth += 1
        negated = consume?("^")
        ranges = parse_class_union
        while peek_prefix?("&&")
          @index += 2
          ranges = materialize_class_ranges(ranges, negated: negated)
          negated = false
          right = if consume?("[")
            nested = parse_class
            materialize_class_ranges(nested.ranges, negated: nested.negated)
          else
            materialize_class_ranges(parse_class_union, negated: false)
          end
          ranges = intersect_ranges(ranges, right)
        end
        expect("]")
        ranges = merge_ranges(ranges)
        ranges = fold_ranges(ranges) if @options.anybits?(::Regexp::IGNORECASE)
        AST::CharClass.new(ranges: ranges, negated: negated, loc: span(starting))
      ensure
        @class_depth -= 1
      end

      def parse_class_union
        ranges = []
        until eof? || current == "]" || peek_prefix?("&&")
          if current == "[" && @source[@index, 2] == "[:"
            ranges.concat(parse_posix_class)
            next
          end
          first = parse_class_atom
          if consume?("-")
            if current == "]"
              ranges.concat(first)
              ranges << [45, 45]
            else
              last = parse_class_atom
              ranges.concat(expand_class_range(first, last))
            end
          else
            ranges.concat(first)
          end
        end
        ranges
      end

      def parse_posix_class
        expect("[:")
        raw_name = read_until(":]")
        inner_negated = raw_name.start_with?("^")
        name = raw_name.delete_prefix("^")
        return [[AST::Property, inner_negated, "POSIX_#{name}", ignorecase?]] if
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
          return [[@last_byte, @last_byte]] if @escaped_byte
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

      def materialize_class_ranges(ranges, negated:)
        concrete = ranges.flat_map do |range|
          if range.first == AST::Property
            property = Unicode::Property.ranges(range[2])
            property = fold_ranges(property) if range[3]
            range[1] ? complement_ranges(property) : property
          else
            [range]
          end
        end
        concrete = merge_ranges(concrete)
        negated ? complement_ranges(concrete) : concrete
      end

      def intersect_ranges(left, right)
        result = []
        left_index = 0
        right_index = 0
        while left_index < left.length && right_index < right.length
          left_range = left[left_index]
          right_range = right[right_index]
          lo = [left_range.first, right_range.first].max
          hi = [left_range.last, right_range.last].min
          result << [lo, hi] if lo <= hi
          if left_range.last < right_range.last
            left_index += 1
          else
            right_index += 1
          end
        end
        result
      end

      def parse_escape
        @escaped_value = false
        @escaped_byte = false
        @last_ranges = nil
        char = advance_raw
        raise_syntax("trailing backslash") unless char
        if ESCAPES.key?(char)
          @escaped_value = true
          @last_codepoint = ESCAPES.fetch(char)
          return
        end
        if @class_depth.positive? && %w[A B G z Z K g X].include?(char)
          raise unsupported("\\#{char}",
                            "inside a character class this is a literal character: rewrite rule(/[\\#{char}]/) as rule(/[#{char}]/); keep the action")
        end
        case char
        when "d", "D", "w", "W", "s", "S", "h", "H"
          ranges = shorthand_ranges(char)
          @last_ranges = ranges
          nil
        when "p", "P"
          expect("{")
          name = read_until("}")
          ranges = [[AST::Property, char == "P", name, ignorecase?]]
          @last_ranges = ranges
          nil
        when "x"
          if consume?("{")
            assign_codepoint(read_until("}"))
          else
            assign_byte(read_exact(2).to_i(16))
          end
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
        when "b"
          unless @class_depth.positive?
            raise unsupported("\\b",
                              'when surrounding literals already establish the boundary, rewrite rule(/foo\b:/) as rule(/foo:/); keep the action; token edges need separate rules or state checks')
          end

          @escaped_value = true
          @last_codepoint = 0x08
        when "B"
          raise unsupported("\\B",
                            'when surrounding literals already establish the non-boundary, rewrite rule(/foo\Bbar/) as rule(/foobar/); keep the action; token edges need separate rules or state checks')
        when "G"
          raise unsupported("\\G",
                            'at the start of a rule, rewrite rule(/\Ga/) as rule(/a/); keep the action; rules already match at the current lexer position; interior \G needs a separate rewrite')
        when "A"
          raise unsupported("\\A",
                            'for input without line feeds, rewrite rule(/\Aa/) as rule(/^a/); keep the action; line boundaries differ from string boundaries')
        when "z", "Z"
          raise unsupported("\\#{char}",
                            "for input without line feeds, rewrite rule(/a\\#{char}/) as rule(/a$/); keep the action; line boundaries differ from string boundaries")
        when "K"
          raise unsupported("\\K",
                            'for /a\Kb/ in :initial, use rule(/a/, followed_by: /b/) { begin_state :suffix }; state(:suffix) { rule(/b/) { begin_state :initial; emit :B } }; keep the action on the suffix rule after returning to :initial; choose an unused state name')
        when "g"
          raise unsupported("\\g",
                            'for this non-recursive call, rewrite rule(/(a|b)\g<1>/) as rule(/[ab]{2}/); keep the action; recursive calls need a parser or state stack')
        when "X"
          raise unsupported("\\X",
                            'for a standalone grapheme token with ASCII-only input, rewrite rule(/\X/) as rule(/\r\n|[\x00-\x7f]/); keep the action; Unicode graphemes need separate segmentation')
        when "c", "C"
          raise unsupported("\\#{char}",
                            'for control-A, rewrite rule(/\cA/) or rule(/\C-A/) as rule(/\x01/); keep the action; other control characters need their own hexadecimal code')
        when "M"
          raise unsupported("\\M",
                            'for binary input, rewrite rule(/\M-a/n) as rule(/\xE1/n); keep the action; other meta characters need their own byte value')
        when "0".."9"
          parse_numbered_escape(char)
        when "k"
          read_until(">") if consume?("<")
          reject_backreference("backreferences")
        when "R", *LITERAL_ESCAPES
          @escaped_value = true
          @last_codepoint = char.ord
        else
          raise unsupported("unknown escape \\#{char}",
                            'if q is literal, rewrite rule(/\q/) as rule(/q/); otherwise use a supported escape; keep the action')
        end
      end

      def parse_linebreak(starting)
        location = span(starting)
        cr = AST::CodepointRange.new(lo: 0x0d, hi: 0x0d, loc: location)
        lf = AST::CodepointRange.new(lo: 0x0a, hi: 0x0a, loc: location)
        condition = AST::NotNextLineFeed.new(loc: location)
        crlf = AST::Seq.new(children: [cr, lf], loc: location)
        lone_cr = AST::Seq.new(children: [cr, condition], loc: location)
        ranges = [[0x0a, 0x0c]]
        ranges.push([0x85, 0x85], [0x2028, 0x2029]) unless @encoding == Encoding::BINARY
        singles = AST::CharClass.new(ranges: ranges, negated: false, loc: location)
        AST::Alt.new(children: [crlf, lone_cr, singles], loc: location)
      end

      def parse_numbered_escape(first)
        starting = @index - 1
        octal = octal_digits(starting)
        byte = octal&.to_i(8)
        # Ruby preserves decimal references for ASCII escapes after preprocessing raw bytes.
        if first != "0" && @class_depth.zero? && (!byte || byte < 0x80)
          decimal = /\G[0-9]+/.match(@source, starting)[0]
          maximum = @capture_count.clamp(9, MAX_BACKREFERENCE)
          reject_backreference("\\#{decimal}") if decimal.to_i <= maximum
        end

        if octal
          @index += octal.length - 1
          assign_byte(byte)
        else
          @escaped_value = true
          @last_codepoint = first.ord
        end
      end

      def reject_backreference(feature)
        raise unsupported(feature,
                          'for a capture limited to a or b, rewrite rule(/(a|b)\1/) as rule(/(?:aa|bb)/) and keep the action; otherwise split the rule into states and compare matched text in actions')
      end

      def shorthand_ranges(char)
        if @unicode && @encoding != Encoding::BINARY
          property = { "d" => "Nd", "w" => "Word", "s" => "Space" }.fetch(char.downcase, nil)
          return [[AST::Property, char == char.upcase, property, ignorecase?]] if property
        end

        base = {
          "d" => [[48, 57]],
          "w" => [[48, 57], [65, 90], [95, 95], [97, 122]],
          "s" => [[9, 13], [32, 32]],
          "h" => [[48, 57], [65, 70], [97, 102]]
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
        starting = @index
        char = advance
        return AST::Anchor.new(kind: :bol, loc: span(starting)) if char == "^"

        AST::Anchor.new(kind: :eol, loc: span(starting))
      end

      def validate_anchor_positions(node)
        anchors = AST.anchors(node)
        return if anchors.empty?

        trailing = node.is_a?(AST::Seq) ? node.children.reverse_each.find { |part| !part.is_a?(AST::Empty) } : node
        anchors.each { |anchor| anchor.kind = :line_end if anchor.kind == :eol && !anchor.equal?(trailing) }

        beginnings = anchors.select { |anchor| anchor.kind == :bol }
        return if beginnings.empty? || (beginnings.one? && beginnings.first.equal?(flatten_sequence(node).first))

        raise_diagnostic(
          diagnostic("FLEXR-E009", "the beginning-of-line anchor is only valid at the outermost pattern start",
                     help: "split alternatives into separate rules or move ^ to the start of the pattern")
        )
      end

      def flatten_sequence(node)
        return [] if node.is_a?(AST::Empty)
        return node.children.flat_map { |child| flatten_sequence(child) } if node.is_a?(AST::Seq)
        return flatten_sequence(node.child) if node.is_a?(AST::NamedCapture)

        [node]
      end

      def reject_postfix_quantifier
        return unless ["?", "+"].include?(current)

        raise unsupported("lazy or possessive quantifier",
                          'for unescaped single-line quoted text, use a negated character class: rule(/"[^"\n]*"/); keep the action; removing lazy or possessive modifiers can change matches')
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

      def octal_digits(starting)
        @source[starting, 3][/\A[0-7]+/]
      end

      def read_byte_escape
        expect("\\")
        return read_exact(2).to_i(16) if consume?("x")

        digits = octal_digits(@index)
        raise_syntax("invalid byte escape") unless digits

        @index += digits.length
        digits.to_i(8)
      end

      def assign_byte(byte)
        raise_syntax("invalid byte escape") if byte > 0xff

        if @encoding == Encoding::BINARY && (!ignorecase? || byte >= 0x80)
          @escaped_byte = true
          @last_byte = byte
          return
        end

        length = case byte
        when 0x00..0x7f then 1
        when 0xc2..0xdf then 2
        when 0xe0..0xef then 3
        when 0xf0..0xf4 then 4
        else 0
        end
        bytes = [byte]
        (length - 1).times { bytes << read_byte_escape }
        raise_syntax("invalid byte escape") if bytes.any? { |part| part > 0xff }
        value = bytes.pack("C*").force_encoding(Encoding::UTF_8)
        raise_syntax("invalid UTF-8 byte escape") unless length.positive? && value.valid_encoding?

        @escaped_value = true
        @last_codepoint = value.ord
      end

      def ignorecase?
        @options.anybits?(::Regexp::IGNORECASE)
      end

      def skip_extended_space
        loop do
          @index += 1 while @source[@index]&.match?(/\s/)
          break unless @source[@index] == "#"

          @index += 1
          @index += 1 while @source[@index] && @source[@index] != "\n"
        end
      end

      def span(starting, ending = @index)
        @byte_offsets.fetch(starting)...@byte_offsets.fetch(ending)
      end
    end
  end
end
