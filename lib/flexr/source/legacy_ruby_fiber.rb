# frozen_string_literal: true

module Flexr
  module LegacyRubyFiber
    def self.start(&)
      return ::Fiber.new(&) unless ::Fiber.respond_to?(:scheduler)

      ::Fiber.new(blocking: true, &)
    end
  end
end
