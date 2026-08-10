# frozen_string_literal: true

module Flexr
  module Runtime
    Location = Struct.new(
      :filename, :byte_begin, :byte_end, :line_begin, :column_begin, :line_end, :column_end,
      keyword_init: true
    ) do
      def initialize(**values)
        @column_values = values.delete(:column_values)
        eager_columns = values.delete(:eager_columns)
        super(**values) # rubocop:disable Style/SuperArguments
        self.column_begin = @column_values.first if eager_columns && @column_values
        self.column_end = @column_values.last if eager_columns && @column_values
      end

      def column_begin
        self[:column_begin] ||= @column_values&.first
      end

      def column_end
        self[:column_end] ||= @column_values&.last
      end
    end
  end
end
