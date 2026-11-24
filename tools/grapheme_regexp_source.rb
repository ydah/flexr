# frozen_string_literal: true

module GraphemeRegexpSource
  module_function

  def build(rows)
    finish = rows.length
    edges = rows.each_with_index.to_h do |row, state|
      targets = Hash.new { |groups, target| groups[target] = [] }
      row.each_with_index do |target, symbol|
        targets[target] << "@#{symbol}@" unless target.nil?
      end
      outgoing = targets.transform_values { |symbols| alternative(symbols) }
      if state.positive?
        symbols = targets.values.flatten
        outgoing[finish] = symbols.empty? ? "" : "(?!#{alternative(symbols)})"
      end
      [state, outgoing]
    end

    remaining = (1...finish).to_a
    until remaining.empty?
      state = remaining.min_by { |candidate| elimination_cost(edges, candidate) }
      eliminate(edges, state)
      remaining.delete(state)
    end
    edges.fetch(0).fetch(finish)
  end

  def elimination_cost(edges, state)
    incoming = edges.filter_map { |origin, outgoing| outgoing[state] if origin != state }
    outgoing = edges.fetch(state).reject { |target, _| target == state }.values
    loop_size = edges.fetch(state).fetch(state, "").length + 5
    prefix_size = outgoing.size * incoming.sum(&:length)
    suffix_size = incoming.size * outgoing.sum(&:length)
    repeated_size = incoming.size * outgoing.size * loop_size
    prefix_size + suffix_size + repeated_size
  end

  def eliminate(edges, state)
    outgoing = edges.delete(state)
    loop_source = outgoing.delete(state)
    repeat = loop_source ? "(?:#{loop_source})*" : ""
    edges.each_value do |targets|
      prefix = targets.delete(state)
      next unless prefix

      outgoing.each do |target, suffix|
        path = "#{prefix}#{repeat}#{suffix}"
        previous = targets[target]
        targets[target] = previous ? alternative([previous, path]) : path
      end
    end
  end

  def alternative(parts)
    parts.length == 1 ? parts.first : "(?:#{parts.join('|')})"
  end
end
