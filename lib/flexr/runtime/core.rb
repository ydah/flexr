# frozen_string_literal: true

module Flexr
  module Runtime
    def initialize(input, filename: nil, error_mode: :raise, max_token_size: 16 * 1024 * 1024,
                   max_lookahead_size: nil, max_buffer_size: 64 * 1024 * 1024,
                   max_state_stack: 1024, max_steps: nil, cancellation: nil, retain_input: true,
                   chunk_size: Runtime::Buffer::DEFAULT_CHUNK_SIZE)
      raise ArgumentError, "max_token_size must be non-negative" if max_token_size.to_i.negative?
      raise ArgumentError, "max_lookahead_size must be non-negative" if max_lookahead_size&.to_i&.negative?
      raise ArgumentError, "max_buffer_size must be non-negative" if max_buffer_size.to_i.negative?
      raise ArgumentError, "max_state_stack must be non-negative" if max_state_stack.to_i.negative?
      raise ArgumentError, "max_steps must be non-negative" if max_steps&.to_i&.negative?
      raise ArgumentError, "cancellation must respond to call" if cancellation && !cancellation.respond_to?(:call)

      self.class.compile!
      config = self.class.__flexr_config
      @buffer = Runtime::Buffer.new(
        input, chunk_size: chunk_size, max_buffer_size: max_buffer_size,
        retain_input: retain_input, filename: filename
      )
      @string_input = input.is_a?(String)
      @stable_input_end = input.bytesize if @string_input && input.frozen?
      @valid_utf8_input = @string_input && input.frozen? && (config.encoding != Encoding::UTF_8 || begin
        bytes = input.encoding == Encoding::UTF_8 ? input : input.dup.force_encoding(Encoding::UTF_8)
        bytes.valid_encoding?
      end)
      @simple_location_input = @string_input && input.frozen? && retain_input &&
        input.ascii_only? && !input.include?("\n")
      @retain_input = retain_input
      @filename = filename
      @error_mode = error_mode
      @token_kind = config.token_kind
      @accel_mode = config.options.fetch(:accel, :auto)
      @max_token_size = max_token_size.to_i
      @token_limit_required = !@string_input || !input.frozen? || input.bytesize > @max_token_size
      @max_lookahead_size = (max_lookahead_size || max_token_size).to_i
      @max_state_stack = max_state_stack.to_i
      @max_steps = max_steps&.to_i
      @cancellation = cancellation
      @steps = 0
      @position = 0
      @line = 1
      @column = 1
      @state = :initial
      @state_stack = []
      @pending = nil
      @matched = nil
      @match_start = 0
      @match_end = 0
      @text_start = 0
      @text_line = 1
      @text_column = 1
      @bol = true
      @more_start = nil
      @more_line = nil
      @more_column = nil
      @more_requested = false
      @non_progress_signatures = {}
      @active_rule = nil
      @eof_fired_states = {}
      @on_error = nil
      @halted = false
      @interpreter = nil
      @generated_scanner = generated_runtime? && respond_to?(:scan_one, true)
    end

    attr_reader :filename, :error_mode, :buffer, :max_token_size, :max_lookahead_size, :steps

    attr_writer :on_error

    def input
      @buffer.source
    end

    def next_token
      return nil if @halted

      loop do
        return nil if @halted
        consume_step! if scan_steps_guarded?

        if eof? && @pending.nil?
          eof_action = self.class.__flexr_spec.eof_rules[@state]
          if eof_action && !@eof_fired_states[@state]
            @eof_fired_states[@state] = true
            @match_start = @position
            @match_end = @position
            @text_start = @position
            @text_line = @line
            @text_column = @column
            @matched = nil
            instance_exec(&eof_action)
            token = @pending
            @pending = nil
            return token if token
            next
          end
          return nil
        end

        @active_rule = nil
        match = if @generated_scanner
          scan_one
        else
          (@interpreter ||= Runtime::Interpreter.new(self)).scan
        end
        unless match
          unless eof?
            token = handle_unmatched_byte
            next unless token

            return token
          end
          return nil
        end
        @match_start = match.start_pos
        @match_end = match.end_pos
        scan_state = @state
        if @more_start
          @text_start = @more_start
          @text_line = @more_line
          @text_column = @more_column
        else
          @text_start = @match_start
          @text_line = @line
          @text_column = @column
        end
        @matched = nil
        @more_requested = false
        @position = match.end_pos
        empty_match = match.end_pos == match.start_pos
        @active_rule = match.rule
        execute(match.rule)
        finalize_more
        ensure_progress!(match, scan_state, empty_match: empty_match) unless
          @position > match.start_pos && @non_progress_signatures.empty?
        ensure_token_size! if @token_limit_required
        update_position
        discard_consumed_input! unless @retain_input
        token = @pending
        @pending = nil
        return token if token
      end
    end

    def each_token
      return enum_for(__method__) unless block_given?

      loop do
        token = next_token
        break unless token

        if @token_kind == :yield
          yield(*token)
        else
          yield token
        end
      end
      self
    end

    def tokens
      result = []
      while (token = next_token)
        result << token
      end
      result
    end

    def racc_next_token
      token = next_token
      token ? [token[0], token[1]] : [false, "$end"]
    end

    def text
      return @matched if @matched

      @matched = @buffer.byteslice(@text_start...@match_end)
    end

    def text_bytesize
      @match_end - @text_start
    end

    def byte_pos
      @position
    end

    def more_text_start
      @more_start
    end

    def defer_token_size_check!(size, rule: nil)
      return if size <= @max_token_size

      raise Runtime::TokenTooLargeError.new(
        filename: @filename, byte_pos: @more_start || @position, line: @line,
        rule: rule_index(rule || @active_rule)
      )
    end

    def ensure_lookahead_size!(size, rule: nil)
      return if size <= @max_lookahead_size

      raise Runtime::LookaheadTooLargeError.new(
        filename: @filename, byte_pos: @position, line: @line,
        rule: rule_index(rule || @active_rule)
      )
    end

    def consume_step!(count = 1)
      return unless scan_steps_guarded?

      @steps += count
      if @max_steps && @steps > @max_steps
        raise Runtime::StepLimitError.new(
          filename: @filename, byte_pos: @position, line: @line, rule: rule_index(@active_rule)
        )
      end
      return unless cancelled?

      raise Runtime::CancelledError.new(
        filename: @filename, byte_pos: @position, line: @line, rule: rule_index(@active_rule)
      )
    end

    def scan_steps_guarded?
      !@max_steps.nil? || !@cancellation.nil?
    end

    def token_limit_required?
      @token_limit_required
    end

    def utf8_input?
      self.class.__flexr_config.encoding == Encoding::UTF_8
    end

    def valid_utf8_at?(position)
      @valid_utf8_input || !utf8_input? || @buffer.valid_utf8_at?(position)
    end

    def utf8_boundary?(position)
      !utf8_input? || @buffer.utf8_boundary?(position)
    end

    def lineno
      @line
    end

    alias line lineno

    def state
      @state
    end

    def beginning_of_line?
      @bol
    end

    def binary_input
      source = @buffer.source
      source.encoding == ::Encoding::BINARY ? source : source.b
    end

    def emit(type, value = text)
      @pending = case @token_kind
      when :struct
        Runtime::Token.new(type: type, value: value, location: last_location)
      else
        [type, value]
      end
    end

    def skip
      @pending = nil
    end

    def error!(message)
      error = LexError.new(message, filename: @filename, byte_pos: @match_start, line: @text_line, text: text)
      if @on_error
        action = @on_error.call(error)
        return @pending = nil if action == :skip
        raise error if action == :raise
        if action == :halt
          @halted = true
          return @pending = nil
        end
        return emit(:error, text) if action == :token

        raise Runtime::InvalidRecoveryActionError.new(
          action: action, filename: @filename, byte_pos: @match_start, line: @text_line,
          text: text, rule: rule_index(@active_rule)
        )
      end
      case @error_mode
      when :token
        emit(:error, text)
      when :panic
        @pending = nil
      else
        raise error
      end
    end

    def echo
      emit(nil, text)
    end

    def reject
      diagnostic = Diagnostics.error(
        "FLEXR-E013", "reject is not supported by flexr",
        help: "use a state transition and less(n) to express the fallback"
      )
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def push(name)
      ensure_state!(name)
      if @state_stack.length >= @max_state_stack
        raise Runtime::StateStackOverflowError.new(
          "state stack exceeds max_state_stack (#{@max_state_stack})",
          filename: @filename, byte_pos: @position, line: @line, text: text,
          rule: rule_index(@active_rule)
        )
      end

      @state_stack << @state
      @state = name.to_sym
    end

    alias push_state push

    def pop
      @state = @state_stack.pop || :initial
    end

    alias pop_state pop

    def begin_state(name)
      ensure_state!(name)
      @state = name.to_sym
    end

    alias state= begin_state

    def less(count)
      matched_bytes = @match_end - @match_start
      raise ArgumentError, "less must not exceed matched bytes" if count.negative? || count > matched_bytes

      new_position = @match_start + count
      raise ArgumentError, "less must end at a UTF-8 codepoint boundary" if
        utf8_input? && !@buffer.utf8_boundary?(new_position)

      @position = new_position
      @match_end = @position
      @matched = nil
    end

    def more
      @more_requested = true
    end

    def last_location
      line_begin = @text_line || @line
      column_begin = @text_column || @column
      line_end, column_end = location_after(
        @text_start, @match_end, line: line_begin, column: column_begin
      )
      Runtime::Location.new(
        filename: @filename, byte_begin: @text_start, byte_end: @match_end,
        line_begin: line_begin, line_end: line_end,
        column_values: [column_begin, column_end],
        eager_columns: self.class.__flexr_config.options[:eager_columns] == true
      )
    end

    private

    def execute(rule)
      return __flexr_generated_execute(rule) if generated_runtime? && respond_to?(:__flexr_generated_execute, true)

      case rule.action
      when :skip
        nil
      when Array
        emit(rule.action[1], text)
      else
        instance_exec(&rule.action)
      end
    end

    def finalize_more
      if @more_requested
        @more_start = @text_start
        @more_line = @text_line
        @more_column = @text_column
      else
        @more_start = nil
        @more_line = nil
        @more_column = nil
      end
      @more_requested = false
    end

    def generated_runtime?
      self.class.respond_to?(:__flexr_generated?) && self.class.__flexr_generated?
    end

    def ensure_token_size!
      return unless @token_limit_required

      actual_size = @match_end - @text_start
      defer_token_size_check!(actual_size, rule: @active_rule)
    end

    def force_empty_match_progress!
      return if eof?

      length = utf8_input? ? @buffer.utf8_character_length(@position) : 1
      ending = @position + length
      advance_location!(@position, ending)
      @position = ending
      @bol = @buffer.getbyte(@position - 1) == 0x0a
    end

    def update_position
      if @simple_location_input
        @column += @match_end - @match_start
        @bol = @match_end.zero?
        return
      end

      advance_location!(@match_start, @match_end)
      @bol = @match_end.zero? || @buffer.getbyte(@match_end - 1) == 0x0a
    end

    def handle_unmatched_byte
      bad = @buffer.byteslice(@position, 1)
      @match_start = @position
      @match_end = @position + 1
      @text_start = @match_start
      @text_line = @line
      @text_column = @column
      @position += 1
      @non_progress_signatures.clear
      advance_location!(@match_start, @match_end)
      @bol = bad.to_s.b == "\n"
      error!("unexpected byte #{bad.inspect}")
      token = @pending
      @pending = nil
      discard_consumed_input! unless @retain_input
      token
    end

    def eof?
      return @position >= @stable_input_end if @stable_input_end
      return @position >= @buffer.bytesize if @string_input

      @buffer.eof?(@position)
    end

    def ensure_state!(name)
      return if self.class.__flexr_config.states.key?(name.to_sym)

      diagnostic = Diagnostics.error("FLEXR-E003", "undefined state: #{name}")
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def ensure_progress!(match, scan_state, empty_match:)
      if @position > match.start_pos
        @non_progress_signatures.clear
        return
      end
      return if @halted

      if empty_match && @state == scan_state && self.class.__flexr_config.options[:allow_empty_match]
        force_empty_match_progress!
        @non_progress_signatures.clear
        return
      end

      signature = [match.start_pos, scan_state, match.rule.index]
      repeated = @non_progress_signatures.key?(signature)
      @non_progress_signatures[signature] = true
      return if @state != scan_state && !repeated

      raise Runtime::NonProgressError.new(
        filename: @filename, byte_pos: match.start_pos, line: @line,
        text: text, rule: match.rule.index
      )
    end

    def advance_location!(starting, ending)
      return if ending <= starting

      if @simple_location_input
        @column += ending - starting
        return
      end

      value = location_value(starting, ending)
      location_bytes = value.valid_encoding? ? value : value.b
      newline_count = location_bytes.count("\n")
      if newline_count.zero?
        @column += display_length(value)
      else
        tail = value.byteslice(((location_bytes.rindex("\n") || -1) + 1)..).to_s
        @line += newline_count
        @column = display_length(tail) + 1
      end
    end

    def location_after(starting, ending, line:, column:)
      return [line, column] if ending <= starting

      value = location_value(starting, ending)
      location_bytes = value.valid_encoding? ? value : value.b
      newline_count = location_bytes.count("\n")
      return [line, column + display_length(value)] if newline_count.zero?

      tail = value.byteslice(((location_bytes.rindex("\n") || -1) + 1)..).to_s
      [line + newline_count, display_length(tail) + 1]
    end

    def display_length(value)
      return value.bytesize unless utf8_input?
      return value.bytesize if value.ascii_only?

      utf8 = value.encoding == Encoding::UTF_8 ? value : value.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8.length : value.bytesize
    end

    def location_value(starting, ending)
      return @matched if @matched && starting == @text_start && ending == @match_end

      @buffer.byteslice(starting...ending).to_s
    end

    def discard_consumed_input!
      @buffer.discard_before(@more_start || @position)
    end

    def cancelled?
      return false unless @cancellation

      @cancellation.arity.zero? ? @cancellation.call : @cancellation.call(self)
    end

    def rule_index(rule)
      rule.respond_to?(:index) ? rule.index : rule
    end
  end
end
