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

    def render(format: :human, color: :auto, source: nil, path: nil)
      return JSON.generate(@items.map(&:to_h)) if format.to_sym == :json

      @items.map { |item| render_one(item, color: color_enabled?(color), source: source, path: path) }.join("\n")
    end

    private

    def render_one(item, color:, source:, path:)
      prefix = "#{item.severity}[#{item.code}]: #{item.message}"
      prefix = "\e[31m#{prefix}\e[0m" if [true, :always].include?(color)
      lines = [prefix]
      lines.concat(render_source(item.location, source, path))
      lines << "  help: #{item.help}" if item.help
      lines << "  note: #{item.note}" if item.note
      lines.join("\n")
    end

    def render_source(location, source, path)
      return [] unless source.is_a?(String) && location.is_a?(Array) && location.length == 2 &&
                       location.all?(Integer)

      first, last = location
      return [] unless first.between?(0, source.bytesize) && last >= first

      before = source.byteslice(0, first).b
      line = before.count("\n") + 1
      line_start = (before.rindex("\n") || -1) + 1
      line_end = source.b.index("\n", first) || source.bytesize
      text = source.byteslice(line_start...line_end).delete_suffix("\r")
      prefix = source.byteslice(line_start...first).delete_suffix("\r").scrub
      last = last.clamp(first, [line_start + text.bytesize, first].max)
      width = [source.byteslice(first...last).scrub.length, 1].max
      gutter = " " * line.to_s.length
      # shortcut: carets count characters; use display-cell widths to align wide or combining glyphs.
      indentation = prefix.gsub(/[^\t]/, " ")
      ["  --> #{path || '(source)'}:#{line}:#{prefix.length + 1}",
       "#{gutter} |", "#{line} | #{text.scrub}", "#{gutter} | #{indentation}#{'^' * width}"]
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
