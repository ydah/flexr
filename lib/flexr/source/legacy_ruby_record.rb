# frozen_string_literal: true

module Flexr
  module LegacyRubyRecord
    def self.define(*members, &definition)
      structure = Struct.new(*members)
      structure.undef_method(:[]=, *members.map { |member| :"#{member}=" })

      record = Class.new(structure) do
        define_method(:initialize) do |**fields|
          unknown = fields.keys - members
          raise ArgumentError, "unknown record members: #{unknown.join(', ')}" unless unknown.empty?

          super(*members.map { |member| fields.fetch(member) })
          freeze
        end

        def initialize_copy(other)
          super
          freeze
        end

        alias_method :deconstruct, :to_a

        def deconstruct_keys(keys)
          values = members.zip(to_a).to_h
          keys ? values.slice(*keys) : values
        end

        def with(**changes)
          changes.empty? ? self : self.class.new(**to_h, **changes)
        end
      end

      record.define_singleton_method(:new) do |*values, **fields|
        unless values.empty?
          raise ArgumentError, "wrong number of record values" unless fields.empty? && values.size == members.size

          fields = members.zip(values).to_h
        end
        super(**fields)
      end
      record.class_eval(&definition) if definition
      record
    end
  end
end
