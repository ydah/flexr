# frozen_string_literal: true

module Flexr
  module Runtime
    Location = Data.define(:filename, :byte_begin, :byte_end, :line_begin, :column_begin, :line_end, :column_end) do
      include Record

      def initialize(filename: nil, byte_begin: nil, byte_end: nil, line_begin: nil, column_begin: nil,
                     line_end: nil, column_end: nil, column_values: nil, eager_columns: false)
        @column_values = [column_begin || column_values&.first, column_end || column_values&.last].freeze
        filename = filename.dup.freeze if filename.is_a?(String)
        column_begin ||= @column_values&.first if eager_columns
        column_end ||= @column_values&.last if eager_columns
        super(filename: filename, byte_begin: byte_begin, byte_end: byte_end, line_begin: line_begin,
              column_begin: column_begin, line_end: line_end, column_end: column_end)
      end

      def column_begin
        @column_values.first
      end

      def column_end
        @column_values.last
      end

      def to_h(&block)
        values = super().merge(column_begin: column_begin, column_end: column_end)
        block ? values.to_h(&block) : values
      end

      def with(**changes)
        columns = @column_values.dup
        columns[0] = changes[:column_begin] if changes.key?(:column_begin)
        columns[1] = changes[:column_end] if changes.key?(:column_end)
        self.class.new(**deconstruct_keys(nil), **changes, column_values: columns)
      end

      def ==(other)
        other.instance_of?(self.class) && to_h == other.to_h
      end

      alias_method :eql?, :==

      def hash
        [self.class, to_h].hash
      end
    end
  end
end
