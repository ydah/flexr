# frozen_string_literal: true

module Flexr
  class LegacyRubyMatch
    def self.wrap(match)
      match.is_a?(::MatchData) ? new(match) : match
    end

    def initialize(match)
      @match = match
    end

    def named_captures(symbolize_names: false)
      captures = @match.named_captures
      symbolize_names ? captures.transform_keys(&:to_sym) : captures
    end

    def byteoffset(group)
      @match.offset(group).map { |offset| offset && @match.string[0, offset].bytesize }
    end
  end
end
