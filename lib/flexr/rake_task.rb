# frozen_string_literal: true

module Flexr
  class RakeTask
    attr_accessor :spec, :output, :warn_as_error

    def initialize(name = :flexr)
      @name = name
      @warn_as_error = false
      yield self if block_given?
      define_task
    end

    private

    def define_task
      require "rake"
      raise ArgumentError, "spec is required" unless @spec

      output = @output || @spec.sub(/\.flexr\.rb\z/, ".rb")
      Rake::FileTask.define_task(output => @spec) do
        Generator.new(@spec, output: output).generate
      end
      Rake::Task.define_task(@name => output)
    end
  end
end
