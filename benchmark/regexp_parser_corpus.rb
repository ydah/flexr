# frozen_string_literal: true

# Loaded by upstream RSpec before spec_helper loads regexp_parser.
require "json"

gem "regexp_parser", ENV.fetch("FLEXR_REGEXP_PARSER_VERSION")
module RegexpParserCorpus
  class << self
    attr_reader :requests, :calls

    def record(input, options)
      @calls += 1
      source, flags = input.is_a?(Regexp) ? [input.source, input.options] : [input, nil]
      @requests[[source.unpack1("H*"), source.encoding.name, flags, options]] = true
    end
  end

  @requests = {}
  @calls = 0

  module Observer
    def scan(input, options: nil, **, &)
      RegexpParserCorpus.record(input, options) if !defined?(Ractor) || Ractor.current == Ractor.main
      super
    end
  end
end

RSpec.configure do |config|
  config.before(:suite) { Regexp::Scanner.prepend(RegexpParserCorpus::Observer) }
  config.after(:suite) do
    data = [RegexpParserCorpus.calls, RegexpParserCorpus.requests.keys]
    File.write(ENV.fetch("FLEXR_REGEXP_PARSER_CORPUS"), JSON.generate(data))
  end
end
