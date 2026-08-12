# frozen_string_literal: true

module Flexr
  class Importer
    Result = Struct.new(:source, :warnings, :complete?, keyword_init: true)

    class UnsupportedFormatError < CompileError; end

    def self.import(path)
      new(path, File.binread(path)).run
    end

    def initialize(path, source)
      @path = path
      @source = source.force_encoding(Encoding::UTF_8)
      @warnings = []
      @complete = true
      @macros = {}
      @states = {}
      @rules = []
      @eof_rules = []
      @last_action = nil
    end

    def run
      case File.extname(@path).downcase
      when ".l", ".lex"
        parse_flex
      when ".rex"
        parse_rexical
      else
        raise UnsupportedFormatError, "import expects a flex .l or rexical .rex file"
      end

      Result.new(source: render, warnings: @warnings.freeze, complete?: @complete)
    end

    private

    def parse_flex
      sections = @source.split(/^%%\s*$/)
      raise CompileError, "flex specification must contain a %% rule separator" if sections.length < 2

      declarations = sections.shift
      rules = sections.shift
      footer = sections.join("%%\n")
      parse_declarations(declarations)
      parse_rules(rules)
      add_comment_block(footer, "footer") unless footer.strip.empty?
    end

    def parse_rexical
      @warnings << "Rexical uses first-match semantics; imported rules will use flexr longest-match semantics"
      @source.scan(/^\s*macro\s*\n(.*?)^\s*end\s*$/m) do |body|
        body.first.each_line do |line|
          name, expression = line.strip.split(/\s+/, 2)
          @macros[name] = expression if name && expression
        end
      end
      match = @source.match(/^\s*rule\s*\n(.*?)^\s*end\s*$/m)
      raise CompileError, "rexical specification has no rule section" unless match

      parse_rules(match[1].lines.map { |line| normalize_rexical_line(line) }.join)
      warn_rexical_semantic_differences
      header = @source.lines.take_while { |line| !line.match?(/^\s*(?:macro|rule)\b/) }.join
      add_comment_block(header, "rexical header") unless header.strip.empty?
    end

    def parse_declarations(text)
      text.each_line do |line|
        stripped = line.strip
        case stripped
        when "", /^%\{/
          next
        when /^%x\s+(.+)/
          ::Regexp.last_match(1).split.each { |name| @states[name] = false }
        when /^%s\s+(.+)/
          ::Regexp.last_match(1).split.each { |name| @states[name] = true }
        when /^%token\s+(.+)/
          @declared_tokens ||= []
          @declared_tokens.concat(::Regexp.last_match(1).split.map(&:to_sym))
        when /^%option\s+(.+)/
          parse_flex_options(::Regexp.last_match(1))
        when /^%[A-Za-z]/
          warn_incomplete("unsupported flex declaration: #{stripped}")
        when /^([A-Za-z_]\w*)\s+(.+)/
          @macros[::Regexp.last_match(1)] = ::Regexp.last_match(2).strip
        else
          add_comment_block(line, "declaration")
        end
      end
    end

    def parse_rules(text)
      lines = text.each_line.to_a
      index = 0
      pending_pattern = nil

      while index < lines.length
        line = lines[index]
        index += 1
        next if line.strip.empty? || line.lstrip.start_with?("/*")

        pattern, action = split_rule_line(line)
        if pattern && action
          action, index = collect_action(action, lines, index)
        elsif pattern
          pending_pattern = pattern
          next
        elsif pending_pattern
          action = line.strip
          action, index = collect_action(action, lines, index)
          pattern = pending_pattern
          pending_pattern = nil
        else
          warn_incomplete("could not parse flex rule: #{line.strip}")
          next
        end

        add_rule(pattern, action)
      end
      warn_incomplete("rule has no action: #{pending_pattern}") if pending_pattern
    end

    def collect_action(action, lines, index)
      return [action, index] unless action.lstrip.start_with?("{")

      depth = brace_delta(action)
      while depth.positive? && index < lines.length
        action = "#{action}#{lines[index]}"
        depth += brace_delta(lines[index])
        index += 1
      end
      warn_incomplete("unterminated flex action") if depth.positive?
      [action, index]
    end

    def add_rule(pattern, action)
      if pattern.strip == "<<EOF>>"
        action_expression, complete = translate_action(action)
        @complete = false unless complete
        @eof_rules << [[], action_expression]
        return
      end

      states, pattern = extract_states(pattern)
      if pattern == "<<EOF>>"
        action_expression, complete = translate_action(action)
        @complete = false unless complete
        @eof_rules << [states, action_expression]
        return
      end

      expanded = expand_macros(pattern)
      expression = normalize_pattern(expanded)
      action_expression, complete = translate_action(action)
      @complete = false unless complete
      @rules << { states: states, pattern: expression, raw_pattern: expanded, action: action_expression }
      @last_action = action_expression
    end

    def extract_states(pattern)
      match = pattern.match(/\A<([^>]+)>/)
      return [[], pattern] unless match

      names = match[1].split(",").map(&:strip)
      names = @states.keys if names.include?("*")
      names = names.map { |name| name == "INITIAL" ? :initial : name.to_sym }
      [names, pattern.delete_prefix(match[0]).strip]
    end

    def expand_macros(pattern)
      result = pattern.dup
      10.times do
        before = result
        @macros.sort_by { |name, _| -name.length }.each do |name, expression|
          result = result.gsub("{#{name}}", "(?:#{expression})")
        end
        break if before == result
      end
      warn_incomplete("unresolved flex macro in #{pattern}") if result.match?(/\{[A-Za-z_]\w*\}/)
      result
    end

    def normalize_pattern(pattern)
      return "" if pattern == ""

      result = +""
      index = 0
      class_depth = 0
      while index < pattern.length
        if pattern[index] == '"' && class_depth.zero?
          finish = index + 1
          escaped = false
          while finish < pattern.length
            char = pattern[finish]
            break if char == '"' && !escaped

            escaped = char == "\\" && !escaped
            escaped = false unless char == "\\"
            finish += 1
          end
          if finish >= pattern.length
            warn_incomplete("unterminated quoted flex pattern: #{pattern}")
            return pattern.inspect
          end
          result << ::Regexp.escape(unescape_flex(pattern[(index + 1)...finish]))
          index = finish + 1
        else
          class_depth += 1 if pattern[index] == "["
          class_depth -= 1 if pattern[index] == "]" && class_depth.positive?
          result << pattern[index]
          index += 1
        end
      end
      result.inspect
    end

    def translate_action(action)
      value = action.to_s.strip
      return ["skip: true", true] if value.empty? || value == ";"
      return [@last_action || "skip: true", !@last_action.nil?] if value == "|"

      body = if value.start_with?("{") && value.end_with?("}")
        value[1...-1]
      else
        value
      end
      translated = body.dup
      translated.gsub!(/\byytext\b/, "text")
      translated.gsub!(/\byyleng\b/, "text.bytesize")
      translated.gsub!(/\byylineno\b/, "lineno")
      translated.gsub!(/\bBEGIN\s*\(\s*([A-Za-z_]\w*)\s*\)/, 'begin_state :\1')
      translated.gsub!(/\byyless\s*\(\s*([^)]*)\)/, 'less(\1)')
      translated.gsub!(/\byymore\s*\(\s*\)/, "more")
      translated.gsub!(/\bECHO\b/, "echo")

      returns = translated.scan(/\breturn\s+([^;]+);?/)
      translated.gsub!(/\breturn\s+([^;]+);?\s*/) { "emit #{token_expression(::Regexp.last_match(1))}\n" }
      translated.gsub!(/\breturn\s*;/, "skip\n")

      complete = true
      unless translated.match?(/\A\s*(?:emit\b|skip\b|echo\b|more\b|less\b|begin_state\b|[A-Za-z_]\w*\s*=|#|\z)/)
        warn_incomplete("FLEXR-TODO: manual action translation required: #{body.strip}")
        translated = "# FLEXR-TODO: translate imported action: #{body.strip.inspect}\n  skip"
        complete = false
      end
      if returns.any? && translated.scan(/\bemit\b/).empty?
        warn_incomplete("FLEXR-TODO: could not translate flex return action: #{body.strip}")
        translated = "# FLEXR-TODO: translate imported action: #{body.strip.inspect}\n  skip"
        complete = false
      end
      ["do\n  #{translated.strip}\nend", complete]
    end

    def render
      lines = ["# Generated by flexr import. Review semantic warnings before use.", "require \"flexr\"", "", "class Lexer < Flexr::Lexer"]
      lines.concat(render_comments)
      lines << "  emits #{@declared_tokens.map(&:inspect).join(', ')}" if @declared_tokens&.any?
      @states.each do |name, inclusive|
        lines << "  state #{name.inspect}, inclusive: #{inclusive} do" unless @rules.any? { |rule| rule[:states].include?(name.to_sym) }
        lines << "  end" unless @rules.any? { |rule| rule[:states].include?(name.to_sym) }
      end
      @rules.each do |rule|
        lines.concat(render_rule(rule))
      end
      @eof_rules.each do |states, action|
        states = [:initial] if states.empty?
        states.each do |state|
          if state == :initial
            lines << "  on_eof #{action}"
          else
            lines << "  state #{state.inspect} do"
            lines << "    on_eof #{action}"
            lines << "  end"
          end
        end
      end
      lines << "end"
      lines << ""
      lines.concat(@comments_after_class || [])
      "#{lines.join("\n")}\n"
    end

    def render_rule(rule)
      action = rule[:action]
      states = rule[:states]
      if states.empty? || states == [:initial]
        [render_rule_call("  ", rule[:pattern], action)]
      else
        states.map do |state|
          if state == :initial
            render_rule_call("  ", rule[:pattern], action)
          else
            inclusive = @states[state.to_s] == true ? ", inclusive: true" : ""
            "  state #{state.inspect}#{inclusive} do\n#{render_rule_call('    ', rule[:pattern], action)}\n  end"
          end
        end
      end
    end

    def render_rule_call(indent, pattern, action)
      prefix = "#{indent}rule(Regexp.new(#{pattern})"
      return "#{prefix}, #{action})" unless action.start_with?("do\n")

      lines = action.lines.map(&:chomp)
      body = lines.drop(1).map { |line| "#{indent}#{line}" }
      "#{prefix}) #{([lines.first] + body).join("\n")}"
    end

    def token_expression(value)
      value = value.strip
      value.match?(/\A[A-Za-z_]\w*\z/) ? ":#{value}" : value
    end

    def render_comments
      @comments || []
    end

    def add_comment_block(text, label)
      @comments ||= []
      @comments << "  # Imported #{label}:"
      text.each_line { |line| @comments << "  # #{line.chomp}" }
    end

    def warn_incomplete(message)
      @warnings << message
      @complete = false
    end

    def parse_flex_options(text)
      text.split(/[\s,]+/).reject(&:empty?).each do |option|
        next if option == "yylineno"

        warn_incomplete("unsupported flex option #{option}")
      end
    end

    def warn_rexical_semantic_differences
      @rules.each_index do |first_index|
        ((first_index + 1)...@rules.length).each do |second_index|
          first = @rules[first_index]
          second = @rules[second_index]
          next unless rexical_rules_overlap?(first, second)

          counterexample = rexical_counterexample(first[:raw_pattern], second[:raw_pattern])
          next unless counterexample

          input, first_length, second_length = counterexample
          @warnings << <<~WARNING.chomp
            Rexical rules #{first_index} and #{second_index} differ under first-match vs longest-match: #{input.inspect} is a counterexample; first-match selects rule #{first_index} (#{first_length} bytes), while longest-match selects rule #{second_index} (#{second_length} bytes)
          WARNING
        end
      end
    end

    def rexical_rules_overlap?(first, second)
      first_states = first[:states].empty? ? [:initial] : first[:states]
      second_states = second[:states].empty? ? [:initial] : second[:states]
      first_states.intersect?(second_states)
    end

    def rexical_counterexample(first_pattern, second_pattern)
      regexps = [first_pattern, second_pattern].map { |pattern| ::Regexp.new(pattern) }
      if (automata = regexps.map { |regexp| rexical_dfa(regexp) }) && automata.all?
        candidate = rexical_dfa_counterexample(regexps, automata)
        return candidate if candidate
      end

      rexical_candidate_inputs([first_pattern, second_pattern]).each do |input|
        lengths = rexical_match_lengths(regexps, input)
        return lengths if lengths
      end
      nil
    rescue RegexpError, ArgumentError
      nil
    end

    def rexical_dfa(regexp)
      dfa = Flexr.compile_pattern(regexp)
      return unless dfa.respond_to?(:accepts) && dfa.respond_to?(:transition)

      dfa
    rescue Flexr::Error, RegexpError, ArgumentError
      nil
    end

    def rexical_dfa_counterexample(regexps, automata)
      first, second = automata
      input = Automaton::Analysis.firstmatch_counterexample(first, second)
      input && rexical_match_lengths(regexps, input)
    end

    def rexical_match_lengths(regexps, input)
      matches = regexps.map do |regexp|
        regexp.match(input.dup.force_encoding(regexp.encoding))
      end
      return unless matches.all? { |match| match&.begin(0)&.zero? && !match[0].empty? }

      lengths = matches.map { |match| match[0].bytesize }
      lengths[0] < lengths[1] ? [input, *lengths] : nil
    rescue ArgumentError, EncodingError
      nil
    end

    def rexical_candidate_inputs(patterns)
      characters = (%w[x a b 0 1 _] + patterns.flat_map { |pattern| rexical_candidate_characters(pattern) }).uniq.first(24)
      fragments = patterns.flat_map { |pattern| rexical_literal_fragments(pattern) }
        .reject(&:empty?).uniq.first(24)
      seeds = (fragments + characters).uniq
      candidates = []

      seeds.each do |seed|
        candidates.push(seed, seed * 2, seed * 3)
      end
      fragments.each do |fragment|
        characters.each do |character|
          candidates << "#{fragment}#{character}"
          candidates << "#{character}#{fragment}"
        end
      end
      fragments.combination(2) { |left, right| candidates << "#{left}#{right}" }

      candidates.uniq.each_with_index
        .sort_by { |candidate, index| [candidate.bytesize, index] }.map(&:first)
    end

    def rexical_candidate_characters(pattern)
      escaped = pattern.scan(/\\x([0-9A-Fa-f]{2})|\\(.)/).filter_map do |hex, character|
        if hex
          byte = hex.to_i(16)
          [byte].pack("C").force_encoding(Encoding::UTF_8) if byte < 0x80
        else
          { "n" => "\n", "r" => "\r", "t" => "\t", "f" => "\f", "v" => "\v" }[character] ||
            (character unless %w[d D w W s S A Z b B p P G K].include?(character))
        end
      end
      pattern.each_char.grep(/[A-Za-z0-9_]/) + escaped
    end

    def rexical_literal_fragments(pattern)
      fragments = []
      current = +""
      in_class = false
      escaped = false
      flush = lambda do
        fragments << current unless current.empty?
        current = +""
      end

      pattern.each_char do |character|
        if escaped
          if { "n" => "\n", "r" => "\r", "t" => "\t", "f" => "\f", "v" => "\v" }.key?(character)
            current << { "n" => "\n", "r" => "\r", "t" => "\t", "f" => "\f", "v" => "\v" }.fetch(character)
          elsif character.match?(/[dDwWsSAZbBpPGK]/)
            flush.call
          else
            current << character
          end
          escaped = false
        elsif character == "\\"
          escaped = true
        elsif in_class
          in_class = false if character == "]"
        elsif character == "["
          flush.call
          in_class = true
        elsif character.match?(/[A-Za-z0-9_]/)
          current << character
        else
          flush.call
        end
      end
      flush.call unless current.empty?
      fragments
    end

    def split_rule_line(line)
      source = line.strip
      return [nil, nil] if source.empty?

      quote = nil
      class_depth = 0
      escaped = false
      source.each_char.with_index do |char, index|
        if quote
          quote = nil if char == quote && !escaped
        elsif char == '"' && class_depth.zero?
          quote = char
        elsif char == "["
          class_depth += 1
        elsif char == "]" && class_depth.positive?
          class_depth -= 1
        elsif char.match?(/\s/) && class_depth.zero?
          return [source[0...index], source[index..].strip]
        end
        escaped = char == "\\" && !escaped
        escaped = false unless char == "\\"
      end
      [source, nil]
    end

    def brace_delta(text)
      text.count("{") - text.count("}")
    end

    def unescape_flex(text)
      text.gsub(/\\([\\"])/, '\\1')
    end

    def normalize_rexical_line(line)
      stripped = line.strip
      if stripped.match?(%r{\A/}) && (finish = stripped.rindex("/")) && finish.positive?
        pattern = stripped[1...finish]
        rest = stripped[(finish + 1)..].to_s
        "#{pattern} #{rest}\n"
      else
        line
      end
    end
  end
end
