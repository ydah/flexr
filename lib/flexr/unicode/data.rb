# frozen_string_literal: true

module Flexr
  module Unicode
    module Data
      autoload :VERSION, File.expand_path("data/properties", __dir__)
      autoload :PROPERTIES, File.expand_path("data/properties", __dir__)
      autoload :CASE_FOLD, File.expand_path("data/case_folding", __dir__)
    end
  end
end
