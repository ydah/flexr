# frozen_string_literal: true

module Flexr
  module Runtime
    class Buffer
      attr_accessor :capture_source_exposed
    end

    class TaggedCaptures
      def self.for_dfa(dfa, rules)
        plans = {}
        whole = {}
        dfa.rule_ids.each do |index|
          rule = rules.fetch(index)
          next unless rule.respond_to?(:tagged_capture_programs) && rule.tagged_capture_programs

          cursors = rule.tagged_capture_programs.each_with_index.map do |program, pattern|
            next unless program
            next program.cursor unless program.whole_capture

            (whole[index] ||= {}.compare_by_identity)[rule.capture_patterns.fetch(pattern)] = program
            nil
          end
          plans[index] = cursors if cursors.any?
        end
        new(plans, whole) unless plans.empty? && whole.empty?
      end

      def initialize(plans, whole)
        @plans = plans
        @whole = whole
        @cursors = plans.values.flatten.compact
        @active = []
      end

      def reset
        return self unless tracking?

        @cursors.each(&:reset)
        @active.replace(@cursors)
        @single_cursor = (@active.pop if @active.length == 1)
        @winner = nil
        self
      end

      def tracking?
        !@cursors.empty?
      end

      def advance(byte, position)
        if @single_cursor
          @single_cursor = @single_cursor.advance(byte, position)
        elsif !@active.empty?
          @active.delete_if { |cursor| !cursor.advance(byte, position) }
          @single_cursor = @active.pop if @active.length == 1
        end
      end

      def advance_region(buffer, beginning, ending)
        while beginning < ending && (@single_cursor || !@active.empty?)
          advance(buffer.getbyte(beginning), beginning)
          beginning += 1
        end
      end

      def remember(acceptance, position)
        @winner = @plans[acceptance.rule_index]&.[](acceptance.pattern_index)&.remember(position)
      end

      def finish(match, buffer)
        return match unless match&.capture.is_a?(::Regexp)
        return match if buffer.capture_source_exposed

        if (program = @whole[match.rule.index]&.[](match.capture))
          match.capture = CapturedMatch.new(program.whole_capture, program.encoding, match, buffer)
        elsif @winner
          snapshot = @winner.snapshot
          match.capture = CapturedMatch.new(snapshot, snapshot.program.encoding, match, buffer)
        end
        match
      end

      class CapturedMatch
        attr_reader :fallback

        def initialize(snapshot, encoding, match, buffer)
          @snapshot = snapshot
          @buffer = buffer
          @start = match.start_pos
          @ending = match.end_pos
          @fallback = match.capture
          @encoding = @fallback.options.anybits?(::Regexp::NOENCODING) ? Encoding::BINARY : encoding
          @subject = subject.freeze unless buffer.stable_source&.frozen?
        end

        def valid_in?(buffer)
          @buffer.equal?(buffer) && (!@subject || @subject == subject)
        end

        def byteoffset(name)
          return [@start, @ending] if name.is_a?(Integer) && name.zero?

          range = ranges.fetch(name.to_s) { raise IndexError, "unknown capture #{name.inspect}" }
          [range&.begin, range&.end]
        end

        def named_captures(symbolize_names: false)
          if @snapshot.is_a?(String)
            name = symbolize_names ? @snapshot.to_sym : @snapshot
            return { name => capture_value(@start...@ending) }
          end

          ranges.to_h do |name, range|
            [symbolize_names ? name.to_sym : name, range && capture_value(range)]
          end
        end

        private

        def ranges
          @ranges ||= @snapshot.is_a?(String) ? { @snapshot => @start...@ending } : @snapshot.ranges
        end

        def subject
          @buffer.byteslice(@start, @ending - @start)&.force_encoding(Encoding::BINARY)
        end

        def capture_value(range)
          value = if @subject
            @subject.byteslice(range.begin - @start, range.size)
          else
            @buffer.byteslice(range.begin, range.size)
          end
          value.force_encoding(@encoding)
        end
      end
    end
  end
end
