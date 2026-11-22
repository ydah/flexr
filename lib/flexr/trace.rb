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

      def handle_unmatched_byte
        @flexr_trace.record_unmatched { super }
      end
    end

    attr_reader :steps

    def initialize(lexer)
      @lexer = lexer
      @steps = []
      @config = lexer.class.__flexr_config
      @compiled = lexer.class.__flexr_compiled
      @rules = lexer.class.__flexr_rules
      @lexer.singleton_class.prepend(Actions)
      @lexer.instance_variable_set(:@flexr_trace, self)
    end

    def run
      @lexer.tokens
    end

    def record(rule)
      start = @lexer.instance_variable_get(:@match_start)
      ending = @lexer.instance_variable_get(:@match_end)
      state = @lexer.state
      candidates = candidates_at(start)
      selected = candidates.find { |candidate| candidate[:rule] == rule.index }
      reason = if @config.backend == :firstmatch
        "first_match"
      elsif candidates.length == 1
        "only_match"
      elsif selected && candidates.count { |candidate| candidate[:total_length] == selected[:total_length] } > 1
        "rule_order"
      else
        "longest"
      end
      yield
      pending = @lexer.instance_variable_get(:@pending)
      bytes = @lexer.buffer.byteslice(start...ending)
      step = { byte_begin: start, byte_end: ending, next_byte: @lexer.byte_pos, state: state, next_state: @lexer.state,
               text: display_text(bytes), bytes: bytes.bytes, candidates: candidates,
               rule: rule.index, patterns: rule.patterns.map(&:inspect), reason: reason,
               action: pending ? "emit" : "skip", token: pending&.inspect }
      step[:channel] = rule.channel if rule.channel
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
        "@#{step[:byte_begin]} #{step[:text].inspect} state=#{step[:state]} " \
          "candidates: #{candidates} -> #{target} #{step[:action]} (#{step[:reason]}) " \
          "state=#{step[:next_state]}#{step[:token] && " #{step[:token]}"}"
      end.join("\n")
    end

    private

    def candidates_at(start)
      @config.backend == :firstmatch ? firstmatch_candidates(start) : dfa_candidates(start)
    end

    def dfa_candidates(start)
      dfa = @compiled.machines.fetch(@lexer.state).dfa
      best = {}
      walk(dfa, start) do |acceptance, ending|
        rule = @rules.fetch(acceptance.rule_index)
        candidate = candidate_for(rule, start, ending)
        next unless candidate
        previous = best[rule.index]
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
          regexp = pattern.is_a?(::Regexp) ? pattern : ::Regexp.new(::Regexp.escape(pattern))
          reference = Regexp::Matcher.reference?(regexp, encoding: @config.encoding, unicode: @config.options[:unicode] == true)
          match = Regexp::Matcher.match(regexp, subject, encoding: @config.encoding,
                                       unicode: @config.options[:unicode] == true, reference: reference)
          [match[0].bytesize, condition] if match&.begin(0)&.zero?
        end
        length, condition = matches.max_by(&:first)
        next unless length
        next if condition.end_anchor && !end_anchor?(start + length)

        candidate_for(rule, start, start + length)
      end
    end

    def candidate_for(rule, start, ending)
      trailing = if rule.trailing
        dfa = rule.trailing_dfa || (@trailing_dfas ||= {})[rule.index] ||= Flexr.compile_pattern(
          rule.trailing, encoding: @config.encoding, options: { unicode: @config.options[:unicode] == true }
        )
        longest = nil
        walk(dfa, ending, scan_start: start) { |_acceptance, cursor| longest = cursor - ending }
        longest
      else
        0
      end
      return if trailing.nil?

      { rule: rule.index, patterns: rule.patterns.map(&:inspect), length: ending - start,
        trailing_length: trailing, total_length: ending - start + trailing }
    end

    def walk(dfa, start, scan_start: start)
      state = dfa.start
      cursor = start
      loop do
        if @lexer.utf8_boundary?(cursor)
          dfa.accepts[state].each do |acceptance|
            next if acceptance.bol_only && !@lexer.__flexr_beginning_of_line_at?(start, scan_start)

            yield acceptance, cursor unless acceptance.end_anchor && !end_anchor?(cursor)
          end
        end
        break unless @lexer.buffer.ensure_available?(cursor + 1)
        break unless (state = dfa.transition(state, @lexer.buffer.getbyte(cursor)))

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
