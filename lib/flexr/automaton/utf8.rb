# frozen_string_literal: true

module Flexr
  module Automaton
    module UTF8
      module_function

      def rows(encoding)
        return [Array.new(256, 0)] if encoding == Encoding::BINARY
        return unless encoding == Encoding::UTF_8

        rows = Array.new(8) { Array.new(256) }
        rows[0].fill(0, 0x00..0x7f)
        rows[0].fill(1, 0xc2..0xdf)
        rows[0].fill(2, 0xe1..0xef)
        rows[0].fill(3, 0xf1..0xf3)
        rows[0][0xe0] = 4
        rows[0][0xed] = 5
        rows[0][0xf0] = 6
        rows[0][0xf4] = 7
        (1..3).each { |remaining| rows[remaining].fill(remaining - 1, 0x80..0xbf) }
        rows[4].fill(1, 0xa0..0xbf)
        rows[5].fill(1, 0x80..0x9f)
        rows[6].fill(2, 0x90..0xbf)
        rows[7].fill(2, 0x80..0x8f)
        rows
      end
    end
  end
end
