# frozen_string_literal: true

module Flexr
  module Runtime
    def initialize(input, filename: nil, error_mode: :raise, max_token_size: 16 * 1024 * 1024,
                   max_state_stack: 1024, chunk_size: Runtime::Buffer::DEFAULT_CHUNK_SIZE)
      raise ArgumentError, "max_token_size must be non-negative" if max_token_size.to_i.negative?
      raise ArgumentError, "max_state_stack must be non-negative" if max_state_stack.to_i.negative?

      self.class.compile!
      @buffer = Runtime::Buffer.new(input, chunk_size: chunk_size)
      @input = input.is_a?(String) ? input : nil
      @filename = filename
      @error_mode = error_mode
      @max_token_size = max_token_size.to_i
      @max_state_stack = max_state_stack.to_i
      @position = 0
      @line = 1
      @state = :initial
      @state_stack = []
      @pending = nil
      @matched = nil
      @match_start = 0
      @match_end = 0
      @text_start = 0
      @text_line = 1
      @bol = true
      @more_start = nil
      @more_line = nil
      @more_requested = false
      @candidate_token_size = 0
      @eof_fired_states = {}
      @on_error = nil
      @halted = false
      @interpreter = nil
    end

    attr_reader :filename, :error_mode, :buffer, :max_token_size

    attr_writer :on_error

    def input
      @buffer.source
    end

    def next_token
      return nil if @halted

      loop do
        return nil if @halted

        if eof? && @pending.nil?
          eof_action = self.class.__flexr_spec.eof_rules[@state]
          if eof_action && !@eof_fired_states[@state]
            @eof_fired_states[@state] = true
            @match_start = @position
            @match_end = @position
            @text_start = @position
            @text_line = @line
            @matched = nil
            instance_exec(&eof_action)
            token = @pending
            @pending = nil
            return token if token
            next
          end
          return nil
        end

        match = if generated_runtime? && respond_to?(:scan_one, true)
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
        if @more_start
          @text_start = @more_start
          @text_line = @more_line
        else
          @text_start = @match_start
          @text_line = @line
        end
        @matched = nil
        @more_requested = false
        @position = match.end_pos
        empty_match = match.end_pos == match.start_pos
        execute(match.rule)
        finalize_more
        force_empty_match_progress! if empty_match && self.class.__flexr_config.options[:allow_empty_match]
        ensure_token_size!
        update_position
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

        if self.class.__flexr_config.token_kind == :yield
          yield(*token)
        else
          yield token
        end
      end
      self
    end

    def tokens
      each_token.to_a
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

    def defer_token_size_check!(size)
      @candidate_token_size = size if size > @candidate_token_size
    end

    def utf8_input?
      self.class.__flexr_config.encoding == Encoding::UTF_8
    end

    def valid_utf8_at?(position)
      !utf8_input? || @buffer.valid_utf8_at?(position)
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
      @buffer.source.b
    end

    def emit(type, value = text)
      @pending = case self.class.__flexr_config.token_kind
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
      error = LexError.new(message, filename: @filename, byte_pos: @match_start, line: @line, text: text)
      if @on_error
        action = @on_error.call(error)
        return @pending = nil if action == :skip
        raise error if action == :raise
        if action == :halt
          @halted = true
          return @pending = nil
        end
        return emit(:error, text) if action == :token
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
          filename: @filename, byte_pos: @position, line: @line, text: text
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

      @position = @match_start + count
      @match_end = @position
      @matched = nil
    end

    def more
      @more_requested = true
    end

    def last_location
      line_begin = @text_line || @line
      Runtime::Location.new(
        filename: @filename, byte_begin: @text_start, byte_end: @match_end,
        line_begin: line_begin, line_end: line_begin + text.to_s.b.count("\n"),
        column_values: [column_at(@text_start), column_at(@match_end)],
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
      else
        @more_start = nil
        @more_line = nil
      end
      @more_requested = false
    end

    def generated_runtime?
      self.class.respond_to?(:__flexr_generated?) && self.class.__flexr_generated?
    end

    def ensure_token_size!
      actual_size = @match_end - @text_start
      @candidate_token_size = 0
      return if actual_size <= @max_token_size

      raise Runtime::TokenTooLargeError, "token exceeds max_token_size"
    end

    def force_empty_match_progress!
      return if eof?

      byte = @buffer.byteslice(@position, 1).to_s.b
      @position += 1
      @line += 1 if byte == "\n"
      @bol = byte == "\n"
    end

    def update_position
      if @match_end > @match_start
        length = @match_end - @match_start
        @line += if length == 1
          @buffer.source.getbyte(@match_start) == 0x0a ? 1 : 0
        else
          @buffer.byteslice(@match_start, length).to_s.count("\n")
        end
      end
      @bol = @match_end.zero? || @buffer.source.getbyte(@match_end - 1) == 0x0a
    end

    def handle_unmatched_byte
      bad = @buffer.byteslice(@position, 1)
      @match_start = @position
      @match_end = @position + 1
      @text_start = @match_start
      @text_line = @line
      @position += 1
      @line += 1 if bad.to_s.b == "\n"
      @bol = bad.to_s.b == "\n"
      error!("unexpected byte #{bad.inspect}")
      token = @pending
      @pending = nil
      token
    end

    def eof?
      @buffer.eof?(@position)
    end

    def ensure_state!(name)
      return if self.class.__flexr_config.states.key?(name.to_sym)

      diagnostic = Diagnostics.error("FLEXR-E003", "undefined state: #{name}")
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def column_at(position)
      prefix = @buffer.byteslice(0...position).to_s
      last_newline = prefix.rindex("\n")
      line_prefix = prefix.byteslice((last_newline ? last_newline + 1 : 0)..).to_s
      if utf8_input? && line_prefix.dup.force_encoding(Encoding::UTF_8).valid_encoding?
        line_prefix.force_encoding(Encoding::UTF_8).length + 1
      else
        line_prefix.bytesize + 1
      end
    end
  end
end
