# frozen_string_literal: true

module FlexrVerification
  module RegexpTokenizerReference
    module_function

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

    def tokens(input)
      source = input.dup
      position = 0
      result = []
      while position < source.bytesize
        match = RULES.filter_map do |pattern, action|
          candidate = pattern.match(source, position)
          next unless candidate&.begin(0) == position

          [candidate[0], action]
        end.first
        raise "reference tokenizer stalled at byte #{position}" unless match

        text, action = match
        position += text.bytesize
        token = action.call(text)
        result << token if token
      end
      result
    end
  end
end
