# frozen_string_literal: true

module Flexr
  module Runtime
    class Parallel
      Mark = Data.define(:boundary, :token_index)
      Tape = Data.define(:tokens, :marks, :eof) do
        def join(boundary)
          index = marks.bsearch_index { |mark| mark.boundary.position >= boundary.position }
          while index && (mark = marks[index]) && mark.boundary.position == boundary.position
            candidate = mark.boundary
            return mark if boundary.converges?(candidate, delta: 0) &&
              boundary.line == candidate.line && boundary.column == candidate.column

            index += 1
          end
        end
      end
      private_constant :Mark, :Tape

      def self.tokens(lexer_class, input, workers:, min_bytes:, filename:)
        raise ArgumentError, "parallel input must be a String" unless input.is_a?(String)
        raise ArgumentError, "workers must be a positive Integer" unless workers.is_a?(Integer) && workers.positive?
        raise ArgumentError, "min_bytes must be a nonnegative Integer" unless min_bytes.is_a?(Integer) && min_bytes >= 0

        return lexer_class.new(input, filename: filename).tokens if
          workers == 1 || input.bytesize < min_bytes || !eligible?(lexer_class, input, filename)

        source = String.new(input).freeze
        plan = ParallelPlan.new(lexer_class, source, workers: workers)
        return lexer_class.new(source, filename: filename).tokens if plan.chunks.size <= 1

        new(lexer_class, source, filename).run(plan)
      end

      def self.eligible?(lexer_class, input, filename)
        return false unless defined?(Ractor) && input.instance_of?(String) && input.singleton_methods.empty?
        return false unless filename.nil? || (filename.instance_of?(String) && filename.singleton_methods.empty?)
        return false unless Boundary.standard_lexer?(lexer_class)

        spec = lexer_class.__flexr_spec
        spec.backend != :firstmatch && spec.eof_rules.empty? && !spec.options[:input_stack] &&
          spec.rules.all? { |rule| rule.emit? || rule.skip? } &&
          (spec.encoding != Encoding::UTF_8 || input.b.force_encoding(Encoding::UTF_8).valid_encoding?)
      end
      private_class_method :eligible?

      def self.scan_chunk(lexer_class, source, chunk, filename)
        layout = lexer_class.__flexr_config.options[:indentation]
        tapes = []
        chunk.seeds.each do |seed|
          next if !layout && tapes.any? { |tape| tape.marks.any? { |mark| mark.boundary.position == seed.position } }

          scanner = RelexScanner.new(lexer_class, source, filename: filename, error_mode: :raise, track_reads: false)
          origin = scanner.start_at(seed.position, line: seed.line, column: seed.column)
          tapes << scan_tape(scanner, origin, chunk.limit, compact: chunk.certified && !layout)
        end
        tapes
      end

      def self.scan_tape(scanner, origin, limit, compact:)
        tokens = []
        marks = [Mark.new(origin, 0)]
        loop do
          token = scanner.next_token
          unless token
            boundary = scanner.boundary
            marks << Mark.new(boundary, tokens.size) if boundary
            return Tape.new(tokens, marks, true)
          end

          tokens << token
          at_limit = limit && scanner.position >= limit
          next if compact && marks.size > 1 && !at_limit

          boundary = scanner.boundary
          next unless boundary

          marks << Mark.new(boundary, tokens.size)
          return Tape.new(tokens, marks, false) if at_limit
        end
      rescue LexError
        Tape.new(tokens.take(marks.last.token_index), marks, false)
      end
      private_class_method :scan_tape

      def initialize(lexer_class, source, filename)
        @source = source
        @filename = filename.is_a?(String) ? String.new(filename).freeze : filename
        @scanner = RelexScanner.new(lexer_class, source, filename: @filename, error_mode: :raise, track_reads: false)
        @boundary = @scanner.boundary
        @tokens = []
      end

      def run(plan)
        running = []
        plan.chunks.each_with_object(running) do |chunk, pending|
          worker = Ractor.new(plan.lexer_class, @source, chunk, @filename) do |lexer_class, source, fragment, filename|
            Parallel.scan_chunk(lexer_class, source, fragment, filename)
          end
          pending << [worker, chunk.limit]
        end

        until running.empty?
          worker, limit = running.shift
          break if merge(worker_result(worker), limit)
        end
        @tokens
      ensure
        running.each do |job|
          worker_result(job.first)
        rescue Ractor::RemoteError
          next
        end
      end

      private

      def worker_result(worker)
        worker.respond_to?(:value) ? worker.value : worker.take
      end

      def merge(tapes, limit)
        positioned = false
        loop do
          if @boundary
            return false if limit && @boundary.position >= limit

            mark = nil
            if (joined = tapes.find { |tape| mark = tape.join(@boundary) })
              @tokens.concat(mark.token_index.zero? ? joined.tokens : joined.tokens.drop(mark.token_index))
              return true if joined.eof

              @boundary = joined.marks.last.boundary
              tapes.delete(joined)
              positioned = false
              next
            end

            @scanner.restore(@boundary) unless positioned
            positioned = true
          end

          token = @scanner.next_token
          return true unless token

          @tokens << token
          @boundary = @scanner.boundary
        end
      end
    end
  end
end
