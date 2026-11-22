# frozen_string_literal: true

require "json"
require_relative "../lib/flexr"

module Flexr
  module Benchmarking
    module LramaLexer
      module_function

      def recognizer(patterns)
        Class.new(Flexr::Lexer) do
          encoding Encoding::BINARY
          patterns.each { |pattern, kind| rule(pattern, emit: kind) }
        end.recognizer
      end

      def patterns(native)
        symbols = native::SYMBOLS.map { |symbol| [symbol.delete_prefix("\\"), :SYMBOL] }
        symbols + [[/[?+*]/, :SYMBOL], [/[0-9]+/, :INTEGER], [native::IDENTIFIER_PATTERN, :IDENTIFIER]]
      end

      def adapter(native, recognizer)
        Class.new(native) do
          define_method(:initialize) do |file|
            super(file)
            @recognizer_input = file.text if file.text.encoding.ascii_compatible? && file.text.valid_encoding?
          end

          define_method(:lex_token) do
            return super() unless @recognizer_input

            until @scanner.eos?
              if @scanner.scan("\n")
                newline
              elsif @scanner.scan(/[^\S\n]+/)
                next
              elsif @scanner.scan(%r{/\*})
                lex_comment
              elsif @scanner.scan(%r{//.*(?<newline>\n)?})
                newline if @scanner[:newline]
              else
                break
              end
            end

            start = @scanner.pos
            match = recognizer.match(@recognizer_input, start)
            return super() unless match

            kind, ending = match
            reset_first_position
            @scanner.pos = ending
            text = @recognizer_input.byteslice(start, ending - start)
            case kind
            when :SYMBOL
              [text, native::Token::Token.new(s_value: text, location: location)]
            when :INTEGER
              [:INTEGER, native::Token::Int.new(s_value: Integer(text), location: location)]
            when :IDENTIFIER
              token = native::Token::Ident.new(s_value: text, location: location)
              [identifier_colon? ? :IDENT_COLON : :IDENTIFIER, token]
            end
          end
        end
      end

      def observe(klass, inputs)
        events = []
        recording = Class.new(klass) do
          define_method(:next_token) do
            super().tap do |token|
              if token
                type, value = token
                loc = value.location
                events << [type, value.class, value.s_value, loc.first_line, loc.first_column, loc.last_line, loc.last_column]
              end
            end
          end
        end
        with_lexer(recording) do
          inputs.map do |path, source|
            events = []
            error = parse(source, path)
            [events, error]
          end
        end
      end

      def parse(source, path)
        Lrama::Parser.new(source, path).parse
        nil
      rescue StandardError => e
        [e.class.name, e.message]
      end

      def with_lexer(klass)
        original = Lrama::Lexer
        return yield if klass == original

        Lrama.send(:remove_const, :Lexer)
        Lrama.const_set(:Lexer, klass)
        begin
          yield
        ensure
          Lrama.send(:remove_const, :Lexer)
          Lrama.const_set(:Lexer, original)
        end
      end

      def measure(klass, inputs, iterations)
        with_lexer(klass) do
          3.times { inputs.each { |path, source| parse(source, path) } }
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          iterations.times { inputs.each { |path, source| parse(source, path) } }
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
      end

      def run(root, iterations: 3, out: $stdout)
        $LOAD_PATH.unshift(File.join(root, "lib"))
        require "lrama"
        native = Lrama::Lexer
        candidate = adapter(native, recognizer(patterns(native)))
        paths = Dir[File.join(root, "spec/fixtures/**/*.y")]
        raise "no upstream fixture corpus" if paths.empty?

        inputs = paths.map { |path| [path, File.read(path)] }
        expected = observe(native, inputs)
        actual = observe(candidate, inputs)
        mismatch = expected.each_index.find { |index| expected[index] != actual[index] }
        raise "lexer mismatch: #{paths.fetch(mismatch)}" if mismatch

        timings = { native: native, embedded: candidate }.transform_values do |klass|
          measure(klass, inputs, iterations)
        end
        result = { ruby: RUBY_DESCRIPTION, fixtures: paths.length, successful_parses: expected.count { |_, error| error.nil? },
                   tokens_compared: expected.sum { |events, _| events.length }, iterations: iterations, seconds: timings,
                   relative_to_native: timings[:embedded] / timings[:native],
                   scope: "symbols, integers, and identifiers; other tokens and parser use native Lrama" }
        out.puts JSON.pretty_generate(result)
        result
      end
    end
  end
end

Flexr::Benchmarking::LramaLexer.run(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
