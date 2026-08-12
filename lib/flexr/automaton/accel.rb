# frozen_string_literal: true

module Flexr
  module Automaton
    Region = Struct.new(:state, :bytes, :regexp, :utf8_regexp, keyword_init: true)

    module Accel
      module_function

      def extract(dfa)
        dfa.transitions.each_index.filter_map do |state|
          bytes = Analysis.self_loop_set(dfa, state)
          next if bytes.empty?

          Region.new(
            state: state, bytes: bytes.freeze,
            regexp: regexp_for(bytes, binary: true),
            utf8_regexp: bytes.all? { |byte| byte < 128 } ? regexp_for(bytes, binary: false) : nil
          )
        end
      end

      def regexp_for(bytes, binary: true)
        source = bytes_to_source(bytes)
        options = binary ? ::Regexp::NOENCODING : 0
        ::Regexp.new("(?:[#{source}])+", options)
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
          lo == hi ? format("\\x%<byte>02X", byte: lo) : format("\\x%<lo>02X-\\x%<hi>02X", lo: lo, hi: hi)
        end.join
      end
    end
  end
end
