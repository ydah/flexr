# frozen_string_literal: true

require "tempfile"
require "json"
require_relative "../lib/flexr/cli"

module Flexr
  module Benchmarking
    module LramaLexer
      LINE_BREAK = /\n/
      module_function

      def recognizer(patterns)
        source = +"class GrammarRecognizer < Flexr::Lexer\nbackend :firstmatch\noption :experimental, :standalone\n"
        patterns.each { |pattern, kind| source << "rule(#{pattern.inspect}, emit: #{kind.inspect})\n" }
        source << "end\n"
        Tempfile.create(["lrama-recognizer-", ".flexr.rb"]) do |file|
          file.write(source)
          file.flush
          scope = Module.new
          scope.module_eval(Generator.new(file.path).generate, file.path)
          scope.const_get(:GrammarRecognizer, false)
        end
      end

      def patterns(native, path)
        require "prism"
        method = nil
        visit = lambda do |node|
          method = node if node.is_a?(Prism::DefNode) && node.name == :lex_token
          node.compact_child_nodes.each { |child| visit.call(child) }
        end
        visit.call(Prism.parse_file(path).value)
        raise "upstream lex_token was not found" unless method

        scans = []
        visit = lambda do |node|
          if node.is_a?(Prism::CallNode) && node.name == :scan &&
              node.receiver.is_a?(Prism::InstanceVariableReadNode) && node.receiver.name == :@scanner
            argument = node.arguments.arguments.first
            scans << case argument
            when Prism::RegularExpressionNode then ::Regexp.new(argument.unescaped, argument.options)
            when Prism::ConstantReadNode then native.const_get(argument.name)
            else raise "unsupported upstream scan argument"
            end
          end
          node.compact_child_nodes.each { |child| visit.call(child) }
        end
        visit.call(method)
        raise "upstream lex_token scan layout changed" unless scans.length == 12

        scans = scans.drop(4)
        scans[0] = ::Regexp.union(native::SYMBOLS.map { |symbol| symbol.gsub(/\\(.)/, '\1') })
        scans[1] = ::Regexp.union(native::PERCENT_TOKENS)
        scans.zip(%i[SYMBOL DIRECTIVE SYMBOL TAG CHARACTER STRING INTEGER IDENTIFIER])
      end

      def adapter(native, recognizer)
        Class.new(native) do
          define_method(:initialize) do |file|
            super(file)
            @recognizer = recognizer.new(file.text)
          end

          define_method(:lex_token) do
            loop do
              if @scanner.scan(LINE_BREAK)
                newline
              elsif @scanner.scan(/[^\S\n]+/)
                next
              elsif @scanner.scan(%r{/\*})
                lex_comment
              elsif @scanner.scan(%r{//[^\n]*(?:\n|$)})
                newline if @scanner.matched.end_with?("\n")
              else
                break
              end
            end
            reset_first_position
            return if @scanner.eos?

            @recognizer.instance_variable_set(:@position, @scanner.pos)
            kind, text = @recognizer.next_token
            raise ::ParseError, location.generate_error_message("Unexpected token") if
              kind == :DIRECTIVE && @scanner.string.byteslice(@recognizer.byte_pos, 1)&.match?(/[-A-Za-z0-9_.]/)
            @scanner.pos = @recognizer.byte_pos
            types = { TAG: :Tag, CHARACTER: :Char, STRING: :Str, INTEGER: :Int, IDENTIFIER: :Ident }
            token_class = native::Token.const_get(types.fetch(kind, :Token))
            value = kind == :INTEGER ? Integer(text) : text
            type = case kind
            when :SYMBOL, :DIRECTIVE then text
            when :IDENTIFIER then identifier_colon? ? :IDENT_COLON : :IDENTIFIER
            else kind
            end
            [type, token_class.new(s_value: value, location: location)]
          rescue StandardError => e
            raise unless e.class.name&.end_with?("LexError")

            raise ::ParseError, location.generate_error_message("Unexpected token")
          end
        end
      end

      def observe(klass, source, path)
        original = Lrama::Lexer
        events = []
        recording = Class.new(klass) do
          define_method(:next_token) do
            super().tap do |token|
              if token
                type, value = token
                loc = value.location
                events << [type, value.s_value, loc.first_line, loc.first_column, loc.last_line, loc.last_column]
              end
            end
          end
        end
        Lrama.send(:remove_const, :Lexer)
        Lrama.const_set(:Lexer, recording)
        error = nil
        begin
          Lrama::Parser.new(source, path).parse
        rescue StandardError => e
          error = [e.class.name, e.message]
        end
        [events, error]
      ensure
        Lrama.send(:remove_const, :Lexer)
        Lrama.const_set(:Lexer, original)
      end

      def run(root, iterations: 3, out: $stdout)
        $LOAD_PATH.unshift(File.join(root, "lib"))
        require "lrama"
        native = Lrama::Lexer
        candidate = adapter(native, recognizer(patterns(native, File.join(root, "lib/lrama/lexer.rb"))))
        paths = Dir[File.join(root, "spec/fixtures/**/*.y")]
        raise "no upstream fixture corpus" if paths.empty?

        inputs = paths.map { |path| [path, File.read(path)] }
        successful_parses = 0
        tokens = 0
        inputs.each do |path, source|
          expected = observe(native, source, path)
          actual = observe(candidate, source, path)
          raise "lexer mismatch: #{path}" unless actual == expected
          successful_parses += 1 unless expected.last
          tokens += expected.first.length
        end
        timings = { native: native, standalone: candidate }.transform_values do |klass|
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          iterations.times { inputs.each { |path, source| observe(klass, source, path) } }
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        end
        result = { ruby: RUBY_DESCRIPTION, fixtures: paths.length, successful_parses: successful_parses,
                   tokens_compared: tokens, iterations: iterations, seconds: timings,
                   scope: "normal grammar tokens; existing trivia, C-code scanning, locations, and parser retained" }
        out.puts JSON.pretty_generate(result)
        result
      end
    end
  end
end

Flexr::Benchmarking::LramaLexer.run(ARGV.fetch(0)) if $PROGRAM_NAME == __FILE__
