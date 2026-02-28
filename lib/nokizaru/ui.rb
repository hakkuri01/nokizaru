# frozen_string_literal: true

module Nokizaru
  # Nokizaru::UI implementation
  module UI
    module_function

    R = "\e[31m"
    G = "\e[32m"
    C = "\e[36m"
    W = "\e[0m"
    Y = "\e[33m"

    SYMBOLS = {
      plus: '⟦+⟧',
      info: '⟦!⟧',
      error: '⟦✘⟧'
    }.freeze

    COLORS = {
      plus: G,
      info: Y,
      error: R
    }.freeze

    def section(title, type: :plus, io: $stdout)
      io.puts
      io.puts("#{prefix(type)} #{C}#{title}#{W}")
      io.puts
    end

    def module_header(title, type: :plus, io: $stdout)
      text = title.to_s.strip
      width = [text.length + 6, 40].max
      bar = '─' * width

      io.puts
      io.puts("#{C}#{bar}#{W}")
      io.puts("#{prefix(type)} #{C}#{text}#{W}")
      io.puts("#{C}#{bar}#{W}")
    end

    def line(type, text, io: $stdout)
      io.puts("#{prefix(type)} #{W}#{text}#{W}")
    end

    def row(type, label, value, io: $stdout, **format_opts)
      io.puts(formatted_row(type, label, value, **format_opts))
    end

    def formatted_row(type, label, value, label_width: nil, min_dots: 3)
      label_text = label.to_s
      value_text = normalized_value_text(value)
      width = [label_width.to_i, label_text.length].max
      dots = '.' * [min_dots, width - label_text.length + min_dots].max
      "#{prefix(type)} #{W}#{label_text}#{dots}#{W}⟦ #{C}#{value_text}#{W} ⟧"
    end

    def normalized_value_text(value)
      return '-' if value.nil?

      text = value.to_s
      text.strip.empty? ? '-' : text
    end

    def rows(type, pairs, min_dots: 3, io: $stdout)
      width = Array(pairs).map { |(label, _)| label.to_s.length }.max.to_i
      Array(pairs).each do |label, value|
        row(type, label, value, label_width: width, min_dots: min_dots, io: io)
      end
    end

    def tree_header(label, io: $stdout)
      io.puts("#{prefix(:info)} #{W}#{label}#{W}")
    end

    def tree_rows(pairs, min_dots: 3, io: $stdout)
      normalized = Array(pairs)
      width = normalized.map { |(label, _)| label.to_s.length }.max.to_i
      normalized.each_with_index { |pair, idx| io.puts(format_tree_row(pair, idx, normalized.length, width, min_dots)) }
    end

    def format_tree_row(pair, idx, total, width, min_dots)
      label, value = pair
      branch = idx == total - 1 ? '└─◈' : '├─◈'
      label_text = label.to_s
      dots = '.' * [min_dots, width - label_text.length + min_dots].max
      value_text = normalized_value_text(value)
      " #{branch} #{W}#{label_text}#{dots}#{W}⟦ #{C}#{value_text}#{W} ⟧"
    end

    def progress(type, label, value, label_width: nil, min_dots: 3)
      "\r\e[K#{formatted_row(type, label, value, label_width: label_width, min_dots: min_dots)}"
    end

    def prefix(type)
      color = COLORS.fetch(type)
      symbol = SYMBOLS.fetch(type)
      "#{color}#{symbol}#{W}"
    end
  end
end
