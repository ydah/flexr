# frozen_string_literal: true

module Flexr
  module Keywords
    module_function

    def add!(options, declared_tokens, words, among:, location: nil)
      error!("keywords requires a base token Symbol", location: location) unless among.is_a?(Symbol)
      error!("keywords requires a nonempty Array or Hash", location: location) unless (words.is_a?(Array) || words.is_a?(Hash)) && !words.empty?

      tables = options.fetch(:keyword_tables, {})
      table = tables.fetch(among, {}).dup
      entries = words.is_a?(Hash) ? words : words.map { |word| [word, nil] }
      types = entries.map do |word, type|
        error!("keyword #{word.inspect} must be a nonempty String", location: location) unless word.is_a?(String) && !word.empty?

        normalized = spelling(word).dup.freeze
        error!("keyword #{word.b.inspect} must have valid UTF-8 spelling", location: location) unless normalized.valid_encoding?
        type = normalized.upcase.to_sym if words.is_a?(Array)
        error!("keyword #{word.inspect} requires a token Symbol", location: location) unless type.is_a?(Symbol)
        error!("keyword #{word.inspect} has conflicting types for #{among.inspect}", location: location) if table.key?(normalized) && table.fetch(normalized).first != type

        table[normalized] ||= [type, location&.freeze].freeze
        type
      end
      options[:keyword_tables] = tables.merge(among => table.freeze).freeze
      declared_tokens.push(among, *types).uniq!
    end

    def spelling(lexeme)
      lexeme.encoding == ::Encoding::UTF_8 ? lexeme : lexeme.dup.force_encoding(::Encoding::UTF_8)
    end

    def error!(message, location: nil, help: nil, note: nil)
      diagnostic = Diagnostics.error("FLEXR-E028", message, location: location, help: help, note: note)
      raise CompileError.new(message, diagnostic: diagnostic)
    end

    module Emission
      private

      def execute(rule)
        return super unless rule.emit?

        type = rule.action[1]
        table = self.class.__flexr_config.options[:keyword_tables]&.[](type)
        return super unless table

        value = text
        lexeme = @text_start == @match_start ? value : @buffer.byteslice(@match_start...@match_end)
        entry = table[Keywords.spelling(lexeme)]
        emit(entry ? entry.first : type, value)
      end
    end
  end

  module DSL
    def keywords(words, among:)
      __flexr_mutate! do
        Keywords.add!(@__flexr_config.options, @__flexr_config.declared_tokens, words, among: among)
      end
      nil
    end
  end
end
