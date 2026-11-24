# frozen_string_literal: true

require "tmpdir"
require_relative "../lib/flexr"

module Flexr
  module Benchmarking
    module LramaParserContexts
      module_function

      def terminal_rows(parser)
        args = parser::Racc_arg
        actions = args.first(4)
        tokens, _, reduce_count = args[10, 3]
        actions.last.each_index.map do |state|
          tokens.filter_map do |name, id|
            next unless name && name != :error

            name.to_sym unless packed_entry(actions, state, id) == -reduce_count
          end.freeze
        end.freeze
      end

      def packed_entry(entries, row, column)
        table, checks, defaults, pointers = entries
        pointer = pointers.fetch(row)
        offset = pointer + column if pointer
        return table.fetch(offset) if offset && offset >= 0 && checks[offset] == row

        defaults.fetch(row)
      end

      def grammar_states(directory, parser)
        path = File.join(directory, "parser.y")
        grammar = Racc::GrammarFileParser.new.parse(File.read(path), path).grammar
        states = Racc::States.new(grammar).nfa.dfa
        table = states.state_transition_table
        fields = %i[action_table action_check action_default action_pointer goto_table goto_check goto_default
                    goto_pointer nt_base reduce_table token_value_table shift_n reduce_n]
        rebuilt = fields.map { |field| table.public_send(field) }
        raise "parser.y did not reproduce Lrama's generated Racc tables" unless rebuilt == parser::Racc_arg.first(fields.length)

        states.each_state.to_a
      end

      def grammar_paths(states, parser)
        root = states.fetch(0)
        paths = Array.new(states.length)
        paths[root.ident] = []
        queue = [root]
        queue.each do |state|
          state.gotos.each do |symbol, edge|
            target = edge.to_state
            if symbol.terminal?
              action = state.action[symbol]
              next unless action.is_a?(Racc::Shift) && action.goto_id == target.ident
            end
            next if paths.fetch(target.ident)

            paths[target.ident] = [*paths.fetch(state.ident), symbol]
            queue << target
          end
        end

        args = parser::Racc_arg
        actions = args.first(4)
        gotos = args[4, 4]
        nonterminal_base = args.fetch(8)
        paths.map.with_index do |path, target|
          raise "missing grammar path for Lrama state #{target}" unless path

          state = path.reduce(root.ident) do |id, symbol|
            if symbol.terminal?
              packed_entry(actions, id, symbol.ident)
            else
              packed_entry(gotos, symbol.ident - nonterminal_base, id)
            end
          end
          raise "grammar path for Lrama state #{target} ended in state #{state}" unless state == target

          path.map { |symbol| symbol.value ? symbol.value.to_s : "$end" }
        end
      end

      def ambiguity_input(patterns)
        lexer = Class.new(Lexer) do
          backend :direct
          encoding Encoding::BINARY
          rule(" ", skip: true)
          patterns.each { |kind, pattern| rule(pattern, emit: kind) }
        end
        Source::SemanticDiff::Input.from_lexer(lexer)
      end

      def check_ambiguity(directory)
        gem "racc", "1.8.1"
        require "racc/grammarfileparser"
        require "racc/state"
        require "racc/statetransitiontable"
        require_relative "../lib/flexr/grammar/context_ambiguity"
        $LOAD_PATH.unshift(File.join(directory, "lib"))
        require "lrama"

        parser = ::Lrama::Parser
        states = grammar_states(directory, parser)
        paths = grammar_paths(states, parser)
        rows = terminal_rows(parser)
        patterns = lexer_patterns
        diagnostics = Grammar::ContextAmbiguity.diagnostics(ambiguity_input(patterns), rows, paths)
        raise "Lrama replay lexer ambiguity check returned #{diagnostics.map(&:to_h).inspect}" unless diagnostics.empty?

        probe_tokens = %i[%token %type]
        target = states.find do |state|
          paths.fetch(state.ident).last == "%%" && probe_tokens.all? do |token|
            state.action.any? { |symbol, action| symbol.value == token.to_s && action.is_a?(Racc::Shift) }
          end
        end
        raise "no Lrama state shifts both #{probe_tokens.inspect} after %%" unless target

        example = patterns.fetch(probe_tokens.first)
        probe_patterns = patterns.merge(probe_tokens.last => example)
        probe_rows = Array.new(rows.length, [].freeze)
        probe_rows[target.ident] = rows.fetch(target.ident)
        probe_diagnostics = Grammar::ContextAmbiguity.diagnostics(ambiguity_input(probe_patterns), probe_rows, paths)
        parser_path = [*paths.fetch(target.ident), "•"].join(" ")
        probe = probe_diagnostics.find do |diagnostic|
          diagnostic.code == "FLEXR-W024" && diagnostic.message.start_with?("parser state #{target.ident} ") &&
            probe_tokens.all? { |token| diagnostic.message.include?(token.to_s) } &&
            diagnostic.note == "example input: #{example.inspect} (byte offset 0)" &&
            diagnostic.help == "parser path: #{parser_path}"
        end
        raise "Lrama ambiguity probe did not report its state, example, and grammar path" unless probe

        puts JSON.pretty_generate(lr_states: rows.length, terminal_sets: rows.uniq.length, grammar_paths: paths.length,
                                 lexer_terminal_sets: rows.map { |row| row & patterns.keys }.uniq.length,
                                 diagnostics: diagnostics.length, probe: probe.to_h)
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

if $PROGRAM_NAME == __FILE__
  if ARGV.first == "--check-ambiguity"
    Flexr::Benchmarking::LramaParserContexts.check_ambiguity(File.expand_path(ARGV.fetch(1)))
  else
    Flexr::Benchmarking::LramaParserContexts.run(File.expand_path(ARGV.fetch(0)), iterations: Integer(ARGV.fetch(1, 9)))
  end
end
