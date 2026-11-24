# frozen_string_literal: true

require_relative "../runtime"
require_relative "tagged_dfa"

module Flexr
  module Automaton
    class TaggedCompiler
      MAX_REGISTERS = 128
      MAX_STATES = 4096
      MAX_WORK = 500_000
      MAX_INSTRUCTIONS = 16_384
      AST = Regexp::AST
      PENDING_POSITION = :pending_position
      Result = Data.define(:program, :reason)
      private_constant :AST, :PENDING_POSITION

      def self.compile(regexp, encoding: Encoding::UTF_8, unicode: false, max_registers: MAX_REGISTERS, max_states: MAX_STATES)
        outcome = catch(:tagged_compile_limit) do
          new(max_registers, max_states).compile(regexp, encoding, unicode)
        end
        if outcome.is_a?(Symbol)
          Result.new(program: nil, reason: outcome)
        else
          Result.new(program: outcome, reason: nil)
        end
      rescue CompileError, EncodingError
        Result.new(program: nil, reason: :unsupported_pattern)
      rescue SystemStackError
        Result.new(program: nil, reason: :state_limit)
      end

      def initialize(max_registers, max_states)
        @max_registers = max_registers
        @max_states = max_states
        @register_count = 0
        @states = []
        @ids = {}
        @instructions = []
        @byte_classes = ByteClassSet.new
        @loop_count = 0
        @work = MAX_WORK
      end

      def compile(regexp, subject_encoding, unicode)
        encoding = regexp.encoding == Encoding::BINARY ? Encoding::BINARY : subject_encoding
        ast = Regexp::Parser.new(regexp.source, options: regexp.options, encoding: encoding, unicode: unicode,
                                preserve_captures: true).parse
        groups = regexp.names.to_h { |name| [name.freeze, []] }
        @group_count = 0
        number_groups(ast, groups)
        tree = Regexp::Normalizer.new(ast, encoding: encoding, subject_encoding: subject_encoding, options: regexp.options).normalize
        @accept = append(:accept)
        root = lower(tree, @accept)
        ec, class_count = @byte_classes.build
        remember(closure([[root, Array.new(2 * @group_count).freeze, 0, 0, 0, 0]]).freeze)
        transitions = []
        acceptances = []
        @states.each do |configs|
          acceptance = configs.find { |address, _, _| address == @accept }
          acceptances << (resolve(acceptance[1], acceptance[2]) if acceptance)
          transitions << transitions_for(configs, ec, class_count)
        end
        TaggedDFA.new(byte_classes: ec, transitions: transitions.freeze, acceptances: acceptances.freeze,
                      groups: groups.transform_values(&:freeze).freeze, register_count: @register_count, encoding: encoding)
      end

      private

      def number_groups(node, groups)
        charge
        case node
        when AST::NamedCapture
          name = node.opening[1...-1]
          groups.fetch(name) << @group_count
          node.opening = @group_count
          @group_count += 1
          throw :tagged_compile_limit, :register_limit if 2 * @group_count > @max_registers

          number_groups(node.child, groups)
        when AST::Seq, AST::Alt
          node.children.each { |child| number_groups(child, groups) }
        when AST::Star, AST::Repeat
          number_groups(node.child, groups)
        when AST::Anchor, AST::Lookahead, AST::Lookbehind, AST::WordBoundary, AST::NotNextLineFeed
          throw :tagged_compile_limit, :unsupported_context
        when AST::Absence, AST::Grapheme
          throw :tagged_compile_limit, :unsupported_pattern
        end
      end

      def lower(node, following)
        return unless following

        case node
        when AST::Empty then following
        when AST::Fail then nil
        when AST::ByteRange then byte_edge(node.lo, node.hi, following)
        when AST::Seq then node.children.reverse_each.reduce(following) { |tail, child| lower(child, tail) }
        when AST::Alt then node.children.reverse_each.reduce(nil) { |tail, child| choice(lower(child, following), tail) }
        when AST::NamedCapture then capture(node, following)
        when AST::Star then repeat(node.child, 0, nil, following)
        when AST::Repeat then repeat(node.child, node.minimum, node.maximum, following)
        when AST::ByteAutomaton then property_fragment(node.fragment, following)
        else throw :tagged_compile_limit, :unsupported_pattern
        end
      end

      def capture(node, following)
        capture_index = 2 * node.opening
        ending = append(:tag, 1 << (capture_index + 1), following)
        inner = lower(node.child, ending)
        append(:open_capture, capture_index, inner) if inner
      end

      def repeat(child, minimum, maximum, following)
        nullable = AST.nullable?(child)
        if nullable && (maximum ? maximum > 1 : minimum > 1)
          # shortcut: use replay until the compiler models Ruby’s capture-sensitive empty-iteration checks.
          throw :tagged_compile_limit, :nullable_repetition
        end

        tail = if maximum
          (maximum - minimum).times.reduce(following) { |next_iteration, _| choice(lower(child, next_iteration), following) }
        else
          @capture_sensitive ||= nullable && AST.named_capture?(child)
          loop_entry(child, following, nullable)
        end
        minimum.times.reduce(tail) { |next_iteration, _| lower(child, next_iteration) }
      end

      def loop_entry(child, following, nullable)
        if nullable
          flag = 1 << @loop_count
          @loop_count += 1
          loop_head = append(:loop, nil, following, flag)
          loop_end = append(:loop_end, loop_head, following, flag)
          @instructions.fetch(loop_head)[1] = lower(child, loop_end)
        else
          loop_head = append(:split, nil, following)
          @instructions.fetch(loop_head)[1] = lower(child, loop_head)
        end
        loop_head
      end

      def property_fragment(fragment, following)
        entries = Array.new(fragment.state_count) { append(:jump, nil) }
        choices = Array.new(fragment.state_count)
        choices[fragment.accept] = following
        fragment.edges.each_slice(4) do |from, lo, hi, to|
          choices[from] = choice(byte_edge(lo, hi, entries.fetch(to)), choices.fetch(from))
        end
        entries.each_with_index { |entry, index| @instructions.fetch(entry)[1] = choices.fetch(index) }
        entries.first
      end

      def choice(first, second)
        return second unless first
        return first unless second

        append(:split, first, second)
      end

      def byte_edge(lo, hi, following)
        @byte_classes.add_range(lo, hi)
        append(:byte, lo, hi, following)
      end

      def append(*instruction)
        throw :tagged_compile_limit, :state_limit if @instructions.length >= MAX_INSTRUCTIONS

        @instructions.push(instruction).length - 1
      end

      def closure(origins)
        pending = origins.reverse
        seen = {}
        terminals = []
        until pending.empty?
          address, values, tags, empty_loops, changed, moved = pending.pop
          next unless address

          charge
          kind, first, second, third = @instructions.fetch(address)
          key = closure_key(address, kind, values, tags, empty_loops, changed, moved)
          next if seen[key]

          seen[key] = true
          case kind
          when :byte, :accept
            terminals << [address, values, tags].freeze
          when :jump
            pending << [first, values, tags, empty_loops, changed, moved]
          when :tag
            pending << [second, values, tags | first, empty_loops, changed, moved]
          when :open_capture
            unless empty_loops.zero?
              start = tag_value(values, tags, first)
              ending = tag_value(values, tags, first + 1)
              if ending.nil? || start != ending
                changed |= empty_loops
              elsif ending != PENDING_POSITION
                moved |= empty_loops
              end
            end
            pending << [second, values, tags | (1 << first), empty_loops, changed, moved]
          when :split
            pending << [second, values, tags, empty_loops, changed, moved] <<
              [first, values, tags, empty_loops, changed, moved]
          when :loop
            pending << [second, values, tags, empty_loops, changed, moved] <<
              [first, values, tags, empty_loops | third, changed, moved]
          when :loop_end
            if empty_loops.anybits?(third) && changed.nobits?(third)
              next if moved.anybits?(third)

              target = second
            else
              target = first
            end
            pending << [target, values, tags, empty_loops & ~third, changed & ~third, moved & ~third]
          end
        end
        terminals
      end

      def closure_key(address, kind, values, tags, empty_loops, changed, moved)
        return address if kind == :accept
        if kind == :byte
          return @capture_sensitive ? [address, capture_status(values, tags, before_byte: true)] : address
        end

        if @capture_sensitive
          [address, capture_status(values, tags), empty_loops, changed, moved]
        else
          [address, empty_loops]
        end
      end

      def capture_status(values, tags, before_byte: false)
        charge(@group_count)
        status = 0
        @group_count.times do |group|
          start = tag_value(values, tags, 2 * group)
          ending = tag_value(values, tags, (2 * group) + 1)
          flags = ending && ending == start ? 1 : 0
          unless before_byte
            flags |= 2 if start == PENDING_POSITION
            flags |= 4 if ending == PENDING_POSITION
          end
          status |= flags << (3 * group)
        end
        status
      end

      def tag_value(values, tags, tag)
        tags[tag].positive? ? PENDING_POSITION : values.fetch(tag)
      end

      def resolve(values, tags)
        return values if tags.zero?

        values.each_with_index.map { |register, tag| tags[tag].positive? ? TaggedDFA::POSITION : register }.freeze
      end

      def transitions_for(configs, ec, class_count)
        charge(class_count)
        origins_by_class = Array.new(class_count)
        configs.each do |address, values, tags|
          charge
          kind, lo, hi, following = @instructions.fetch(address)
          next unless kind == :byte

          classes = ec.fetch(lo)..ec.fetch(hi)
          charge(classes.size)
          origin = [following, resolve(values, tags), 0, 0, 0, 0]
          classes.each { |class_id| (origins_by_class[class_id] ||= []) << origin }
        end
        compiled = {}
        origins_by_class.map do |origins|
          compiled.fetch(origins) { compiled[origins] = step(origins) } if origins
        end.freeze
      end

      def step(origins)
        following = closure(origins)
        return if following.empty?

        # Register ids belong to a state. Renumber equal source values before interning the successor.
        sources = {}
        canonical = following.map do |address, values, tags|
          charge(values.length)
          registers = values.map do |source|
            sources[source] ||= sources.length unless source.nil?
          end
          [address, registers.freeze, tags].freeze
        end.freeze
        moves = sources.keys
        throw :tagged_compile_limit, :register_limit if moves.length > @max_registers

        @register_count = [@register_count, moves.length].max
        transfer = moves.freeze unless moves.each_with_index.all? { |source, destination| source == destination }
        [remember(canonical), transfer].freeze
      end

      def remember(configs)
        @ids[configs] ||= begin
          throw :tagged_compile_limit, :state_limit if @states.length >= @max_states

          @states.push(configs).length - 1
        end
      end

      def charge(amount = 1)
        @work -= amount
        throw :tagged_compile_limit, :state_limit if @work.negative?
      end
    end
  end
end
