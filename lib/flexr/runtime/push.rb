# frozen_string_literal: true

module Flexr
  module Runtime
    class Push
      NEED_INPUT = Object.new.freeze
      private_constant :NEED_INPUT

      class Source
        def initialize(encoding)
          @encoding = encoding
        end

        def offer(bytes)
          @chunk = String.new(bytes, encoding: @encoding)
          @offset = 0
        end

        def finish
          @finished = true
        end

        def limit_next_read(max_bytes)
          @read_limit = max_bytes
        end

        def read(size)
          until @chunk
            return if @finished

            Fiber.yield(NEED_INPUT)
          end

          size = [size, @read_limit].min if @read_limit
          @read_limit = nil
          bytes = @chunk.byteslice(@offset, size)
          @offset += bytes.bytesize
          @chunk = nil if @offset == @chunk.bytesize
          bytes
        end
      end

      def initialize(lexer_class, retain_input: false, **)
        lexer_class.compile!
        config = lexer_class.__flexr_config
        @source = Source.new(config.encoding)
        scanner = lexer_class.new(@source, retain_input: retain_input, **)
        @thread = Thread.current
        @yield_pairs = config.token_kind == :yield
        @fiber = Fiber.new(blocking: true) do
          while (token = scanner.next_token)
            Fiber.yield(token)
          end
        end
      end

      def feed(bytes, &block)
        check_access!
        raise IOError, "push lexer is finished" unless @fiber
        raise ArgumentError, "push input must be a String" unless bytes.is_a?(String)
        return block ? self : [] if bytes.empty?

        @source.offer(bytes)
        drain(&block)
      end

      def finish(&block)
        check_access!
        return block ? self : [] unless @fiber

        @source.finish
        drain(&block)
      end

      private

      def check_access!
        raise FiberError, "push lexer belongs to another thread" unless @thread.equal?(Thread.current)
        raise IOError, "push lexer is already running" if @running
      end

      def drain
        @running = true
        tokens = [] unless block_given?
        while @fiber.alive?
          token = @fiber.resume
          break unless @fiber.alive?
          if token.equal?(NEED_INPUT)
            waiting = true
            break
          end

          if tokens
            tokens << token
          elsif @yield_pairs
            yield(*token)
          else
            yield token
          end
        end
        tokens || self
      ensure
        @running = false
        @fiber = @source = nil unless waiting
      end
    end
  end
end
