# frozen_string_literal: true

require "minitest/autorun"
require_relative "calculator"

class CalculatorTest < Minitest::Test
  def test_adds_and_subtracts
    assert_equal 11, Calculator.evaluate("12 + 3 - 4")
    assert_equal(-5, Calculator.evaluate("2 - 4 - 3"))
  end

  def test_rejects_an_incomplete_expression
    assert_raises(ArgumentError) { Calculator.evaluate("12 +") }
  end
end
