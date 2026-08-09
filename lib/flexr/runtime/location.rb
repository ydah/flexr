# frozen_string_literal: true

module Flexr
  module Runtime
    Location = Struct.new(
      :filename, :byte_begin, :byte_end, :line_begin, :column_begin, :line_end, :column_end,
      keyword_init: true
    ) do
      def initialize(**values)
        @column_resolver = values.delete(:column_resolver)
        eager_columns = values.delete(:eager_columns)
        # Struct's generated initializer does not accept the private resolver
        # keywords, so pass only the public fields onward.
        super(**values) # rubocop:disable Style/SuperArguments
        self.column_begin = @column_resolver.call(byte_begin) if eager_columns && @column_resolver
        self.column_end = @column_resolver.call(byte_end) if eager_columns && @column_resolver
      end

      def column_begin
        self[:column_begin] ||= @column_resolver&.call(byte_begin)
      end

      def column_end
        self[:column_end] ||= @column_resolver&.call(byte_end)
      end
    end
  end
end
