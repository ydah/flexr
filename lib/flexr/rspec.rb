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
