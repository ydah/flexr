# frozen_string_literal: true

module Flexr
  module Runtime
    INPUT_STACK_FIELDS = (CHECKPOINT_FIELDS + %i[
      @buffer @filename @string_input @stable_input_end @valid_utf8_input @simple_location_input
      @token_limit_required @__flexr_input_id
    ]).freeze
    private_constant :INPUT_STACK_FIELDS

    def push_input(input, filename: nil)
      buffer = Buffer.new(input, chunk_size: @buffer.chunk_size, max_buffer_size: @buffer.max_buffer_size,
                          retain_input: @retain_input, freeze_input: @freeze_input, filename: filename)
      input = buffer.source if input.is_a?(String)
      (@__flexr_pending_inputs ||= []) << [buffer, input, filename]
      nil
    end

    private

    def activate_pending_inputs
      raise ArgumentError, "a delegated lexer scans only the captured input" if @__flexr_delegation_depth

      pending = @__flexr_pending_inputs
      @__flexr_pending_inputs = nil
      pending.each do |buffer, input, filename|
        (@__flexr_input_frames ||= []) << INPUT_STACK_FIELDS.map { |field| instance_variable_get(field) }
        @buffer = buffer
        @filename = filename
        @__flexr_input_id = Object.new.freeze
        reset_input_cursor(input, self.class.__flexr_config.encoding)
      end
      clear_input_scanners
    end

    def defer_input_resume? = false

    def resume_suspended_input
      frame = @__flexr_input_frames.pop
      @__flexr_input_frames = nil if @__flexr_input_frames.empty?
      INPUT_STACK_FIELDS.each_with_index { |field, index| instance_variable_set(field, frame.fetch(index)) }
      clear_input_scanners
    end

    def clear_input_scanners
      @interpreter = @__flexr_whole_scanner = @__flexr_generated_accel_scanner = nil
    end
  end
end
