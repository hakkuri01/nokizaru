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
    M = "\e[35m"

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

    DIRREC_PULSE_HEAD_POSITIONS = [0, 1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1].freeze

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

    def direnum_progress(current:, total:, elapsed_s:, frame_index:, stats:, tty: $stdout.tty?)
      rate = elapsed_s.to_f.positive? ? current.fdiv(elapsed_s.to_f) : 0.0
      body = [
        prefix(:info),
        direnum_pulse_rail(frame_index, tty: tty),
        "#{current}/#{total}",
        format('avg %.1fr/s', rate),
        "ok #{stats[:success]}",
        "err #{stats[:errors]}",
        "found #{stats[:found]}"
      ].join(' ')
      tty ? "\r\e[K#{body}" : body
    end

    def direnum_pulse_rail(frame_index, tty: $stdout.tty?)
      index = frame_index.to_i % DIRREC_PULSE_HEAD_POSITIONS.length
      head = DIRREC_PULSE_HEAD_POSITIONS[index]
      moving_right = index <= 6
      cells = Array.new(7, '·')

      3.times do |offset|
        pos = moving_right ? (head - offset) : (head + offset)
        next if pos.negative? || pos >= cells.length

        cells[pos] = direnum_pulse_block(offset, tty: tty)
      end

      cells.join
    end

    def direnum_pulse_block(offset, tty:)
      return '■' unless tty

      case offset
      when 0
        "\e[38;5;226m■#{W}"
      when 1
        "\e[38;5;220m■#{W}"
      else
        "\e[38;5;178m■#{W}"
      end
    end

    def prefix(type)
      color = COLORS.fetch(type)
      symbol = SYMBOLS.fetch(type)
      "#{color}#{symbol}#{W}"
    end
  end
end
