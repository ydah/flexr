# frozen_string_literal: true

module Flexr
  module Deprecations
    module_function

    def warn(message)
      Kernel.warn("flexr deprecated: #{message}", category: :deprecated, uplevel: 2)
    end

    def record_mutations(record)
      record.prepend(Module.new do
        record.members.each do |member|
          define_method("#{member}=") do |value|
            Deprecations.warn("#{record.name} becomes immutable in 2.0; replace the record instead of mutating it")
            super(value)
          end
        end
        define_method(:[]=) do |key, value|
          Deprecations.warn("#{record.name} becomes immutable in 2.0; replace the record instead of mutating it")
          super(key, value)
        end
      end)
    end
  end
end
