# frozen_string_literal: true

module Flexr
  module Automaton
    class ByteClassSet
      def initialize
        @boundaries = Array.new(257, false)
        @boundaries[0] = true
      end

      def add_range(lo, hi)
        raise ArgumentError, "invalid byte range" unless lo.between?(0, 255) && hi.between?(lo, 255)

        @boundaries[lo] = true
        @boundaries[hi + 1] = true if hi < 255
      end

      def build
        ec = Array.new(256)
        class_id = -1
        256.times do |byte|
          class_id += 1 if @boundaries[byte]
          ec[byte] = class_id
        end
        [ec.freeze, class_id + 1]
      end
    end
  end
end
