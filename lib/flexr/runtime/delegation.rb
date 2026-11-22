# frozen_string_literal: true

module Flexr
  module Runtime
    module DelegatedTokens
      def next_token(...)
        return super if @halted || !@__flexr_delegated_queue || (@__flexr_indent_queue && !@__flexr_indent_queue.empty?)

        token = @__flexr_delegated_queue.shift
        @__flexr_delegated_queue = nil if @__flexr_delegated_queue.empty?
        token
      end
    end

    MAX_DELEGATION_DEPTH = 32
    private_constant :MAX_DELEGATION_DEPTH

    def delegate(lexer_class, capture:)
      raise ArgumentError, "delegation requires a named capture action" unless @capture_match
      raise ArgumentError, "delegation requires a default-channel parent rule" if @capture_match.rule.channel
      raise ArgumentError, "delegate requires a Flexr::Lexer subclass" unless lexer_class.is_a?(Class) && lexer_class < Lexer
      raise ArgumentError, "capture: requires a named capture Symbol" unless capture.is_a?(Symbol)

      config = lexer_class.__flexr_config
      raise ArgumentError, "delegated lexers must use the parent encoding" if config.encoding != self.class.__flexr_config.encoding
      raise ArgumentError, "a struct parent requires a struct child lexer" if @token_kind == :struct && config.token_kind != :struct

      starting, ending = delegated_capture_range(capture)
      return unless starting
      raise ArgumentError, "delegated capture is outside the current match" if ending > @match_end

      line, column = location_after(@capture_match.start_pos, starting, line: @line, column: @column)
      source = @buffer.byteslice(starting, ending - starting).freeze
      tokens = delegated_tokens(lexer_class, source, [starting, line, column, source.bytesize])
      (@__flexr_delegation_tokens ||= []).concat(tokens)
      @__flexr_delegation_end = [@__flexr_delegation_end || ending, ending].max
      nil
    end

    private

    def delegated_capture_range(capture)
      starting, ending = capture_data.byteoffset(capture)
      return unless starting

      origin = @capture_match.start_pos
      [origin + starting, origin + ending]
    rescue IndexError
      raise ArgumentError, "unknown delegated capture #{capture.inspect}"
    end

    def delegated_tokens(lexer_class, source, origin)
      depth = @__flexr_delegation_depth.to_i + 1
      if depth > MAX_DELEGATION_DEPTH
        raise LexError.new("lexer delegation exceeds #{MAX_DELEGATION_DEPTH} levels of nesting",
                           filename: @filename, byte_pos: origin[0], line: origin[1])
      end

      child = lexer_class.new(source, filename: @filename, error_mode: @error_mode, max_token_size: @max_token_size,
                              max_buffer_size: @buffer.max_buffer_size, max_lookahead_size: @max_lookahead_size,
                              max_state_stack: @max_state_stack, max_steps: @max_steps && (@max_steps - @steps),
                              cancellation: @cancellation && -> { cancelled? })
      child.instance_variable_set(:@__flexr_delegation_depth, depth)
      tokens = []
      while (token = child.next_token)
        tokens << (@token_kind == :struct ? rebase_delegated_token(token, origin) : [token[0], token[1]])
      end
      tokens
    rescue LexError => e
      raise unless child

      raise rebase_delegated_error(e, origin)
    ensure
      @steps += child.steps if child
    end

    def rebase_delegated_token(token, origin)
      raise ArgumentError, "delegation requires positioned child tokens" unless token.is_a?(Token) && token.location

      source = token.location
      byte, line, column, size = origin
      raise ArgumentError, "delegated token location is outside the captured input" unless
        source.filename == @filename && source.byte_begin.between?(0, size) && source.byte_end.between?(source.byte_begin, size)

      location = Location.new(filename: @filename, byte_begin: byte + source.byte_begin, byte_end: byte + source.byte_end,
                              line_begin: line + source.line_begin - 1, line_end: line + source.line_end - 1,
                              column_begin: source.column_begin + (source.line_begin == 1 ? column - 1 : 0),
                              column_end: source.column_end + (source.line_end == 1 ? column - 1 : 0))
      changes = { location: location }
      changes[:leading_trivia] = token.leading_trivia.map { |item| rebase_delegated_token(item, origin) } unless token.leading_trivia.empty?
      token.with(**changes)
    end

    def rebase_delegated_error(error, origin)
      byte, line = origin
      rebased = error.dup
      rebased.instance_variable_set(:@filename, @filename)
      rebased.instance_variable_set(:@byte_pos, error.byte_pos && (byte + error.byte_pos))
      rebased.instance_variable_set(:@line, error.line && (line + error.line - 1))
      if (diagnostic = error.diagnostic) && diagnostic.location
        diagnostic = diagnostic.dup
        diagnostic.location = diagnostic.location.map { |position| byte + position }
        rebased.instance_variable_set(:@diagnostic, diagnostic)
      end
      rebased
    end

    def finish_delegation
      raise ArgumentError, "delegated capture is outside the current match" if @__flexr_delegation_end > @match_end

      tokens = @__flexr_delegation_tokens
      return if @halted || tokens.empty?

      tokens << @pending if @pending
      @__flexr_delegated_location = last_location if @__flexr_indentation
      @pending = tokens.shift
      return if tokens.empty?

      @__flexr_delegated_queue = tokens
      extend DelegatedTokens unless is_a?(DelegatedTokens)
    end
  end
end
