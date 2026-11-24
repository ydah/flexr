# frozen_string_literal: true

require_relative "token_diff/right_context"
require_relative "token_diff/utf8"
require_relative "token_diff/firstmatch"
require_relative "token_diff/inclusion"

module Flexr
  module Automaton
    module TokenDiff
      Side = Data.define(:dfa, :rules, :effects, :keyword_effects, :allow_empty_match)
      FirstmatchSide = Data.define(:rules, :effects, :keyword_effects)
      Match = Data.define(:rule_index, :effect, :length)
      Result = Data.define(:status, :input, :offset, :left, :right, :reason)

      BYTE_ORDER = ((32..126).to_a + (0..31).to_a + (127..255).to_a).freeze
      Candidate = Data.define(:rule_index, :effect, :end_pos)
      Scan = Data.define(:state, :pending, :winner) do
        def settled? = state.nil? && pending.empty?

        def endpoints = [winner&.end_pos, *pending.values.map(&:end_pos)].compact

        def with_endpoint_ranks(ranks)
          ranked_winner = winner&.with(end_pos: ranks.fetch(winner.end_pos))
          ranked_pending = pending.transform_values { |candidate| candidate.with(end_pos: ranks.fetch(candidate.end_pos)) }
          with(winner: ranked_winner, pending: ranked_pending)
        end
      end
      Position = Data.define(:right, :utf8, :left, :keyword, :bol, :scans)
      Path = Data.define(:position, :parent, :byte, :length, :offset)
      class SearchLimit < StandardError; end
      class UnsupportedFirstmatch < StandardError; end

      module_function

      def compare(left, right, encoding:, limit: 100_000)
        Search.new([left, right], encoding, limit).compare
      rescue SearchLimit
        Result.new(status: :inconclusive, input: nil, offset: nil, left: nil, right: nil, reason: "search limit reached")
      rescue UnsupportedFirstmatch => e
        Result.new(status: :inconclusive, input: nil, offset: nil, left: nil, right: nil, reason: e.message)
      end

      def overlap(side, tokens:, encoding:, limit: 100_000)
        raise ArgumentError, "overlap requires two distinct token kinds" unless tokens.size == 2 && tokens.uniq.size == 2

        result = OverlapSearch.new(side, tokens, encoding, limit).compare
        return result unless result.status == :equal && side.dfa.rule_ids.any? { |id| side.effects[id].nil? }

        result.with(status: :inconclusive, reason: "a rule in this state has an opaque action")
      rescue SearchLimit
        Result.new(status: :inconclusive, input: nil, offset: nil, left: nil, right: nil, reason: "search limit reached")
      end

      class Search
        def initialize(sides, encoding, limit)
          @sides = sides
          @encoding = encoding
          @limit = limit
          @utf8_rows = UTF8.rows(encoding)
          @paths = []
          @visited = {}
          @scan_roots = {}
        end

        def compare
          return outcome(:inconclusive, reason: "unsupported input encoding") unless @utf8_rows

          @ordered = @sides.map { |side| Firstmatch.new(side.rules, @encoding) if side.is_a?(FirstmatchSide) }
          trails = @sides.flat_map do |side|
            rules = side.is_a?(FirstmatchSide) ? side.rules : side.dfa.rule_ids.map { |index| side.rules.fetch(index) }
            rules.filter_map do |rule|
              next unless rule.trailing

              return outcome(:inconclusive, reason: "trailing context has no DFA") unless rule.trailing_dfa

              rule.trailing_dfa
            end
          end.uniq
          bodies = @sides.grep(Side).map(&:dfa)
          dfas = bodies | trails
          firstmatch = @ordered.compact
          @graphs = (dfas.filter_map(&:left_context) + firstmatch.flat_map(&:graphs)).uniq
          @graph_ids = @graphs.each_with_index.to_h
          body_labels = bodies.flat_map { |dfa| dfa.accepts.flatten } + firstmatch.flat_map(&:labels)
          trailing_labels = trails.flat_map { |dfa| dfa.accepts.flatten }
          @body_bol = body_labels.any?(&:bol_only)
          @scan_left = trails.any?(&:starts) || trailing_labels.any?(&:bol_only) || firstmatch.any?(&:left_sensitive?)
          @left_sensitive = bodies.any?(&:starts) || @body_bol || @scan_left
          labels = body_labels + trailing_labels
          @right = RightContext.new(labels, @utf8_rows, track_edge: firstmatch.any?(&:track_edge?), prefix_dfas: prefix_dfas(trails))
          build_keywords

          bytes = alphabet(dfas)
          @right.build(bytes, @limit)
          @initial_rights = @right.initial
          left = [LeftContext::SOURCE_START, *Array.new(@graphs.length, 0)] if @left_sensitive
          frontier = []
          pos = Position.new(right: nil, utf8: 0, left: left, keyword: nil, bol: nil, scans: nil)
          enqueue(Path.new(position: pos, parent: nil, byte: nil, length: 0, offset: nil), frontier)

          opaque = false
          until frontier.empty?
            frontier.each do |id|
              path = @paths.fetch(id)
              pos = path.position
              if !pos.scans
                start_scan(path, id, frontier) if pos.utf8.zero?
              elsif pos.right.zero? && pos.utf8.zero?
                candidates = winners(resolve(path, eof: true))
                return witness(id, candidates) if different?(candidates)

                opaque ||= candidates.any? { |candidate| candidate && candidate.effect.nil? }
              end
            end
            following = []
            frontier.each do |id|
              path = @paths.fetch(id)
              advance(path, id, bytes, following) if path.position.scans || @left_sensitive
            end
            frontier = following
          end

          return outcome(:inconclusive, reason: "a winning rule has an opaque action") if opaque

          outcome(:equal)
        end

        private

        def outcome(status, reason: nil)
          Result.new(status: status, input: nil, offset: nil, left: nil, right: nil, reason: reason)
        end

        def prefix_dfas(_trails)
          @sides.grep(FirstmatchSide).flat_map { |side| side.rules.filter_map(&:trailing_dfa) }.uniq
        end

        def build_keywords
          @keyword_rows = [{}]
          @keyword_spellings = {}
          @keyword_effects = @sides.map do |side|
            side.keyword_effects.transform_values do |effects|
              effects.to_h do |text, effect|
                state = 0
                spelling = text.b
                spelling.each_byte do |byte|
                  state = @keyword_rows.fetch(state)[byte] ||= begin
                    id = @keyword_rows.length
                    @keyword_rows << {}
                    id
                  end
                end
                @keyword_spellings[state] = spelling
                [spelling, effect]
              end
            end
          end
          @keyword_bytes = @keyword_rows.flat_map(&:keys).to_h { |byte| [byte, true] }
        end

        def alphabet(dfas)
          byte_classes = dfas.map(&:ec) + @graphs.map(&:ec) + @ordered.compact.flat_map(&:byte_classes)
          BYTE_ORDER.map { |byte| [byte, @right.byte_key(byte)] }.uniq do |byte, key|
            [*byte_classes.map { |row| row.fetch(byte) }, key,
             @left_sensitive && byte == 0x0a, (byte if @keyword_bytes[byte])]
          end
        end

        def start_state(dfa, left)
          return dfa.start unless dfa.starts

          graph = dfa.left_context
          context = graph ? left.fetch(@graph_ids.fetch(graph) + 1) : left.first
          dfa.start_for(context)
        end

        def start_scan(path, id, frontier)
          pos = path.position
          bol = @body_bol && (!pos.left || pos.left.first != LeftContext::OTHER)
          scans = @sides.each_with_index.map do |side, index|
            ordered = @ordered[index]
            ordered ? ordered.start(bol) : Scan.new(state: start_state(side.dfa, pos.left), pending: {}, winner: nil)
          end
          left = pos.left if @scan_left
          start = pos.with(scans: scans, keyword: @keyword_spellings.empty? ? nil : 0, bol: bol, left: left)
          return if @scan_roots[start]

          @scan_roots[start] = true
          @initial_rights.each do |right|
            root = Path.new(position: start.with(right: right), parent: id, byte: nil, length: path.length, offset: path.length)
            enqueue(root, frontier)
          end
        end

        def advance(path, id, bytes, following)
          pos = path.position
          scans = resolve(path, eof: false) if pos.scans
          return if scans && settled_equal?(scans)

          bytes.each do |byte, right_key|
            utf8 = @utf8_rows.fetch(pos.utf8).fetch(byte)
            next unless utf8

            tails = pos.scans ? @right.tails(pos.right, right_key) : [nil]
            next if tails.empty?

            next_scans = scans&.each_with_index&.map do |scan, index|
              next advance_ordered(scan, path, index, byte) if @ordered[index]

              dfa = @sides.fetch(index).dfa
              state = dfa.transition(scan.state, byte) if scan.state
              pending = advance_pending(scan.pending, @sides.fetch(index).rules, byte)
              Scan.new(state: state, pending: pending, winner: scan.winner)
            end
            keyword = pos.keyword && @keyword_rows.fetch(pos.keyword)[byte]
            left = advance_left(pos.left, byte) if pos.left
            tails.each do |right|
              current = pos.with(right: right, utf8: utf8, scans: next_scans, keyword: keyword, left: left)
              enqueue(Path.new(position: current, parent: id, byte: byte, length: path.length + 1, offset: path.offset), following)
            end
          end
        end

        def advance_left(left, byte)
          [LeftContext.after(byte), *@graphs.each_with_index.map { |graph, id| graph.transition(left.fetch(id + 1), byte) }]
        end

        def advance_pending(pending, rules, byte)
          pending.each_with_object({}) do |((index, state, bol), candidate), next_pending|
            target = rules.fetch(index).trailing_dfa.transition(state, byte)
            remember(next_pending, [index, target, bol], candidate) if target
          end
        end

        def resolve(path, eof:)
          pos = path.position
          return pos.scans unless pos.utf8.zero?
          return pos.scans if eof && path.length == path.offset

          @sides.each_with_index.map do |side, index|
            if @ordered[index]
              scan = pos.scans.fetch(index)
              eof ? advance_ordered(scan, path, index, nil) : scan
            else
              resolve_scan(path, side, index)
            end
          end
        end

        def advance_ordered(scan, path, index, byte)
          pos = path.position
          @ordered.fetch(index).advance(scan, pos, byte, @right, @graph_ids) do |rule, eligible|
            if eligible && (dfa = rule.trailing_dfa)
              bol = !pos.left || pos.left.first != LeftContext::OTHER
              eligible = @right.accepts_prefix?(dfa, start_state(dfa, pos.left), bol, pos.right)
            end
            [candidate_at(path, @sides.fetch(index), index, rule.index), eligible]
          end
        end

        def resolve_scan(path, side, index)
          pos = path.position
          scan = pos.scans.fetch(index)
          return scan unless scan.state || !scan.pending.empty?

          candidates = []
          pending = scan.pending.dup
          consuming = path.length > path.offset
          if scan.state && (side.allow_empty_match || consuming)
            side.dfa.accepts.fetch(scan.state).each do |label|
              next unless eligible?(label, pos.bol, pos.right)

              rule = side.rules.fetch(label.rule_index)
              candidate = candidate_at(path, side, index, rule.index)
              if rule.trailing
                bol = !pos.left || pos.left.first != LeftContext::OTHER
                remember(pending, [rule.index, start_state(rule.trailing_dfa, pos.left), bol], candidate)
              else
                candidates << candidate
              end
            end
          end
          pending.each do |(rule, state, bol), candidate|
            label = side.rules.fetch(rule).trailing_dfa.accepts.fetch(state).first
            candidates << candidate if label && eligible?(label, bol, pos.right)
          end
          best = candidates.max_by do |candidate|
            [side.rules.fetch(candidate.rule_index).priority, -candidate.rule_index, candidate.end_pos]
          end
          Scan.new(state: scan.state, pending: pending, winner: best || scan.winner)
        end

        def eligible?(label, bol, right)
          (bol || !label.bol_only) && @right.accepts?(label.end_anchor, right)
        end

        def candidate_at(path, side, index, rule)
          effect = side.effects[rule]
          remaps = @keyword_effects.fetch(index)[rule]
          effect = remaps.fetch(@keyword_spellings[path.position.keyword], effect) if remaps
          Candidate.new(rule_index: rule, effect: effect, end_pos: path.length)
        end

        def remember(pending, key, candidate)
          previous = pending[key]
          pending[key] = candidate unless previous && previous.end_pos >= candidate.end_pos
        end

        def enqueue(path, frontier)
          key = position_key(path)
          return if @visited[key]
          raise SearchLimit if @paths.length >= @limit

          @visited[key] = true
          frontier << @paths.length
          @paths << path
        end

        def position_key(path)
          pos = path.position
          return pos unless pos.scans

          # Only the order and equality of live body ends affect later comparisons.
          ends = pos.scans.flat_map(&:endpoints)
          ranks = ends.uniq.sort.each_with_index.to_h
          scans = pos.scans.map { |scan| scan.with_endpoint_ranks(ranks) }
          [pos.with(scans: scans), path.offset == path.length]
        end

        def settled_equal?(scans)
          return false unless scans.all?(&:settled?)

          left, right = winners(scans)
          return true unless left || right

          left && right && !left.effect.nil? && left.effect == right.effect && left.end_pos == right.end_pos
        end

        def winners(scans)
          scans.each_with_index.map do |scan, index|
            ordered = @ordered[index]
            ordered ? ordered.winner(scan) : scan.winner
          end
        end

        def different?(candidates)
          left, right = candidates
          return false unless left || right
          return true unless left && right
          return true if left.end_pos != right.end_pos

          !left.effect.nil? && !right.effect.nil? && left.effect != right.effect
        end

        def witness(id, candidates)
          offset = @paths.fetch(id).offset
          left, right = candidates.map do |candidate|
            next unless candidate

            Match.new(rule_index: candidate.rule_index, effect: candidate.effect, length: candidate.end_pos - offset)
          end
          bytes = []
          until id.nil?
            path = @paths.fetch(id)
            bytes << path.byte unless path.byte.nil?
            id = path.parent
          end
          input = bytes.reverse.pack("C*").force_encoding(@encoding)
          Result.new(status: :different, input: input, offset: offset, left: left, right: right, reason: nil)
        end
      end

      class OverlapSearch < Search
        def initialize(side, tokens, encoding, limit)
          super([side, side], encoding, limit)
          @side = side
          @tokens = tokens
        end

        private

        def prefix_dfas(trails) = trails

        def resolve(path, eof:)
          pos = path.position
          state = pos.scans.first.state
          return pos.scans unless state && pos.utf8.zero?
          return pos.scans if path.length == path.offset && (eof || !@side.allow_empty_match)

          candidates = {}
          @side.dfa.accepts.fetch(state).each do |label|
            next unless eligible?(label, pos.bol, pos.right)

            candidate = candidate_at(path, @side, 0, label.rule_index)
            effect = candidate.effect
            next unless effect&.action == :emit && @tokens.include?(effect.token)
            next if candidates.key?(effect.token) || !accepts_trailing?(label.rule_index, pos)

            candidates[effect.token] = candidate
          end
          return pos.scans unless @tokens.all? { |token| candidates.key?(token) }

          @tokens.map { |token| Scan.new(state: nil, pending: {}, winner: candidates.fetch(token)) }
        end

        def accepts_trailing?(index, pos)
          rule = @side.rules.fetch(index)
          return true unless rule.trailing

          dfa = rule.trailing_dfa
          bol = !pos.left || pos.left.first != LeftContext::OTHER
          @right.accepts_prefix?(dfa, start_state(dfa, pos.left), bol, pos.right)
        end

        def different?(candidates) = candidates.all?
      end

      private_constant :BYTE_ORDER, :Candidate, :Scan, :Position, :Path, :Search, :OverlapSearch,
                       :SearchLimit, :UnsupportedFirstmatch, :Firstmatch
    end
  end
end
