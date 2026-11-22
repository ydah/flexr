# frozen_string_literal: true

require "json"
require_relative "../lib/flexr"

module DFAStretch
  module_function

  def check(actual, expected)
    raise "expected #{expected.inspect}, got #{actual.inspect}" unless actual == expected

    actual
  end

  def initial_dfa(lexer)
    lexer.compile!.machines.fetch(:initial).dfa
  end

  def acceptance_history(dfa, input)
    raise ArgumentError, "this probe requires ASCII input" unless input.ascii_only?

    state = dfa.start
    history = []
    input.each_byte.with_index(1) do |byte, ending|
      state = dfa.transition(state, byte)
      break unless state

      dfa.accepts.fetch(state).each do |acceptance|
        raise ArgumentError, "this probe requires unanchored patterns" if acceptance.bol_only || acceptance.end_anchor

        history << [ending, acceptance.rule_index, acceptance.pattern_index]
      end
    end
    history
  end

  def selection_probe
    effects = []
    grammar = Class.new(Flexr::Lexer) do
      rule("a", emit: :SINGLE)
      rule(/a+/, emits: :RUN) do
        effects << [:run, text]
        push :inside
        emit :RUN
      end
      rule("aa", emit: :PAIR, priority: 10)
      state(:inside) { rule("!", emit: :BANG) }
    end
    input = "aaa!"
    dfa = initial_dfa(grammar)
    names = %i[SINGLE RUN PAIR]
    history = acceptance_history(dfa, input).map { |ending, rule, _| [names.fetch(rule), ending] }
    check(history, [[:SINGLE, 1], [:RUN, 1], [:PAIR, 2], [:RUN, 2], [:RUN, 3]])
    reject_order = history.chunk(&:last).to_a.reverse.flat_map(&:last)
    check(reject_order, [[:RUN, 3], [:PAIR, 2], [:RUN, 2], [:SINGLE, 1], [:RUN, 1]])

    scanner = grammar.new(input)
    checkpoint = scanner.checkpoint
    longest = check(scanner.next_token, [:RUN, "aaa"])
    state_after = check([scanner.state, scanner.byte_pos], [:inside, 3])
    scanner.restore(checkpoint)
    restored = check([scanner.state, scanner.byte_pos], [:initial, 0])
    alternative = check(scanner.next_token(expect: [:PAIR]), [:PAIR, "aa"])
    check(effects, [[:run, "aaa"]])
    counts = [1, 8, 64, 1024].to_h { |size| [size, acceptance_history(dfa, "a" * size).size] }
    check(counts.values, [2, 10, 66, 1026])

    trailing = Class.new(Flexr::Lexer) do
      rule("a", followed_by: "bcd", emit: :CONTEXT)
      rule("ab", emit: :PAIR)
    end
    body_ends = check(acceptance_history(initial_dfa(trailing), "abcd"), [[1, 0, 0], [2, 1, 0]])
    ranked = check(trailing.recognizer.match("abcd", 0), [:CONTEXT, 1])

    firstmatch = Class.new(Flexr::Lexer) do
      backend :firstmatch
      rule(/a+/, emit: :RUN)
      rule("a", emit: :SINGLE)
    end
    firstmatch_shortest = check(acceptance_history(initial_dfa(firstmatch), input).first, [1, 0, 0])
    native_token = check(firstmatch.new(input).next_token, [:RUN, "aaa"])
    {
      shortest: history.first, longest: reject_order.first, actual_token: longest,
      firstmatch: { shortest: [:RUN, firstmatch_shortest.first], native_token: native_token },
      reject_order: reject_order, history_counts: counts,
      position_after_action: state_after, restored_position: restored, filtered_token: alternative, surviving_effects: effects,
      trailing_context: { body_ends: body_ends.map(&:first), ranking_ends: [4, 2], current_match: ranked }
    }
  end

  def dfa_signature(dfa)
    [dfa.start, dfa.accepts, dfa.states.times.map { |state| 256.times.map { |byte| dfa.transition(state, byte) } }]
  end

  def bounded_capture_ranges(input, widths, lanes)
    states = widths.map { |width| lanes.fetch(width).start }
    split = finish = nil
    input.each_byte.with_index(1) do |byte, ending|
      states.map!.with_index do |state, index|
        state && lanes.fetch(widths.fetch(index)).transition(state, byte)
      end
      break if states.none?

      winning_lane = states.each_index.find do |index|
        state = states.fetch(index)
        state && !lanes.fetch(widths.fetch(index)).accepts.fetch(state).empty?
      end
      next unless winning_lane

      split = widths.fetch(winning_lane)
      finish = ending
    end
    [0...split, split...finish] if finish
  end

  def captures_probe
    variants = { /(?<head>a|aa)(?<tail>a+)/ => [1, 2], /(?<head>aa|a)(?<tail>a+)/ => [2, 1] }
    grammars = variants.keys.map do |pattern|
      Class.new(Flexr::Lexer) do
        rule(pattern) { emit :CAPTURE, captures.values_at(:head, :tail) }
      end
    end
    dfa, other = grammars.map { |grammar| initial_dfa(grammar) }
    check(dfa_signature(dfa), dfa_signature(other))

    lanes = { 1 => Flexr.compile_pattern(/aa+/), 2 => Flexr.compile_pattern(/aaa+/) }
    inputs = (2..64).map { |size| "#{'a' * size}!" }
    examples = grammars.zip(variants.values).map do |grammar, widths|
      inputs.each do |input|
        ranges = bounded_capture_ranges(input, widths, lanes)
        check(ranges.last.end, grammar.recognizer.match(input, 0).last)
        check(ranges.map { |range| input.byteslice(range) }, grammar.new(input).next_token.last)
      end
      ranges = bounded_capture_ranges("aaa!", widths, lanes)
      { order: widths, ranges: ranges.map { |range| [range.begin, range.end] },
        replay: grammar.new("aaa!").next_token.last }
    end
    ["", "a", "!aaa"].each do |input|
      grammars.zip(variants.values).each do |grammar, widths|
        check(bounded_capture_ranges(input, widths, lanes), nil)
        check(grammar.recognizer.match(input, 0), nil)
      end
    end
    check(examples.map { |example| example.fetch(:replay) }, [%w[a aa], %w[aa a]])
    { identical_dfa: true, states: dfa.states, examples: examples, compared: (inputs.size + 3) * variants.size }
  end
end

puts JSON.pretty_generate(ruby: RUBY_DESCRIPTION, selection: DFAStretch.selection_probe, captures: DFAStretch.captures_probe) if $PROGRAM_NAME == __FILE__
