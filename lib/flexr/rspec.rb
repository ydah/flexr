# frozen_string_literal: true

require "rspec/expectations"
require_relative "testing"

RSpec::Matchers.define :tokenize do |input, **options|
  chain :as do |tokens|
    @expected = tokens
    @comparison = :tokens
  end

  chain :matching_snapshot do |path, snapshot_options = {}|
    @snapshot_path = path
    @update_snapshot = snapshot_options.fetch(:update, false)
    @comparison = :snapshot
  end

  match do |lexer|
    raise ArgumentError, "use .as(tokens) or .matching_snapshot(path)" unless @comparison

    @actual = lexer.new(input, **options).tokens
    if @comparison == :snapshot
      @actual = Flexr::Testing::Snapshot.render(@actual)
      begin
        @expected = Flexr::Testing::Snapshot.expected(@snapshot_path, @actual, update: @update_snapshot)
      rescue Errno::ENOENT
        @missing_snapshot = true
        next false
      end
    end
    @actual == @expected
  end

  failure_message do
    if @missing_snapshot
      "missing token snapshot #{@snapshot_path}; create it with update: true"
    elsif @comparison == :snapshot
      "expected tokens to match snapshot #{@snapshot_path}"
    else
      "expected tokens #{@expected.inspect}, got #{@actual.inspect}"
    end
  end

  failure_message_when_negated do
    "expected tokens to differ from #{@comparison == :snapshot ? @snapshot_path : @expected.inspect}"
  end

  diffable
  define_method(:expected) { @expected }
  define_method(:actual) { @actual }
end

RSpec::Matchers.define :have_disjoint_tokens do |first, second|
  chain(:in_state) { |state| @state = state }

  define_method(:verify) do |lexer|
    state = instance_variable_defined?(:@state) ? @state : :initial
    @assertion = Flexr::Testing::Languages.disjoint_tokens(lexer, first, second, state: state)
  end

  match { |lexer| verify(lexer).status == :equal }
  match_when_negated { |lexer| verify(lexer).status == :different }
  failure_message { @assertion.failure_message }
  failure_message_when_negated { @assertion.failure_message(negated: true) }
end

RSpec::Matchers.define :include_language do |subset, encoding: Encoding::UTF_8, unicode: false|
  define_method(:verify) do |superset|
    @assertion = Flexr::Testing::Languages.include_language(superset, subset, encoding: encoding, unicode: unicode)
  end

  match { |superset| verify(superset).status == :equal }
  match_when_negated { |superset| verify(superset).status == :different }
  failure_message { @assertion.failure_message }
  failure_message_when_negated { @assertion.failure_message(negated: true) }
end

RSpec::Matchers.define :tokenize_like do |expected|
  chain(:in_state) { |state| @state = state }

  define_method(:verify) do |actual|
    state = instance_variable_defined?(:@state) ? @state : :initial
    @assertion = Flexr::Testing::Languages.tokenize_like(actual, expected, state: state)
  end

  match { |actual| verify(actual).status == :equal }
  match_when_negated { |actual| verify(actual).status == :different }
  failure_message { @assertion.failure_message }
  failure_message_when_negated { @assertion.failure_message(negated: true) }
end
