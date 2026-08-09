# frozen_string_literal: true

module Flexr
  module Runtime
    Location = Struct.new(
      :filename, :byte_begin, :byte_end, :line_begin, :column_begin, :line_end, :column_end,
      keyword_init: true
    )
  end
end
