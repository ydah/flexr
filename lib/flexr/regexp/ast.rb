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
      Difference = Struct.new(:left, :right, :loc, keyword_init: true)
      Anchor = Struct.new(:kind, :loc, keyword_init: true)
      TrailMark = Struct.new(:rule_id, :loc, keyword_init: true)
      CharClass = Struct.new(:ranges, :negated, :loc, keyword_init: true)
      Property = Module.new

      module Formatting
        def to_s
          name = self.class.name.split("::").last
          case name
          when "Empty", "Fail" then name
          when "ByteRange" then "ByteRange(#{lo}..#{hi})"
          when "CodepointRange" then "CodepointRange(#{lo}..#{hi})"
          when "Anchor" then "Anchor(#{kind})"
          when "Star", "Absence" then "#{name}(#{child})"
          when "Repeat" then "Repeat(#{child}, #{minimum}, #{maximum || '∞'})"
          when "Seq", "Alt" then "#{name}(#{children.join(', ')})"
          when "Difference" then "Difference(#{left}, #{right})"
          else super
          end
        end
      end

      [Empty, Fail, ByteRange, CodepointRange, Seq, Alt, Star, Repeat, Absence, Difference,
       Anchor, TrailMark, CharClass].each do |node_class|
        node_class.include(Formatting)
      end

      def self.absence?(node)
        case node
        when Absence then true
        when Seq, Alt then node.children.any? { |child| absence?(child) }
        when Star, Repeat then absence?(node.child)
        else false
        end
      end

      def self.nullable?(node)
        case node
        when Empty, Anchor, Star then true
        when Repeat then node.minimum.zero? || nullable?(node.child)
        when Seq then node.children.all? { |child| nullable?(child) }
        when Alt then node.children.any? { |child| nullable?(child) }
        when Absence then !nullable?(node.child)
        when Difference then nullable?(node.left) && !nullable?(node.right)
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
