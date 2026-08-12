# frozen_string_literal: true

module Flexr
  module ActionResolver
    module_function

    def resolve(skip:, emit:, block:, default:)
      return :skip if skip
      return [:emit, emit.to_sym] if emit
      return block if block

      default
    end
  end
end
