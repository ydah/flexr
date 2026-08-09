# frozen_string_literal: true

module Flexr
  Diagnostic = Struct.new(:code, :severity, :message, :location, :help, :note, keyword_init: true) do
    def error?
      severity == :error
    end

    def warning?
      severity == :warning
    end

    def to_h
      {
        code: code,
        severity: severity,
        message: message,
        location: location,
        help: help,
        note: note
      }.compact
    end
  end

  class DiagnosticSet
    include Enumerable

    def initialize
      @items = []
    end

    def each(&)
      @items.each(&)
    end

    def <<(diagnostic)
      @items << diagnostic
      self
    end

    def any_error?
      @items.any?(&:error?)
    end

    def empty?
      @items.empty?
    end

    def to_a
      @items.dup
    end

    def render(format: :human, color: :auto)
      return JSON.generate(@items.map(&:to_h)) if format.to_sym == :json

      @items.map { |item| render_one(item, color: color_enabled?(color)) }.join("\n")
    end

    private

    def render_one(item, color:)
      prefix = "#{item.severity}[#{item.code}]: #{item.message}"
      prefix = "\e[31m#{prefix}\e[0m" if [true, :always].include?(color)
      lines = [prefix]
      lines << "  help: #{item.help}" if item.help
      lines << "  note: #{item.note}" if item.note
      lines.join("\n")
    end

    def color_enabled?(color)
      return false if ENV.key?("NO_COLOR") || color == :never || color == false
      return true if [:always, true].include?(color)

      $stderr.tty?
    end
  end

  module Diagnostics
    module_function

    def error(code, message, location: nil, help: nil, note: nil)
      Diagnostic.new(code: code, severity: :error, message: message, location: location, help: help, note: note)
    end

    def warning(code, message, location: nil, help: nil, note: nil)
      Diagnostic.new(code: code, severity: :warning, message: message, location: location, help: help, note: note)
    end

    def raise!(diagnostic)
      klass = diagnostic.code == "FLEXR-E014" ? UnsupportedRegexpError : CompileError
      raise klass.new(diagnostic.message, diagnostic: diagnostic)
    end
  end
end
