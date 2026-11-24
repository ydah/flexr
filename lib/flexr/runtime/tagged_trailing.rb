# frozen_string_literal: true

module Flexr
  module Runtime
    class Buffer
      def tagged_trailing_input?
        eof_loaded? && @source.instance_of?(String) && @source.singleton_methods.empty?
      end
    end

    module TaggedTrailing
      Boundary = Data.define(:rule, :dfa, :body_end, :capture, :snapshot) unless const_defined?(:Boundary, false)
      private_constant :Boundary

      def scan(expected = nil)
        @has_tagged_trailing = @config.backend != :firstmatch && @rules.any?(&:trailing) if @has_tagged_trailing.nil?
        return super unless @has_tagged_trailing

        machine = @compiled.machines.fetch(@lexer.state)
        position = @lexer.byte_pos
        return super unless tagged_trailing_applicable?(machine, position)
        return unless @lexer.valid_utf8_at?(position)

        scan_tagged_trailing(machine, position, expected)
      end

      private

      def tagged_trailing_applicable?(machine, position)
        buffer = @lexer.buffer
        return false if @lexer.scan_steps_guarded? || !buffer.tagged_trailing_input?

        text_start = @lexer.more_text_start || position
        return false if buffer.bytesize - position > @lexer.max_lookahead_size ||
          buffer.bytesize - text_start > @lexer.max_token_size

        @tagged_trailing_machines ||= {}
        @tagged_trailing_machines.fetch(machine.dfa) do
          @tagged_trailing_machines[machine.dfa] = machine.dfa.rule_ids.any? { |index| @rules.fetch(index).trailing }
        end
      end

      def scan_tagged_trailing(machine, position, expected)
        dfa = machine.dfa
        buffer = @lexer.buffer
        state = @lexer.__flexr_dfa_start(dfa, position)
        tracker = @lexer.__send__(:__flexr_tagged_captures, dfa) if @lexer.respond_to?(:__flexr_tagged_captures, true)
        tags = tracker if tracker&.tracking?
        regions = acceleration_regions_for(machine) if !expected && acceleration_enabled?
        frontier = {}
        next_frontier = {}
        cursor = position
        best = nil
        snapshot = nil

        loop do
          if state && (cursor != position || @config.options[:allow_empty_match])
            each_body_acceptance(dfa.accepts[state], cursor, position, buffer, expected) do |acceptance, rule|
              if rule.trailing
                start_tagged_trailer(frontier, acceptance, rule, cursor, position, tags)
              elsif preferred_tagged_match?(best, rule, cursor, cursor)
                best = reusable_match(rule, position, cursor, cursor)
                best.capture = rule.capture_patterns&.[](acceptance.pattern_index)
                tags&.remember(acceptance, cursor)
              end
            end
          end
          frontier.each do |(_, trailer_state, _), boundary|
            next unless preferred_tagged_match?(best, boundary.rule, boundary.body_end, cursor)
            next unless trailing_accept?(boundary.dfa, trailer_state, buffer, cursor, boundary.body_end, boundary.rule)

            best = reusable_match(boundary.rule, position, boundary.body_end, cursor)
            best.capture = boundary.capture
            snapshot = boundary.snapshot
          end
          break if cursor >= buffer.bytesize

          if state && frontier.empty? && (region = regions&.[](state)) && !@disabled_auto_acceleration&.key?(region)
            ending = accelerate(region, buffer, cursor,
                                token_rule: dfa.accepts[state].first&.rule_index, token_start: position)
            if ending && ending > cursor
              tags&.advance_region(buffer, cursor, ending)
              cursor = ending
              next
            end
          end

          byte = buffer.getbyte(cursor)
          state = transition(dfa, state, byte) if state
          tags&.advance(byte, cursor) if state
          advance_tagged_trailers(frontier, next_frontier, byte)
          frontier, next_frontier = next_frontier, frontier
          break unless state || !frontier.empty?

          cursor += 1
        end

        return best unless tracker
        return tracker.finish(best, buffer) { snapshot } if best&.rule&.trailing

        tracker.finish(best, buffer)
      end

      def start_tagged_trailer(frontier, acceptance, rule, cursor, position, tags)
        dfa = rule.trailing_dfa || trailing_dfa(rule.trailing)
        state = @lexer.__flexr_dfa_start(dfa, cursor, position)
        bol = @lexer.__flexr_beginning_of_line_at?(cursor, position)
        key = [rule.index, state, bol]
        return if frontier[key]&.body_end == cursor

        capture = rule.capture_patterns&.[](acceptance.pattern_index)
        frontier[key] = Boundary.new(rule: rule, dfa: dfa, body_end: cursor, capture: capture,
                                     snapshot: tags&.snapshot_at(acceptance, cursor))
      end

      def each_body_acceptance(acceptances, cursor, position, buffer, expected)
        acceptances.each do |acceptance|
          rule = @rules.fetch(acceptance.rule_index)
          next if acceptance.bol_only && !@lexer.beginning_of_line?
          next unless @lexer.utf8_boundary?(cursor)
          next if expected && !expected_rule?(rule, expected, buffer, position, cursor)
          next unless acceptance.valid_end_at?(buffer, cursor, @lexer, rule)

          yield acceptance, rule
        end
      end

      def advance_tagged_trailers(frontier, next_frontier, byte)
        next_frontier.clear
        frontier.each do |(index, state, bol), boundary|
          target = boundary.dfa.transition(state, byte)
          next unless target

          key = [index, target, bol]
          previous = next_frontier[key]
          next_frontier[key] = boundary if !previous || boundary.body_end > previous.body_end
        end
      end

      def preferred_tagged_match?(best, rule, body_end, total_end)
        return true if !best || total_end > best.total_end_pos
        return false if total_end < best.total_end_pos || rule.loses_priority_tie?(best.rule)

        !rule.equal?(best.rule) || body_end > best.end_pos
      end

      Interpreter.prepend(self)
    end
  end
end
