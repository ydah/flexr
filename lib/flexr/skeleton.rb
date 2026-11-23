# frozen_string_literal: true

require_relative "testing"

module Flexr
  class Skeleton
    UTF8_TAILS = {
      1 => [0x80..0xbf, 0],
      2 => [0x80..0xbf, 1],
      3 => [0x80..0xbf, 2],
      0xe0 => [0xa0..0xbf, 1],
      0xed => [0x80..0x9f, 1],
      0xf0 => [0x90..0xbf, 2],
      0xf4 => [0x80..0x8f, 2]
    }.freeze
    BYTE_ORDER = ((32..126).to_a + (0..31).to_a + (127..255).to_a).freeze

    def initialize(compiled, encoding:)
      @compiled = compiled
      @utf8 = encoding == Encoding::UTF_8
      @completion = { 0 => "".b.freeze }
    end

    def report
      cases = []
      uncovered = []
      total = 0
      @compiled.machines.each do |name, machine|
        dfa = machine.dfa
        witnesses = transition_witnesses(dfa)
        dfa.transitions.each_with_index do |row, from|
          row.each_with_index do |to, byte_class|
            next unless to

            total += 1
            next if witnesses.key?([from, byte_class])

            uncovered << transition(from, byte_class, to).merge(
              state: name, reason: @utf8 ? "no_valid_input" : "unreachable"
            )
          end
        end
        witnesses.values.uniq.sort_by { |input| [input.bytesize, input] }.unshift("".b).each do |input|
          cases << describe(dfa, name, input)
        end
      end
      { coverage: { covered: total - uncovered.length, total: total, uncovered: uncovered }, cases: cases }
    end

    def self.human(report)
      coverage = report.fetch(:coverage)
      lines = ["DFA transitions: #{coverage.fetch(:covered)}/#{coverage.fetch(:total)} covered"]
      coverage.fetch(:uncovered).each do |edge|
        lines << "  #{edge.fetch(:state)}: #{edge.fetch(:from)} -> #{edge.fetch(:to)} " \
          "(byte class #{edge.fetch(:byte_class)}, #{edge.fetch(:reason).tr('_', ' ')})"
      end
      report.fetch(:cases).group_by { |item| item.fetch(:state) }.each do |state, cases|
        lines << "State #{state.inspect}"
        cases.each do |item|
          rules = item.fetch(:rule_bodies).map { |body| "#{body.fetch(:rule)} (#{body.fetch(:bytes)} B)" }
          line = "  #{display_input(item.fetch(:input))} (#{item.fetch(:transitions).length} transitions)"
          line << ", rules #{rules.join(', ')}" unless rules.empty?
          lines << line
        end
      end
      if (verification = report[:verification])
        lines << "Parity: #{verification.fetch(:matched)}/#{verification.fetch(:compared)} cases matched in " \
          "#{verification.fetch(:modes).join(', ')}"
        verification.fetch(:mismatches).each do |item|
          lines << "  #{item.fetch(:state)} #{display_input(item.fetch(:input))} #{JSON.generate(item.fetch(:outcomes))}"
        end
      end
      lines.join("\n")
    end

    def self.display_input(input)
      input.is_a?(String) ? input.inspect : input.fetch("bytes").pack("C*").dump
    end
    private_class_method :display_input

    private

    def transition_witnesses(dfa)
      steps = steps_by_encoding_state(dfa)
      paths = [[[dfa.start, 0], nil, nil, 0]]
      seen = { [dfa.start, 0] => true }
      witnesses = {}
      completions = {}
      cursor = 0
      while cursor < paths.length
        (from, encoding_state), _, _, depth = paths.fetch(cursor)
        row = dfa.transitions.fetch(from)
        steps.fetch(encoding_state).each do |(byte_class, next_state), byte|
          to = row.fetch(byte_class)
          next unless to

          edge = [from, byte_class]
          suffix = dfa_completion(dfa, to, next_state, steps, completions) || completion(next_state)
          size = depth + 1 + suffix.bytesize
          previous = witnesses[edge]
          witnesses[edge] = [size, cursor, byte, suffix] if !previous || size < previous.first

          target = [to, next_state]
          next if seen[target]

          seen[target] = true
          paths << [target, cursor, byte, depth + 1]
        end
        cursor += 1
      end
      witnesses.transform_values do |_, parent, byte, suffix|
        Automaton::Analysis.example_input(paths, parent) + byte.chr(Encoding::BINARY) + suffix
      end
    end

    def steps_by_encoding_state(dfa)
      states = @utf8 ? [0, *UTF8_TAILS.keys] : [0]
      states.to_h do |state|
        representatives = {}
        BYTE_ORDER.each do |byte|
          following = advance_encoding(state, byte)
          next unless following

          representatives[[dfa.ec.fetch(byte), following]] ||= byte
        end
        [state, representatives]
      end
    end

    def advance_encoding(state, byte)
      return 0 unless @utf8
      unless state.zero?
        range, following = UTF8_TAILS.fetch(state)
        return following if range.cover?(byte)

        return
      end

      case byte
      when 0x00..0x7f then 0
      when 0xc2..0xdf then 1
      when 0xe0 then 0xe0
      when 0xe1..0xec, 0xee..0xef then 2
      when 0xed then 0xed
      when 0xf0 then 0xf0
      when 0xf1..0xf3 then 3
      when 0xf4 then 0xf4
      end
    end

    def dfa_completion(dfa, state, encoding_state, steps, cache)
      return completion(0) if encoding_state.zero?

      key = [state, encoding_state]
      return cache[key] if cache.key?(key)

      row = dfa.transitions.fetch(state)
      steps.fetch(encoding_state).each do |(byte_class, following), byte|
        target = row.fetch(byte_class)
        next unless target

        suffix = dfa_completion(dfa, target, following, steps, cache)
        return cache[key] = byte.chr(Encoding::BINARY) + suffix if suffix
      end
      cache[key] = nil
    end

    def completion(state)
      @completion[state] ||= begin
        range, following = UTF8_TAILS.fetch(state)
        range.begin.chr(Encoding::BINARY) + completion(following)
      end
    end

    def describe(dfa, name, bytes)
      current = dfa.start
      encoding_state = 0
      transitions = []
      rule_bodies = []
      (0..bytes.bytesize).each do |offset|
        byte = bytes.getbyte(offset)
        if encoding_state.zero?
          dfa.accepts.fetch(current).each do |acceptance|
            next if acceptance.end_anchor && !acceptance.valid_end_at?(bytes, offset)

            rule_bodies << { rule: acceptance.rule_index, bytes: offset }
          end
        end
        break unless byte

        target = dfa.transition(current, byte)
        break unless target

        transitions << transition(current, dfa.ec.fetch(byte), target)
        current = target
        encoding_state = advance_encoding(encoding_state, byte)
      end
      {
        state: name, input: Testing::Snapshot.encode(bytes), transitions: transitions,
        rule_bodies: rule_bodies.uniq
      }
    end

    def transition(from, byte_class, to)
      { from: from, byte_class: byte_class, to: to }
    end
  end
end
