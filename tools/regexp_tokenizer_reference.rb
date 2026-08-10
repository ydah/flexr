# frozen_string_literal: true

module FlexrVerification
  module RegexpTokenizerReference
    module_function

    class UnmatchedInputError < StandardError
      attr_reader :offset, :byte

      def initialize(offset:, byte:)
        @offset = offset
        @byte = byte
        super(format("reference tokenizer could not match byte at offset %<offset>d (0x%<byte>02x)",
                     offset: offset, byte: byte))
      end
    end

    RULES = [
      [/[ \t\r\n]+/, ->(_text) {}],
      [/\\p\{[A-Za-z_][A-Za-z0-9_]*\}/, ->(text) { [:PROPERTY, text.byteslice(3...-1)] }],
      [/\\./, ->(text) { [:ESCAPE, text] }],
      [/\[[^\]\n]*\]/, ->(text) { [:CHAR_CLASS, text] }],
      [/[?*+]|\{[0-9]+(?:,[0-9]*)?\}/, ->(text) { [:QUANTIFIER, text] }],
      [/\|/, ->(text) { [:ALTERNATION, text] }],
      [/\(/, ->(text) { [:GROUP_OPEN, text] }],
      [/\)/, ->(text) { [:GROUP_CLOSE, text] }],
      [/\^|\$/, ->(text) { [:ANCHOR, text] }],
      [/\./, ->(text) { [:DOT, text] }],
      [/[^\\\[\]().|?*+{}^$ \t\r\n]/, ->(text) { [:LITERAL, text] }]
    ].freeze
    BYTE_RULES = RULES.map do |pattern, action|
      [Regexp.new(pattern.source, pattern.options | ::Regexp::NOENCODING), action]
    end.freeze

    def tokens(input)
      source = input.b
      position = 0
      result = []
      while position < source.bytesize
        match = match_at(source, position)
        raise UnmatchedInputError.new(offset: position, byte: source.getbyte(position)) unless match

        matched_text, action = match
        text = input.byteslice(position, matched_text.bytesize)
        position += matched_text.bytesize
        token = action.call(text)
        result << token if token
      end
      result
    end

    def match_at(source, position)
      BYTE_RULES.each do |pattern, action|
        candidate = pattern.match(source, position)
        return [candidate[0], action] if candidate&.begin(0) == position
      end
      nil
    end
  end
end
