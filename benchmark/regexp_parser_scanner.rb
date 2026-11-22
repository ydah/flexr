# frozen_string_literal: true

require "flexr"

module RegexpParserParity
  class Unsupported < StandardError; end

  class Scanner < Flexr::Lexer
    OPENERS = {
      "(" => %i[group capture], "(?:" => %i[group passive], "(?>" => %i[group atomic],
      "(?~" => %i[group absence], "(?=" => %i[assertion lookahead], "(?!" => %i[assertion nlookahead],
      "(?<=" => %i[assertion lookbehind], "(?<!" => %i[assertion nlookbehind]
    }.freeze
    METACHARS = { "." => %i[meta dot], "|" => %i[meta alternation], "^" => %i[anchor bol], "$" => %i[anchor eol] }.freeze
    QUANTIFIERS = { "?" => "zero_or_one", "*" => "zero_or_more", "+" => "one_or_more" }.freeze
    ASCII_ESCAPES = %i[bell backspace escape form_feed newline carriage tab vertical_tab].zip(%w[a b e f n r t v]).to_h.invert.freeze
    SYMBOL_ESCAPES = %i[dot alternation bol eol zero_or_one zero_or_more one_or_more group_open group_close
      interval_open interval_close set_open set_close backslash].zip('.|^$?*+(){}[]\\'.chars).to_h.invert.freeze
    ESCAPED_ANCHORS = %i[bos eos eos_ob_eol word_boundary nonword_boundary match_start].zip(%w[A z Z b B G]).to_h.invert.freeze
    TYPES = %i[digit nondigit hex nonhex space nonspace word nonword linebreak xgrapheme].zip(%w[d D h H s S w W R X]).to_h.invert.freeze
    SET_SYMBOL_ESCAPES = SYMBOL_ESCAPES.slice("[", "]", "\\").freeze
    SET_TYPES = TYPES.except("R", "X").freeze
    POSIX_CLASSES = %w[alnum alpha ascii blank cntrl digit graph lower print punct space upper word xdigit].freeze

    state :extended, inclusive: true do
      rule(/#[^\n]*\n?/) { piece(:free_space, :comment) }
      rule(/[ \t\r\n\f\v]+/) { piece(:free_space, :whitespace) }
    end

    OPENERS.each { |spelling, (type, name)| rule(spelling) { open_group(type, name) } }
    METACHARS.each { |spelling, (type, name)| rule(spelling) { piece(type, name) } }
    rule(/\(\?<[^=0-9!>-][^>]*>/) { open_group(:group, :named_ab) }
    rule(/\(\?'[^0-9'-][^']*'/) { open_group(:group, :named_sq) }
    rule(pattern("(?#") + upto(")")) { piece(:group, :comment) }
    rule("(?(") { unsupported!("conditionals") }
    rule("(?") { unsupported!("option groups or invalid group prefixes") }
    rule(")") do
      unsupported!("unbalanced groups") if @group_depth.zero?
      @group_depth -= 1
      piece(:group, :close)
    end
    rule("[") { open_set }
    rule(/[?*+](?<modifier>[?+])?/) do
      base = QUANTIFIERS.fetch(text[0])
      suffix = { "?" => "_reluctant", "+" => "_possessive" }[captures[:modifier]]
      piece(:quantifier, :"#{base}#{suffix}")
    end
    rule(/\{[0-9]+\}|\{(?:[0-9]+,[0-9]*|,[0-9]+)\}\??/) do
      piece(:quantifier, text.end_with?("?") ? :interval_reluctant : :interval)
    end
    rule(/\\[1-9]|\\[kg][<']/) { unsupported!("backreferences, calls or ambiguous numeric escapes") }
    rule(/\\0[0-7]{0,2}/) { piece(:escape, :octal) }
    rule(/\\./m) { escape(set: false) }
    rule(/[^\\\[().|?*+{^$# \t\r\n\f\v]+/) { piece(:literal_run, :literal) }
    rule(/[ \t\r\n\f\v]+|[{#]/) { piece(:literal_run, :literal) }

    state :set do
      rule("[") { open_set }
      rule("]") do
        pop
        piece(:set, :close)
      end
      rule("&&") { piece(:set, :intersection) }
      rule("^") { @previous == %i[set open] ? piece(:set, :negate) : piece(:literal, :literal) }
      rule("-", followed_by: /\]|&&/) { piece(:literal, :literal) }
      rule("-") { @previous.first == :set ? piece(:literal, :literal) : piece(:set, :range) }
      rule(/\[:(?<negated>\^)?(?<name>[^\[\]]*):\]/) do
        name = captures.fetch(:name)
        unsupported!("unknown POSIX classes") unless POSIX_CLASSES.include?(name)
        piece(captures[:negated] ? :nonposixclass : :posixclass, name.to_sym)
      end
      rule(/\\[0-7]{1,3}/) { piece(:escape, :octal) }
      rule(/\\./m) { escape(set: true) }
      rule(/[^\\]/) { piece(:literal, :literal) }
    end

    all_states do
      rule(/\\u\{[0-9A-Fa-f]{1,6}(?:[ \t\r\n\f\v][0-9A-Fa-f]{1,6})*\}/) { piece(:escape, :codepoint_list) }
      rule(/\\u[0-9A-Fa-f]{4}/) { piece(:escape, :codepoint) }
      rule(/(?:\\x[89A-Fa-f][0-9A-Fa-f])+/) { unsupported!("high hexadecimal escapes and regexp encoding") }
      rule(/\\x[0-9A-Fa-f]{1,2}/) { piece(:escape, :hex) }
    end

    def self.scan(input, options)
      if input.is_a?(Regexp)
        raise Unsupported, "options with Regexp inputs" unless options.nil?

        options = input.options
        input = input.source
      end
      source = input.dup.force_encoding(Encoding::UTF_8)
      raise Unsupported, "invalid UTF-8 bytes" unless source.valid_encoding?

      new(source).scan(extended: (options || 0).anybits?(Regexp::EXTENDED))
    end

    def scan(extended:)
      @group_depth = 0
      begin_state(:extended) if extended
      pieces = tokens
      unsupported!("unbalanced groups") unless @group_depth.zero?
      unsupported!("unbalanced sets") if state == :set

      position = 0
      output = []
      previous_run = false
      pieces.each do |(type, name), lexeme|
        finish = position + lexeme.length
        run = type == :literal_run
        if run && previous_run
          output.last[2] << lexeme
          output.last[4] = finish
        else
          output << [run ? :literal : type, name, lexeme.dup, position, finish]
        end
        previous_run = run
        position = finish
      end
      output
    rescue Flexr::LexError
      unsupported!("unrecognized input")
    end

    private

    def open_group(type, name)
      @group_depth += 1
      piece(type, name)
    end

    def open_set
      push(:set)
      piece(:set, :open)
    end

    def escape(set:)
      letter = text[1]
      unsupported!("Unicode properties") if %w[p P].include?(letter)
      unsupported!("control, meta or incomplete escapes") if %w[C M c u x].include?(letter)
      return piece(:keep, :mark) if letter == "K" && !set
      return piece(:anchor, ESCAPED_ANCHORS[letter]) if !set && ESCAPED_ANCHORS.key?(letter)

      type = (set ? SET_TYPES : TYPES)[letter]
      return piece(:type, type) if type

      symbol = (set ? SET_SYMBOL_ESCAPES : SYMBOL_ESCAPES)[letter]
      piece(:escape, ASCII_ESCAPES[letter] || symbol || :literal)
    end

    def piece(type, name)
      @previous = [type, name]
      emit(@previous, text)
    end

    def unsupported!(reason)
      raise Unsupported, reason
    end
  end
end
