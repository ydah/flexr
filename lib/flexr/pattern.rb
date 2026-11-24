# frozen_string_literal: true

module Flexr
  class Pattern
    attr_reader :operation, :operands, :name

    def self.build(*values, regexp: nil)
      unless regexp.nil?
        invalid! unless values.empty? && regexp.is_a?(String)

        return new(:regexp, [regexp])
      end

      operands = values.flatten.map do |value|
        case value
        when Pattern then value
        when String, ::Regexp then new(:literal, [value])
        else invalid!
        end
      end
      invalid! if operands.empty?
      operands.one? ? operands.first : new(:|, operands)
    end

    def self.upto(value)
      new(:upto, [build(value)])
    end

    def self.__flexr_restore(operation, operands, name)
      new(operation, operands, name)
    end

    def self.invalid!
      diagnostic = Diagnostics.error("FLEXR-E018", "pattern requires Regexp, String, or Pattern values")
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    private_class_method :new, :invalid!

    def initialize(operation, operands, name = nil)
      @operation = operation
      @operands = operands.map do |value|
        case value
        when String then String.new(value).freeze
        when ::Regexp then ::Regexp.new(value).freeze
        else value
        end
      end.freeze
      @name = String.new(name).freeze if name
      freeze
    end

    def |(other) = binary(:|, other)
    def +(other) = binary(:+, other)
    def &(other) = binary(:&, other)
    def -(other) = binary(:-, other)
    def ! = Pattern.__flexr_restore(:!, [self], nil)

    def __flexr_named(name)
      Pattern.__flexr_restore(@operation, @operands, name)
    end

    def inspect
      return @name if @name

      case @operation
      when :literal then @operands.first.inspect
      when :regexp then "pattern(regexp: #{@operands.first.inspect})"
      when :! then "!#{@operands.first.inspect}"
      when :upto then "upto(#{@operands.first.inspect})"
      else "(#{@operands.map(&:inspect).join(" #{@operation} ")})"
      end
    end

    alias to_s inspect

    private

    def binary(operation, other)
      Pattern.__flexr_restore(operation, [self, Pattern.build(other)], nil)
    end
  end
end
