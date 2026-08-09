# frozen_string_literal: true

module Flexr
  module Regexp
    module AST
      Empty = Struct.new(:loc, keyword_init: true)
      ByteRange = Struct.new(:lo, :hi, :loc, keyword_init: true)
      CodepointRange = Struct.new(:lo, :hi, :loc, keyword_init: true)
      Seq = Struct.new(:children, :loc, keyword_init: true)
      Alt = Struct.new(:children, :loc, keyword_init: true)
      Star = Struct.new(:child, :loc, keyword_init: true)
      Anchor = Struct.new(:kind, :loc, keyword_init: true)
      TrailMark = Struct.new(:rule_id, :loc, keyword_init: true)
      CharClass = Struct.new(:ranges, :negated, :loc, keyword_init: true)
      Property = Module.new

      module Formatting
        def to_s
          name = self.class.name.split("::").last
          case name
          when "Empty" then "Empty"
          when "ByteRange" then "ByteRange(#{lo}..#{hi})"
          when "CodepointRange" then "CodepointRange(#{lo}..#{hi})"
          when "Anchor" then "Anchor(#{kind})"
          when "Star" then "Star(#{child})"
          when "Seq", "Alt" then "#{name}(#{children.map(&:to_s).join(", ")})"
          else super
          end
        end
      end

      [Empty, ByteRange, CodepointRange, Seq, Alt, Star, Anchor, TrailMark, CharClass].each do |node_class|
        node_class.include(Formatting)
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
