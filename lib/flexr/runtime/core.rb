# frozen_string_literal: true

module Flexr
  module Runtime
    def initialize(input, filename: nil, error_mode: :raise, max_token_size: 16 * 1024 * 1024)
      raise ArgumentError, "input must be a String" unless input.is_a?(String)

      self.class.compile!
      @input = input
      @binary_input = input.dup.force_encoding(Encoding::BINARY)
      @filename = filename
      @error_mode = error_mode
      @max_token_size = max_token_size
      @position = 0
      @line = 1
      @state = :initial
      @state_stack = []
      @pending = nil
      @matched = nil
      @match_start = 0
      @match_end = 0
      @bol = true
      @more_start = nil
      @eof_fired = false
    end

    attr_reader :input, :filename, :error_mode

    def next_token
      loop do
        if eof? && @pending.nil?
          eof_action = self.class.__flexr_spec.eof_rules[@state]
          if eof_action && !@eof_fired
            @eof_fired = true
            instance_exec(&eof_action)
            token = @pending
            @pending = nil
            return token if token
          end
          return nil
        end

        match = Runtime::Interpreter.new(self).scan
        unless match
          return handle_unmatched_byte if !eof?
          return nil
        end
        raise LexError, "token exceeds max_token_size" if match.end_pos - match.start_pos > @max_token_size

        @match_start = match.start_pos
        @match_end = match.end_pos
        @matched = nil
        @position = match.end_pos
        execute(match.rule)
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

      @matched = @input.byteslice(@match_start...@match_end)
    end

    def text_bytesize
      @match_end - @match_start
    end

    def byte_pos
      @position
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
      @binary_input
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

    def push(name)
      ensure_state!(name)
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
      raise ArgumentError, "less must not exceed matched bytes" if count.negative? || count > text_bytesize

      @position = @match_end - count
      @match_end = @position
    end

    def more
      @more_start ||= @match_start
    end

    def last_location
      Runtime::Location.new(
        filename: @filename, byte_begin: @match_start, byte_end: @match_end,
        line_begin: @line, line_end: @line + text.count("\n"),
        column_begin: column_at(@match_start), column_end: column_at(@match_end)
      )
    end

    private

    def execute(rule)
      case rule.action
      when :skip
        nil
      when Array
        emit(rule.action[1], text)
      else
        instance_exec(&rule.action)
      end
    end

    def update_position
      consumed = @input.byteslice(@match_start...@match_end).to_s
      @line += consumed.count("\n")
      @bol = consumed.end_with?("\n") || (@match_end == 0)
    end

    def handle_unmatched_byte
      bad = @input.byteslice(@position, 1)
      @match_start = @position
      @match_end = @position + 1
      @position += 1
      @line += 1 if bad == "\n"
      @bol = bad == "\n"
      error!("unexpected byte #{bad.inspect}")
      token = @pending
      @pending = nil
      token
    end

    def eof?
      @position >= @binary_input.bytesize
    end

    def ensure_state!(name)
      return if self.class.__flexr_config.states.key?(name.to_sym)

      diagnostic = Diagnostics.error("FLEXR-E003", "undefined state: #{name}")
      raise CompileError.new(diagnostic.message, diagnostic: diagnostic)
    end

    def column_at(position)
      prefix = @input.byteslice(0...position).to_s
      last_newline = prefix.rindex("\n")
      position - (last_newline ? last_newline + 1 : 0) + 1
    end
  end
end
