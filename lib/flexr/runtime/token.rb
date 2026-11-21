# frozen_string_literal: true

module Flexr
  module Runtime
    Token = Struct.new(:type, :value, :location, keyword_init: true)
    Deprecations.record_mutations(Token)
  end
end
