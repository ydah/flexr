# frozen_string_literal: true

require "digest"
require "json"
require_relative "action_effects"

module Flexr
  module Source
    class GenerationProfile
      MIN_RUN_BYTES = 384
      MIN_SAMPLES = 2

      StateStats = Struct.new(:visits, :arrivals, :loop_bytes, :longest_loop, :first_bytes) do
        def hot_loop?
          arrivals >= MIN_SAMPLES && loop_bytes >= arrivals * MIN_RUN_BYTES
        end
      end

      TokenStats = Struct.new(:matches, :bytes, :longest) do
        def record(length)
          self.matches += 1
          self.bytes += length
          self.longest = [longest, length].max
        end
      end
      private_constant :StateStats, :TokenStats

      attr_reader :loops, :whole_tokens

      def initialize(parsed, compiled, backend:, options:, patterns:, output:, optimize:)
        @compiled = compiled
        @states = Hash.new do |by_machine, name|
          by_machine[name] = Hash.new { |by_state, id| by_state[id] = StateStats.new(0, 0, 0, 0, {}) }
        end
        @first_bytes = Hash.new { |by_machine, name| by_machine[name] = Hash.new { |by_byte, byte| by_byte[byte] = TokenStats.new(0, 0, 0) } }
        @rules = Hash.new { |by_machine, name| by_machine[name] = Hash.new { |by_rule, id| by_rule[id] = TokenStats.new(0, 0, 0) } }
        @opaque_matches = @tokens = @bytes = 0
        @loops = {}
        @whole_tokens = {}
        paths = corpus_paths(patterns)
        paths.each { |path| ArtifactWriter.ensure_distinct!(path, output) } if output

        lexer = projection_lexer(parsed, backend, options)
        digests = paths.map do |path|
          input = read_corpus(path).freeze
          @bytes += input.bytesize
          lexer.new(input, filename: path, max_buffer_size: input.bytesize).each_token { nil }
          Digest::SHA256.new.update([input.bytesize].pack("Q>")).update(input).digest
        end
        @files = paths.length
        @digest = Digest::SHA256.hexdigest(digests.sort.join)
        select_strategies(parsed.config.fetch(:encoding), options) if optimize
      end

      def header_lines
        states = @states.sort.to_h.transform_values do |visits|
          visits.sort.to_h.transform_values { |stats| stats.to_h.except(:first_bytes) }
        end
        rules = @rules.sort.to_h.transform_values { |tokens| tokens.sort.to_h.transform_values(&:to_h) }
        summary = {version: 1, sha256: @digest, files: @files, bytes: @bytes, tokens: @tokens, opaque_matches: @opaque_matches,
                   states: states, rules: rules}
        strategies = {
          loops: @loops.transform_values { |regions| regions.transform_values { |region| region.is_a?(String) ? :byteindex : :strscan } },
          whole_tokens: @whole_tokens.transform_values(&:keys)
        }
        ["# profile: #{JSON.generate(summary)}", "# profile-strategies: #{JSON.generate(strategies)}"]
      end

      private

      def corpus_paths(patterns)
        paths = Array(patterns).flat_map do |pattern|
          paths = Dir.glob(pattern).select { |path| File.file?(path) }
          raise ArgumentError, "profile pattern matched no regular files: #{pattern.inspect}" if paths.empty?

          paths.map { |path| File.realpath(path) }
        end
        raise ArgumentError, "--profile requires a corpus glob" if paths.empty?

        paths.uniq.sort
      end

      def read_corpus(path)
        flags = File::NONBLOCK if File::ALT_SEPARATOR.nil? && defined?(File::NONBLOCK)
        File.open(path, "rb", flags: flags || 0) do |file|
          raise ArgumentError, "profile input is not a regular file: #{path}" unless file.stat.file?

          file.read
        end
      end

      def projection_lexer(parsed, backend, options)
        effects = parsed.rules.map { |rule| ActionEffects.for_rule(rule) }
        recorder = method(:record_match)
        opaque = -> { @opaque_matches += 1 }
        machines = @compiled.machines.transform_values do |machine|
          machine.dup.tap { |copy| copy.whole_tokens = nil }
        end
        rules = @compiled.rules.map(&:dup)
        klass = Class.new(Lexer) do
          define_method(:execute) do |rule|
            dfa = machines.fetch(@state).dfa
            start = __flexr_dfa_start(dfa, @match_start, @match_start)
            recorder.call(@state, dfa, start, @buffer, @match_start, @match_end, rule.index)
            if (effect = effects.fetch(rule.index))
              effect.state_operations.each { |operation, *arguments| public_send(operation, *arguments) }
            else
              opaque.call
            end
          end
          private :execute
        end
        Generated.install!(klass, rules: [], backend: backend, encoding: parsed.config.fetch(:encoding),
                           options: options.merge(accel: :none), states: parsed.states.keys - [:initial],
                           inclusive_states: parsed.states.transform_values { |state| state.fetch(:inclusive) })
        klass.__flexr_rules.concat(rules)
        klass.__flexr_set_compiled!(Automaton::CompiledSpec.new(**@compiled.to_h, machines: machines, rules: rules))
        klass
      end

      def record_match(name, dfa, state, buffer, starting, ending, rule)
        length = ending - starting
        first_byte = buffer.getbyte(starting) if length.positive?
        @tokens += 1
        @rules[name][rule].record(length)
        @first_bytes[name][first_byte].record(length) if first_byte
        visits = @states[name]
        stats = visits[state]
        stats.arrivals += 1
        stats.visits += 1
        stats.first_bytes[first_byte] = true
        length_in_loop = 0
        (starting...ending).each do |position|
          target = dfa.transition(state, buffer.getbyte(position))
          if target == state
            length_in_loop += 1
          else
            record_loop(stats, length_in_loop)
            length_in_loop = 0
            state = target
            stats = visits[state]
            stats.arrivals += 1
            stats.first_bytes[first_byte] = true
          end
          stats.visits += 1
        end
        record_loop(stats, length_in_loop)
      end

      def record_loop(stats, length)
        stats.loop_bytes += length
        stats.longest_loop = [stats.longest_loop, length].max
      end

      def select_strategies(encoding, options)
        return unless options.fetch(:accel, :auto) == :auto && !options[:allow_empty_match]
        return if @compiled.machines.values.any? { |machine| machine.dfa.starts || machine.dfa.lookahead? }

        @compiled.machines.sort.each do |name, machine|
          next unless @states.key?(name)
          next if options[:shortest_states]&.include?(name)

          dfa = machine.dfa
          rules = dfa.rule_ids.map { |id| @compiled.rules.fetch(id) }
          next if dfa.context_dependent_end? || rules.any?(&:trailing) || rules.any?(&:capture_patterns)
          next if rules.any? { |rule| rule.pattern_conditions.any? { |condition| !condition || condition.bol_only || condition.end_anchor } }

          select_whole_tokens(name, dfa, rules)
          select_loops(name, machine, encoding)
        end
      end

      def select_whole_tokens(name, dfa, rules)
        plans = Automaton::Accel.whole_token_plans(dfa, rules)
        return unless plans

        selected = @first_bytes[name].sort.filter_map do |byte, stats|
          plan = plans[byte]
          next unless plan && stats.matches >= MIN_SAMPLES && stats.bytes >= stats.matches * MIN_RUN_BYTES

          [byte, plan]
        end.to_h
        @whole_tokens[name] = selected unless selected.empty?
      end

      def select_loops(name, machine, encoding)
        dfa = machine.dfa
        selected = @states[name].sort.filter_map do |state, visits|
          next unless visits.hot_loop?
          next if @whole_tokens[name] && visits.first_bytes.each_key.all? { |byte| @whole_tokens[name].key?(byte) }
          next if machine.backup_memo_states&.[](state) || machine.backup_recovery_states&.[](state)

          bytes = Automaton::Accel.self_loop_set(dfa, state)
          if encoding == Encoding::BINARY && bytes.length == 255
            [state, ((0..255).to_a - bytes).first.chr(Encoding::BINARY)]
          elsif !bytes.empty? && bytes.last < 128
            [state, Automaton::Accel.regexp_for(bytes, binary: false)]
          end
        end.to_h
        @loops[name] = selected unless selected.empty?
      end
    end
  end
end
