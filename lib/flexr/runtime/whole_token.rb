# frozen_string_literal: true

module Flexr
  module Runtime
    def __flexr_whole_token_match(plans, position)
      return unless plans && defined?(::StringScanner) && !scan_steps_guarded? && !token_limit_required?

      source = @buffer.stable_source
      return unless source&.frozen?

      byte = source.getbyte(position)
      plan = plans[byte] if byte
      return unless plan

      scanner = @__flexr_whole_scanner ||= ::StringScanner.new(source)
      scanner.pos = position
      length = scanner.skip(plan.regexp)
      return unless length

      match = @__flexr_whole_match ||= Runtime::Match.new
      match.rule = self.class.__flexr_rules.fetch(plan.rule_index)
      match.start_pos = position
      match.end_pos = position + length
      match.total_end_pos = match.end_pos
      match
    rescue ArgumentError
      nil
    end
  end
end
