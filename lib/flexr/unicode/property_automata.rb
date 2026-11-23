# frozen_string_literal: true

module Flexr
  module Unicode
    module PropertyAutomata
      PATH = File.expand_path("data/utf8_automata.rb", __dir__).freeze
      MAGIC = "flexr UTF-8 property automata v1\n".b.freeze
      Fragment = ::Data.define(:state_count, :accept, :edges)

      module_function

      def lookup(name, negate:, fold:)
        data, entries = artifact
        variants = entries[Property.canonical_name(name)]
        return unless variants

        offset, length = variants.fetch((negate ? 2 : 0) + (fold ? 1 : 0))
        fragments = (@fragments ||= {})
        fragments[offset] ||= begin
          state_count, accept, *edges = data.byteslice(offset, length).unpack("v*")
          Fragment.new(state_count, accept, edges.freeze)
        end
      end

      def artifact
        @artifact ||= begin
          require_relative "data/utf8_automata"
          bytes = Data::UTF8_AUTOMATA
          raise ArgumentError, "unknown property automata format" unless bytes.start_with?(MAGIC)

          size = bytes.byteslice(MAGIC.bytesize, 4).unpack1("V")
          start = MAGIC.bytesize + 4
          index = JSON.parse(bytes.byteslice(start, size))
          if index.fetch("unicode") == Unicode::VERSION
            [bytes.byteslice((start + size)..).freeze, index.fetch("properties")]
          else
            ["".b.freeze, {}.freeze]
          end
        rescue LoadError, JSON::ParserError, ArgumentError, KeyError, TypeError
          ["".b.freeze, {}.freeze]
        end
      end
      private_class_method :artifact
    end
  end
end
