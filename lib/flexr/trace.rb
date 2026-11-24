# frozen_string_literal: true

require_relative "runtime" unless defined?(Flexr::Lexer)

module Flexr
  class Trace
    module Actions
      private

      def execute(rule)
        @flexr_trace.record(rule) { super }
      end

      public

      def instance_exec(*args, &block)
        if block.equal?(self.class.__flexr_spec.eof_rules[state])
          @flexr_trace.record_eof { super }
        else
          super
        end
      end

      private

      def handle_unmatched_byte(...)
        @flexr_trace.record_unmatched { super }
      end
    end

    attr_reader :steps

    def initialize(lexer, residuals: false)
      @lexer = lexer
      @steps = []
      @config = lexer.class.__flexr_config
      @compiled = lexer.class.compile!
      @rules = lexer.class.__flexr_rules
      @derivatives = compile_residuals if residuals
      @lexer.singleton_class.prepend(Actions)
      @lexer.instance_variable_set(:@flexr_trace, self)
    end

    def run
      @lexer.tokens
    end

    def select_shortest(match, expected)
      @shortest_choice = describe_candidate(match.rule, match.end_pos - match.start_pos, match.total_end_pos - match.end_pos)
      @shortest_expected = expected
    end

    def record(rule)
      start = @lexer.instance_variable_get(:@match_start)
      ending = @lexer.instance_variable_get(:@match_end)
      state = @lexer.state
      shortest = @config.options[:shortest_states]&.include?(state)
      observed = @shortest_choice
      expected = @shortest_expected
      @shortest_choice = nil
      @shortest_expected = nil
      candidates = if shortest && observed && !buffered_shortest_trace?
        [observed]
      else
        candidates_at(start, shortest, expected)
      end
      selected = candidates.find { |candidate| candidate[:rule] == rule.index }
      length_key = shortest ? :length : :total_length
      ties = selected ? candidates.select { |candidate| candidate[length_key] == selected[length_key] } : []
      reason = if @config.backend == :firstmatch
        "first_match"
      elsif candidates.length == 1 && !shortest
        "only_match"
      elsif ties.length > 1
        ties.count { |candidate| candidate.fetch(:priority, 0) == rule.priority } > 1 ? "rule_order" : "priority"
      elsif shortest
        "shortest"
      else
        "longest"
      end
      if @derivatives
        bytes = @lexer.buffer.byteslice(start...ending)
        path = residual_path(state, start, bytes)
      end
      yield
      pending = @lexer.instance_variable_get(:@pending)
      bytes ||= @lexer.buffer.byteslice(start...ending)
      step = { byte_begin: start, byte_end: ending, next_byte: @lexer.byte_pos, state: state, next_state: @lexer.state,
               text: display_text(bytes), bytes: bytes.bytes, candidates: candidates,
               rule: rule.index, patterns: rule.patterns.map(&:inspect), reason: reason,
               action: pending ? "emit" : "skip", token: pending&.inspect }
      step[:channel] = rule.channel if rule.channel
      step[:dfa_path] = path if @derivatives
      @steps << step
    end

    def record_eof
      position = @lexer.byte_pos
      state = @lexer.state
      yield
      pending = @lexer.instance_variable_get(:@pending)
      @steps << { byte_begin: position, byte_end: position, next_byte: @lexer.byte_pos,
                  state: state, next_state: @lexer.state, text: "", bytes: [], candidates: [],
                  rule: nil, patterns: [], reason: "eof", action: pending ? "emit" : "skip", token: pending&.inspect }
    end

    def record_unmatched
      position = @lexer.byte_pos
      state = @lexer.state
      bytes = @lexer.buffer.byteslice(position, 1)
      token = yield
      @steps << { byte_begin: position, byte_end: position + 1, next_byte: @lexer.byte_pos,
                  state: state, next_state: @lexer.state, text: display_text(bytes), bytes: bytes.bytes,
                  candidates: [], rule: nil, patterns: [], reason: "unmatched",
                  action: token ? "emit" : "skip", token: token&.inspect }
      token
    end

    def render
      steps.map do |step|
        candidates = step[:candidates].map do |candidate|
          "rule #{candidate[:rule]}(#{candidate[:length]}/#{candidate[:total_length]})"
        end.join(" ")
        target = step[:rule] ? "rule #{step[:rule]}" : step[:reason]
        target += " channel=#{step[:channel].inspect}" if step[:channel]
        line = "@#{step[:byte_begin]} #{step[:text].inspect} state=#{step[:state]} " \
          "candidates: #{candidates} -> #{target} #{step[:action]} (#{step[:reason]}) " \
          "state=#{step[:next_state]}#{step[:token] && " #{step[:token]}"}"
        step[:dfa_path]&.each do |entry|
          line << "\n  @#{entry.fetch(:byte_offset)} DFA #{entry.fetch(:state)}: " \
            "#{Automaton::DerivativeResiduals.render(entry.fetch(:residuals))}"
        end
        line
      end.join("\n")
    end

    private

    def compile_residuals
      spec = @lexer.class.__flexr_spec
      spec.rules = spec.rules.map { |rule| rule.dup.tap { |copy| copy.capture_patterns = nil } }
      Automaton::Compiler.new(spec, construction: :derivative, retain_residuals: true).compile
    end

    def residual_path(state_name, start, bytes)
      machine = @derivatives.machines.fetch(state_name)
      dfa = machine.dfa
      state = @lexer.__flexr_dfa_start(dfa, start, start)
      entries = [{ byte_offset: start, state: state, residuals: machine.residuals.describe(state) }]
      bytes.each_byte.with_index(1) do |byte, offset|
        state = dfa.transition(state, byte)
        break unless state

        entries << { byte_offset: start + offset, state: state, residuals: machine.residuals.describe(state) }
      end
      entries
    end

    def candidates_at(start, shortest, expected)
      @config.backend == :firstmatch ? firstmatch_candidates(start) : dfa_candidates(start, shortest, expected)
    end

    def buffered_shortest_trace?
      buffer = @lexer.buffer
      source = buffer.stable_source
      buffer.eof_loaded? && source.instance_of?(String) && source.singleton_methods.empty?
    end

    def dfa_candidates(start, shortest, expected)
      dfa = @compiled.machines.fetch(@lexer.state).dfa
      best = {}
      interpreter = Runtime::Interpreter.new(@lexer) if expected
      scalar_rows = Runtime::ShortestMatch::UTF8_ROWS if shortest && @config.encoding == Encoding::UTF_8
      walk(dfa, start, scalar_rows: scalar_rows) do |acceptance, ending|
        rule = @rules.fetch(acceptance.rule_index)
        previous = best[rule.index]
        next if shortest && (previous || (start == ending && !@config.options[:allow_empty_match]))
        next if interpreter && !interpreter.__send__(:expected_rule?, rule, expected, @lexer.buffer, start, ending)

        candidate = candidate_for(rule, start, ending, scalar_rows: scalar_rows)
        next unless candidate

        best[rule.index] = candidate if !previous || candidate[:total_length] >= previous[:total_length]
      end
      best.values.sort_by { |candidate| candidate[:rule] }
    end

    def firstmatch_candidates(start)
      state = @config.states.fetch(@lexer.state)
      @lexer.buffer.read_to_end
      ending = @lexer.buffer.bytesize
      if @config.encoding == Encoding::UTF_8
        ending = start
        ending += @lexer.buffer.utf8_character_length(ending) while
          ending < @lexer.buffer.bytesize && @lexer.buffer.valid_utf8_at?(ending)
      end
      subject = @lexer.buffer.byteslice(start...ending).to_s
      subject.force_encoding(@config.encoding)
      @rules.filter_map do |rule|
        next unless rule.states.include?(@lexer.state) || (state.inclusive && rule.states.include?(:initial))
        matches = rule.patterns.each_with_index.filter_map do |pattern, index|
          condition = rule.pattern_conditions.fetch(index)
          next if condition.bol_only && !@lexer.beginning_of_line?
          context = rule.contextual_patterns&.[](index)
          context = nil if context&.replay
          match = if context
            context.match(@lexer, rule, start)
          else
            regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern))
            reference = Regexp::Matcher.reference?(regexp, encoding: @config.encoding, unicode: @config.options[:unicode] == true)
            Regexp::Matcher.match(regexp, subject, encoding: @config.encoding,
                                 unicode: @config.options[:unicode] == true, reference: reference)
          end
          [match[0].bytesize, condition] if match && (context || match.begin(0).zero?)
        end
        length, condition = matches.max_by(&:first)
        next unless length
        next if condition.end_anchor && !end_anchor?(start + length)

        candidate_for(rule, start, start + length)
      end
    end

    def candidate_for(rule, start, ending, scalar_rows: nil)
      trailing = if rule.trailing
        dfa = rule.trailing_dfa || (@trailing_dfas ||= {})[rule.index] ||= Flexr.compile_pattern(
          rule.trailing, encoding: @config.encoding, options: { unicode: @config.options[:unicode] == true }
        )
        longest = nil
        walk(dfa, ending, scan_start: start, scalar_rows: scalar_rows) do |_acceptance, cursor|
          longest = cursor - ending
        end
        longest
      else
        0
      end
      return if trailing.nil?

      describe_candidate(rule, ending - start, trailing)
    end

    def describe_candidate(rule, length, trailing)
      candidate = { rule: rule.index, patterns: rule.patterns.map(&:inspect), length: length,
                    trailing_length: trailing, total_length: length + trailing }
      candidate[:priority] = rule.priority unless rule.priority.zero?
      candidate
    end

    def walk(dfa, start, scan_start: start, scalar_rows: nil)
      state = @lexer.__flexr_dfa_start(dfa, start, scan_start)
      cursor = start
      scalar = 0
      loop do
        if scalar.zero? && @lexer.utf8_boundary?(cursor)
          dfa.accepts[state].each do |acceptance|
            next if acceptance.bol_only && !@lexer.__flexr_beginning_of_line_at?(start, scan_start)

            yield acceptance, cursor if acceptance.valid_end_at?(@lexer.buffer, cursor)
          end
        end
        break unless @lexer.buffer.ensure_available?(cursor + 1)
        byte = @lexer.buffer.getbyte(cursor)
        break unless (state = dfa.transition(state, byte))
        scalar = scalar_rows[scalar][byte] if scalar_rows
        break unless scalar

        cursor += 1
      end
    end

    def end_anchor?(position)
      @lexer.buffer.eof?(position) || @lexer.buffer.getbyte(position) == 0x0a
    end

    def display_text(bytes)
      bytes.dup.force_encoding(Encoding::UTF_8).scrub
    end
  end
end
