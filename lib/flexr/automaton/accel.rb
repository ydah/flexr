# frozen_string_literal: true

module Flexr
  module Automaton
    Region = Struct.new(:state, :bytes, :regexp, keyword_init: true)

    module Accel
      module_function

      def extract(dfa)
        dfa.transitions.each_index.filter_map do |state|
          bytes = Analysis.self_loop_set(dfa, state)
          next if bytes.empty?

          Region.new(state: state, bytes: bytes.freeze, regexp: regexp_for(bytes))
        end
      end

      def regexp_for(bytes)
        source = bytes_to_source(bytes)
        ::Regexp.new("(?:[#{source}])+", ::Regexp::NOENCODING)
      end

      def bytes_to_source(bytes)
        ranges = []
        bytes.sort.each do |byte|
          if ranges.empty? || byte > ranges.last.last + 1
            ranges << [byte, byte]
          else
            ranges.last[1] = byte
          end
        end
        ranges.map do |lo, hi|
          lo == hi ? "\\x%02X" % lo : "\\x%02X-\\x%02X" % [lo, hi]
        end.join
      end
    end
  end
end
