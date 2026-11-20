# frozen_string_literal: true

module Flexr
  module Runtime
    module Record
      def [](key)
        member = key.is_a?(Integer) ? members.fetch(key) : key.to_sym
        raise NameError, "unknown record member #{key.inspect}" unless members.include?(member)

        public_send(member)
      end
    end
  end
end
