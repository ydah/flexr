# frozen_string_literal: true

require_relative "../byte_class_set"

module Flexr
  module Automaton
    module TokenDiff
      class Firstmatch
        Program = Data.define(:instructions, :entry, :condition, :rule)
        Proposal = Data.define(:candidate, :eligible)
        Span = Data.define(:address, :state)
        Slot = Data.define(:active, :proposal)
        Scan = Data.define(:slots) do
          def settled? = slots.all? { |slot| slot.active.empty? }

          def endpoints = slots.filter_map { |slot| slot.proposal&.candidate&.end_pos }

          def with_endpoint_ranks(ranks)
            self.class.new(slots: slots.map do |slot|
              next slot unless (proposal = slot.proposal)

              candidate = proposal.candidate
              slot.with(proposal: proposal.with(candidate: candidate.with(end_pos: ranks.fetch(candidate.end_pos))))
            end)
          end
        end

        OPCODES = %i[accept byte choice loop loop_end line_end not_lf predicate context_predicate left_anchor span].freeze
        private_constant :Program, :Proposal, :Slot, :Scan, :Span, :OPCODES

        attr_reader :labels, :graphs, :byte_classes

        def initialize(rules, encoding)
          @encoding = encoding
          @programs = []
          @groups = rules.map do |rule|
            rule.patterns.each_index.map do |index|
              @programs.length.tap { @programs << program_for(rule, index) }
            end
          end
          @labels = @programs.map(&:condition)
          @graphs = []
          spans = []
          classes = ByteClassSet.new
          @programs.each do |program|
            program.instructions.each do |kind, first, second, following|
              case kind
              when :byte then classes.add_range(first, second)
              when :predicate then @labels << first
              when :context_predicate
                @labels.concat(first.compact)
                @graphs << following if following
                @left_sensitive = true
              when :left_anchor then @left_sensitive = @track_edge = true
              when :line_end, :not_lf then @track_edge = true
              when :span then spans << first
              end
            end
          end
          spans.uniq!
          @labels.concat(spans.flat_map { |dfa| dfa.accepts.flatten })
          @graphs.concat(spans.filter_map(&:left_context))
          @left_sensitive ||= spans.any?(&:starts)
          @byte_classes = [classes.build.first, *spans.map(&:ec)]
        end

        def left_sensitive? = @left_sensitive
        def track_edge? = @track_edge

        def start(bol)
          Scan.new(slots: @programs.map do |program|
            active = program.entry && (bol || !program.condition.bol_only) ? [program.entry] : []
            Slot.new(active: active, proposal: nil)
          end)
        end

        def advance(scan, pos, byte, right, graph_ids, &)
          Scan.new(slots: scan.slots.each_with_index.map do |slot, index|
            next slot if slot.active.empty?

            advance_slot(@programs.fetch(index), slot, pos, byte, right, graph_ids, &)
          end)
        end

        def winner(scan)
          @groups.each do |indices|
            best = indices.filter_map { |index| scan.slots.fetch(index).proposal }.max_by { |proposal| proposal.candidate.end_pos }
            return best.candidate if best&.eligible
          end
          nil
        end

        private

        def program_for(rule, index)
          pattern = rule.patterns.fetch(index)
          ordered = rule.contextual_patterns&.[](index)
          raise UnsupportedFirstmatch, "firstmatch pattern #{pattern.inspect} has no ordered program" unless ordered
          replay_encoding = ordered.regexp.encoding
          raise UnsupportedFirstmatch, "firstmatch pattern #{pattern.inspect} has #{replay_encoding} replay encoding on #{@encoding} input" unless
            [Encoding::US_ASCII, @encoding].include?(replay_encoding)

          unsupported = ordered.instructions.find { |kind, *| !OPCODES.include?(kind) }
          raise UnsupportedFirstmatch, "firstmatch pattern #{pattern.inspect} uses #{unsupported.first}" if unsupported

          Program.new(instructions: ordered.instructions, entry: ordered.entry,
                      condition: rule.pattern_conditions.fetch(index), rule: rule)
        end

        def advance_slot(program, slot, pos, byte, right, graph_ids)
          pending = slot.active.reverse.map { |address| [address, 0] }
          seen = {}
          active = []
          proposal = slot.proposal
          until pending.empty?
            address, idle_loops = pending.pop
            while address
              key = [address, idle_loops]
              break if seen[key]

              seen[key] = true
              span = address.is_a?(Span) ? address : nil
              pc = span ? span.address : address
              kind, first, second, following = program.instructions.fetch(pc)
              case kind
              when :accept
                eligible = pos.utf8.zero? && right.accepts?(program.condition.end_anchor, pos.right)
                candidate, eligible = yield(program.rule, eligible)
                proposal = Proposal.new(candidate: candidate, eligible: eligible)
                pending.clear
                break
              when :byte
                active << following if following && byte&.between?(first, second)
                break
              when :span
                state = span ? span.state : span_start(first, pos.left, graph_ids)
                target = byte && first.transition(state, byte)
                active << Span.new(address: pc, state: target) if target
                break unless first.accepts.fetch(state).any? { |label| right.accepts?(label.end_anchor, pos.right) }

                address = second
              when :choice, :loop
                pending << [second, idle_loops]
                idle_loops += 1 if kind == :loop
                address = first
              when :loop_end
                address = idle_loops.zero? ? first : second
                idle_loops -= 1 unless idle_loops.zero?
              when :line_end
                break unless right.accepts?(true, pos.right)

                address = first
              when :not_lf
                break unless right.accepts?(EndContext::EOF | EndContext::OTHER, pos.right)

                address = first
              when :predicate
                break unless right.accepts?(first.end_anchor, pos.right)

                address = second
              when :context_predicate
                context = following ? pos.left.fetch(graph_ids.fetch(following) + 1) : pos.left.first
                label = first.fetch(context)
                break unless label && right.accepts?(label.end_anchor, pos.right)

                address = second
              when :left_anchor
                context = pos.left.first
                break unless context == LeftContext::SOURCE_START ||
                  (first == :line_start && context == LeftContext::AFTER_LF && !right.accepts?(EndContext::EOF, pos.right))

                address = second
              end
            end
          end
          Slot.new(active: active.uniq, proposal: proposal)
        end

        def span_start(dfa, left, graph_ids)
          return dfa.start unless dfa.starts

          graph = dfa.left_context
          context = graph ? left.fetch(graph_ids.fetch(graph) + 1) : left.first
          dfa.start_for(context)
        end
      end
    end
  end
end
