# frozen_string_literal: true

require_relative "../flexr" unless defined?(Flexr::Lexer)

module Flexr
  module Testing
    autoload :Languages, File.expand_path("testing/languages", __dir__)

    module Snapshot
      module_function

      def render(tokens)
        "#{JSON.pretty_generate(encode(tokens))}\n"
      end

      def expected(path, actual, update:)
        File.binwrite(path, actual) if update
        File.binread(path).force_encoding(Encoding::UTF_8)
      end

      def encode(value)
        case value
        when NilClass, TrueClass, FalseClass, Integer
          value
        when Float
          raise ArgumentError, "unsupported snapshot value: non-finite Float" unless value.finite?

          value
        when String
          utf8 = value.dup.force_encoding(Encoding::UTF_8)
          utf8.valid_encoding? ? utf8 : { "bytes" => value.bytes }
        when Symbol
          { "symbol" => value.to_s }
        when Array
          value.map { |item| encode(item) }
        when Hash
          pairs = value.map { |key, item| [encode(key), encode(item)] }
          { "hash" => pairs.sort_by { |key, _item| JSON.generate(key) } }
        when Runtime::Token
          data = value.to_h
          data = data.merge(channel: value.channel, leading_trivia: value.leading_trivia) if
            value.channel != :default || !value.leading_trivia.empty?
          { "token" => encode(data) }
        when Runtime::Location
          { "location" => encode(value.members.to_h { |name| [name, value.public_send(name)] }) }
        else
          raise ArgumentError, "unsupported snapshot value: #{value.class}; convert it to built-in values first"
        end
      end
    end
  end
end
