# frozen_string_literal: true

require "digest"
require "fileutils"
require_relative "../artifact_writer"

module Flexr
  module Automaton
    class DfaCache
      SCHEMA_VERSION = 3

      def initialize(directory, spec, state_limit, construction:)
        @directory = directory
        @compiler = [SCHEMA_VERSION, construction, Flexr::VERSION, Unicode::VERSION, spec.encoding.name,
                     spec.options[:unicode] == true, state_limit]
      end

      def key(rules, resolved_patterns)
        patterns = rules.zip(resolved_patterns).map do |rule, values|
          [rule.index, rule.priority, values.map { |pattern| pattern_key(pattern) }]
        end
        Digest::SHA256.hexdigest(JSON.generate([@compiler, patterns], max_nesting: false))
      end

      def read(key)
        checksum, payload = File.binread(path(key)).split("\n", 2)
        return unless payload && checksum == Digest::SHA256.hexdigest(key + payload)

        data = JSON.parse(payload, symbolize_names: true)
        [Generated.load_dfa(data.fetch(:dfa)), data.fetch(:conditions), data.fetch(:empty_absence)]
      rescue SystemCallError, IOError, JSON::ParserError, ArgumentError, KeyError, TypeError
        nil
      end

      def write(key, dfa, conditions, empty_absence)
        data = {
          accepts: dfa.accepts.map { |row| row.map(&:to_a) }, ec: dfa.ec, class_count: dfa.class_count,
          start: dfa.start, rule_ids: dfa.rule_ids, state_count: dfa.states, transitions: dfa.transitions
        }
        payload = JSON.generate(dfa: data, conditions: conditions, empty_absence: empty_absence)
        checksum = Digest::SHA256.hexdigest(key + payload)
        FileUtils.mkdir_p(@directory, mode: 0o700)
        ArtifactWriter.write!(path(key), "#{checksum}\n#{payload}")
      rescue SystemCallError, IOError
        nil
      end

      private

      def pattern_key(pattern)
        case pattern
        when Pattern then [pattern.operation, pattern.operands.map { |operand| pattern_key(operand) }]
        when ::Regexp then [:regexp, pattern.encoding.name, pattern.options, pattern.source.b.unpack1("H*")]
        else [:literal, pattern.encoding.name, pattern.b.unpack1("H*")]
        end
      end

      def path(key)
        File.join(@directory, "#{key}.dfa")
      end
    end
  end
end
