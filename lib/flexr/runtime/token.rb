# frozen_string_literal: true

module Flexr
  module Runtime
    Token = Struct.new(:type, :value, :location, keyword_init: true)
  end
end
