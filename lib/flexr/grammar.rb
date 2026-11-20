# frozen_string_literal: true

module Flexr
  module Grammar
    module_function

    def tokens(source)
      names = []
      declaration = false
      source.scan(%r{%\{.*?%\}|/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|<[^>]*>|%%|%[a-zA-Z][\w-]*|[a-zA-Z_]\w*|.}m).each do |token|
        break if token == "%%"
        if token.start_with?("%") && !token.start_with?("%{")
          declaration = token == "%token"
        elsif declaration && token.match?(/\A[A-Za-z_]\w*\z/)
          names << token
        end
      end
      names.uniq
    end

    def diagnostics(parsed, path)
      expected = tokens(File.read(path))
      emitted = Array(parsed.config[:declared_tokens]).map(&:to_s)
      location = [parsed.first_dsl_offset, parsed.first_dsl_offset]
      (expected - emitted).map do |name|
        Diagnostics.warning("FLEXR-W017", "grammar token #{name} is not declared by emits",
                            location: location, note: "grammar: #{path}", help: "declare and emit #{name}, or remove it from the grammar")
      end + (emitted - expected).map do |name|
        Diagnostics.warning("FLEXR-W018", "emitted token #{name} is not declared by the grammar",
                            location: location, note: "grammar: #{path}", help: "add a %token declaration or remove #{name} from emits")
      end
    end

    def declarations(tokens)
      names = tokens.map(&:to_s).uniq
      raise ArgumentError, "Lrama token names must be identifiers" unless names.all? { |name| name.match?(/\A[A-Za-z_]\w*\z/) }

      names.empty? ? "" : "%token #{names.join(' ')}"
    end
  end
end
