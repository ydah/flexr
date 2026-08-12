# frozen_string_literal: true

require_relative "runtime" unless defined?(Flexr::Lexer)
require_relative "codegen/base"
require_relative "codegen/table"
require_relative "codegen/direct"
require_relative "codegen/firstmatch"
require_relative "codegen/table_packer"
