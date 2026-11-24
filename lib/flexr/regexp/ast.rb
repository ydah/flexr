# frozen_string_literal: true

module Flexr
  module Regexp
    module AST
      Empty = Struct.new(:loc, keyword_init: true)
      Fail = Struct.new(:loc, keyword_init: true)
      ByteRange = Struct.new(:lo, :hi, :loc, keyword_init: true)
      CodepointRange = Struct.new(:lo, :hi, :loc, keyword_init: true)
      Seq = Struct.new(:children, :loc, keyword_init: true)
      Alt = Struct.new(:children, :loc, keyword_init: true)
      Star = Struct.new(:child, :loc, keyword_init: true)
      Repeat = Struct.new(:child, :minimum, :maximum, :loc, keyword_init: true)
      Absence = Struct.new(:child, :loc, keyword_init: true)
      Difference = Struct.new(:left, :right, :loc, :operation, keyword_init: true)
      Intersection = Struct.new(:left, :right, :loc, keyword_init: true)
      EmbeddedDFA = Struct.new(:dfa)
      FirstEnding = Struct.new(:child)
      ByteAutomaton = Struct.new(:fragment)
      NamedCapture = Struct.new(:opening, :child, keyword_init: true)
      Anchor = Struct.new(:kind, :loc, keyword_init: true)
      NotNextLineFeed = Struct.new(:loc, keyword_init: true)
      Lookahead = Struct.new(:child, :negative, :loc, keyword_init: true)
      TrailMark = Struct.new(:rule_id, :loc, keyword_init: true)
      CharClass = Struct.new(:ranges, :negated, :loc, keyword_init: true)
      Property = Module.new

      module Formatting
        def to_s
          name = self.class.name.split("::").last
          case name
          when "Empty", "Fail", "NotNextLineFeed" then name
          when "ByteRange" then "ByteRange(#{lo}..#{hi})"
          when "CodepointRange" then "CodepointRange(#{lo}..#{hi})"
          when "Anchor" then "Anchor(#{kind})"
          when "Star", "Absence", "Lookahead" then "#{name}(#{child})"
          when "Repeat" then "Repeat(#{child}, #{minimum}, #{maximum || '∞'})"
          when "Seq", "Alt" then "#{name}(#{children.join(', ')})"
          when "Difference", "Intersection" then "#{name}(#{left}, #{right})"
          else super
          end
        end
      end

      [Empty, Fail, ByteRange, CodepointRange, Seq, Alt, Star, Repeat, Absence, Difference, Intersection,
       Anchor, NotNextLineFeed, Lookahead, TrailMark, CharClass].each do |node_class|
        node_class.include(Formatting)
      end

      def self.absence?(node)
        case node
        when Absence then true
        when Seq, Alt then node.children.any? { |child| absence?(child) }
        when Star, Repeat, Lookahead, NamedCapture then absence?(node.child)
        else false
        end
      end

      def self.anchors(node)
        case node
        when Anchor then [node]
        when Seq, Alt then node.children.flat_map { |child| anchors(child) }
        when Star, Repeat, Absence, Lookahead, NamedCapture then anchors(node.child)
        else []
        end
      end

      def self.left_anchor?(node)
        node.is_a?(Anchor) && %i[source_start line_start].include?(node.kind)
      end

      def self.contextual?(node)
        case node
        when Lookahead then true
        when Anchor then node.kind != :bol && node.kind != :eol
        when Seq, Alt then node.children.any? { |child| contextual?(child) }
        when Star, Repeat, Absence, NamedCapture then contextual?(node.child)
        else false
        end
      end

      def self.lookahead?(node)
        case node
        when Lookahead then true
        when Seq, Alt then node.children.any? { |child| lookahead?(child) }
        when Star, Repeat, Absence, NamedCapture then lookahead?(node.child)
        else false
        end
      end

      def self.named_capture?(node)
        case node
        when NamedCapture then true
        when Seq, Alt then node.children.any? { |child| named_capture?(child) }
        when Star, Repeat, Absence, Lookahead then named_capture?(node.child)
        when Difference, Intersection then named_capture?(node.left) || named_capture?(node.right)
        else false
        end
      end

      def self.next_byte_assertion?(node)
        case node
        when NotNextLineFeed then true
        when Seq, Alt then node.children.any? { |child| next_byte_assertion?(child) }
        when Star, Repeat, Absence, Lookahead, NamedCapture then next_byte_assertion?(node.child)
        else false
        end
      end

      def self.nullable?(node)
        case node
        when Empty, Anchor, NotNextLineFeed, Lookahead, Star then true
        when Repeat then node.minimum.zero? || nullable?(node.child)
        when NamedCapture then nullable?(node.child)
        when Seq then node.children.all? { |child| nullable?(child) }
        when Alt then node.children.any? { |child| nullable?(child) }
        when Absence then !nullable?(node.child)
        when Difference then nullable?(node.left) && !nullable?(node.right)
        when Intersection then nullable?(node.left) && nullable?(node.right)
        else false
        end
      end

      class Node
        attr_reader :loc

        def initialize(loc = nil)
          @loc = loc
        end
      end
    end
  end
end
