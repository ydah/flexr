# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/flexr"

module Flexr
  module Benchmarking
    module LramaParserContexts
      module_function

      def terminal_rows(parser)
        table, check, defaults, pointers, _, _, _, _, _, _, tokens, _, reduce_count = parser::Racc_arg
        pointers.each_with_index.map do |pointer, state|
          tokens.filter_map do |name, id|
            next unless name && name != :error

            offset = pointer + id if pointer
            explicit = offset && offset.between?(0, check.length - 1) && check[offset] == state
            name.to_sym unless (explicit ? table[offset] : defaults[state]) == -reduce_count
          end.freeze
        end.freeze
      end

      def recording_parser
        Class.new(::Lrama::Parser) do
          attr_reader :requests

          def do_parse
            @requests = []
            _racc_do_parse_rb(_racc_setup, false)
          end

          def next_token
            state = @racc_state.last
            super.tap { |token| @requests << [state, *token] if token&.first }
          end
        end
      end

      def lexer_patterns
        fixed = ::Lrama::Lexer::SYMBOLS.map { |text| text.delete_prefix("\\") } +
          ::Lrama::Lexer::PERCENT_TOKENS + %w[? + *]
        fixed.to_h { |text| [text.to_sym, text] }.merge(
          IDENTIFIER: ::Lrama::Lexer::IDENTIFIER_PATTERN, INTEGER: /[0-9]+/, TAG: ::Lrama::Lexer::TAG_PATTERN
        )
      end

      def record_requests(directory, terminal_sets, patterns)
        parser_class = recording_parser
        paths = Dir.glob(File.join(directory, "{sample,spec/fixtures}/**/*.y"))
        raise ArgumentError, "no Lrama grammar fixtures under #{directory}" if paths.empty?

        events = []
        states = {}
        requests = 0
        rejected = 0
        paths.each do |path|
          text = File.read(path)
          parser = parser_class.new(text, path)
          begin
            parser.parse
          rescue Racc::ParseError
            rejected += 1
            next
          end
          lines = text.lines
          parser.requests.each do |state, token, value|
            kind = token.to_sym
            raise "Lrama requested #{kind.inspect} in state #{state} at #{path}" unless terminal_sets.fetch(state).include?(kind)

            states[state] = true
            requests += 1
            next unless patterns.key?(kind)

            location = value.location
            lexeme = lines.fetch(location.first_line - 1)[location.first_column...location.last_column]
            events << [state, [kind, lexeme.b].freeze]
          end
        end
        raise "no replayable Lrama requests" if events.empty?

        [events, {fixtures: paths.size - rejected, rejected: rejected, requests: requests,
                  visited_states: states.size, replayed: events.size}]
      end

      def generate_lexers(patterns, terminal_sets)
        contextual = Class.new(Generator) { define_method(:lrama_terminal_rows) { terminal_sets } }
        body = patterns.map { |kind, pattern| "  rule(#{pattern.inspect}, emit: #{kind.inspect})" }.join("\n")
        Dir.mktmpdir("flexr-lrama-context-bench-") do |directory|
          [[Generator, "Plain"], [contextual, "Context"]].map do |generator, suffix|
            name = "LramaContextBenchmark#{suffix}"
            path = File.join(directory, "#{name}.flexr.rb")
            output = File.join(directory, "#{name}.rb")
            File.write(path, <<~RUBY)
              class #{name} < Flexr::Lexer
                encoding Encoding::BINARY
                rule(" ", skip: true)
              #{body}
              end
            RUBY
            generator.new(path, output: output, options: {backend: :direct}).generate
            load output
            Object.const_get(name)
          end
        end
      end

      def sample(lexer, input, events, &request)
        scanner = lexer.new(input)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        events.each do |state, expected|
          actual = request.call(scanner, state)
          raise "state #{state} returned #{actual.inspect}, expected #{expected.inspect}" unless actual == expected
        end
        raise "lexer left a token after replay" if scanner.next_token

        (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1_000
      end

      def run(directory, iterations: 9)
        $LOAD_PATH.unshift(File.join(directory, "lib"))
        require "lrama"

        terminal_sets = terminal_rows(::Lrama::Parser)
        patterns = lexer_patterns
        events, counts = record_requests(directory, terminal_sets, patterns)
        input = events.map { |_, token| token.last }.join(" ").freeze
        plain, contextual = generate_lexers(patterns, terminal_sets)
        modes = {
          plain: [plain, ->(scanner, _) { scanner.next_token }],
          expect: [plain, ->(scanner, state) { scanner.next_token(expect: terminal_sets.fetch(state)) }],
          parser_state: [contextual, ->(scanner, state) { scanner.next_token(parser_state: state) }]
        }
        modes.each_value { |lexer, request| sample(lexer, input, events, &request) }
        times = modes.transform_values { [] }
        iterations.times do |iteration|
          modes.keys.rotate(iteration).each do |mode|
            lexer, request = modes.fetch(mode)
            times.fetch(mode) << sample(lexer, input, events, &request)
          end
        end
        stats = times.transform_values do |samples|
          sorted = samples.sort
          {median: sorted.fetch(sorted.length / 2), min: sorted.first, max: sorted.last}
        end
        puts JSON.pretty_generate(counts.merge(lr_states: terminal_sets.size, terminal_sets: terminal_sets.uniq.size,
                                               iterations: iterations, milliseconds: stats))
      end
    end
  end
end

Flexr::Benchmarking::LramaParserContexts.run(File.expand_path(ARGV.fetch(0)), iterations: Integer(ARGV.fetch(1, 9))) if
  $PROGRAM_NAME == __FILE__
