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

    PULSE_HEAD_POSITIONS = [0, 1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1].freeze

    def section(title, type: :plus, io: $stdout)
      with_terminal_output(io) do
        io.puts
        io.puts("#{prefix(type)} #{C}#{title}#{W}")
        io.puts
      end
    end

    def module_header(title, type: :plus, io: $stdout)
      text = title.to_s.strip
      width = [text.length + 6, 40].max
      bar = '─' * width

      with_terminal_output(io) do
        io.puts
        io.puts("#{C}#{bar}#{W}")
        io.puts("#{prefix(type)} #{C}#{text}#{W}")
        io.puts("#{C}#{bar}#{W}")
      end
    end

    def line(type, text, io: $stdout)
      with_terminal_output(io) { io.puts("#{prefix(type)} #{W}#{text}#{W}") }
    end

    def blank_line(io: $stdout)
      with_terminal_output(io) { io.puts }
    end

    def row(type, label, value, io: $stdout, **format_opts)
      with_terminal_output(io) { io.puts(formatted_row(type, label, value, **format_opts)) }
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
      with_terminal_output(io) do
        Array(pairs).each do |label, value|
          io.puts(formatted_row(type, label, value, label_width: width, min_dots: min_dots))
        end
      end
    end

    def tree_header(label, io: $stdout)
      with_terminal_output(io) { io.puts("#{prefix(:info)} #{W}#{label}#{W}") }
    end

    def tree_rows(pairs, min_dots: 3, io: $stdout)
      normalized = Array(pairs)
      width = normalized.map { |(label, _)| label.to_s.length }.max.to_i
      with_terminal_output(io) do
        normalized.each_with_index do |pair, idx|
          io.puts(format_tree_row(pair, idx, normalized.length, width, min_dots))
        end
      end
    end

    def format_tree_row(pair, idx, total, width, min_dots)
      label, value = pair
      branch = idx == total - 1 ? '└─◈' : '├─◈'
      label_text = label.to_s
      dots = '.' * [min_dots, width - label_text.length + min_dots].max
      value_text = normalized_value_text(value)
      " #{branch} #{W}#{label_text}#{dots}#{W}⟦ #{C}#{value_text}#{W} ⟧"
    end

    def run_status_line(snapshot, frame_index:, tty: $stdout.tty?)
      body = [bracketed_pulse_rail(frame_index, tty: tty), run_status_text(snapshot, tty: tty)].join(' ')
      tty ? body : body.gsub(/\e\[[0-9;]*m/, '')
    end

    def bracketed_pulse_rail(frame_index, tty: $stdout.tty?)
      return "⟦#{pulse_rail(frame_index, tty: tty)}⟧" unless tty

      "#{C}⟦#{W}#{pulse_rail(frame_index, tty: tty)}#{C}⟧#{W}"
    end

    def pulse_rail(frame_index, tty: $stdout.tty?)
      index = frame_index.to_i % PULSE_HEAD_POSITIONS.length
      head = PULSE_HEAD_POSITIONS[index]
      moving_right = index <= 6
      cells = Array.new(7, '·')

      3.times do |offset|
        pos = moving_right ? (head - offset) : (head + offset)
        next if pos.negative? || pos >= cells.length

        cells[pos] = pulse_block(offset, tty: tty)
      end

      cells.join
    end

    def pulse_block(offset, tty:)
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

    def run_status_text(snapshot, tty: $stdout.tty?)
      current = snapshot[:current_module]
      module_state = snapshot.dig(:modules, current) || {}
      segments = [
        module_run_count(snapshot, tty: tty),
        module_label(current, module_state),
        module_status_parts(current, module_state, tty: tty).join(' ')
      ]
      segments.reject(&:empty?).join(" #{status_divider(tty)} ")
    end

    def module_run_count(snapshot, tty: $stdout.tty?)
      enabled = Array(snapshot[:enabled_modules])
      current = snapshot[:current_module]
      index = enabled.index(current).to_i + 1
      "Module #{active_number(index, tty)}/#{enabled.length}"
    end

    def status_divider(tty)
      tty ? "#{C}┃#{W}" : '┃'
    end

    def module_label(key, state)
      label = state[:label].to_s.strip
      label.empty? ? key.to_s : label
    end

    def module_status_parts(key, state, tty: $stdout.tty?)
      case key.to_sym
      when :dir then dir_status_parts(state, tty: tty)
      when :ps then portscan_status_parts(state, tty: tty)
      when :sub then subdomain_status_parts(state, tty: tty)
      else generic_status_parts(state, tty: tty)
      end
    end

    def dir_status_parts(state, tty: $stdout.tty?)
      current = state[:current].to_i
      total = state[:total].to_i
      elapsed_s = state[:elapsed_s].to_f
      rate = elapsed_s.positive? ? current.fdiv(elapsed_s) : 0.0
      ["#{active_number(current, tty)}/#{total}", "avg #{active_number(format('%.1f', rate), tty)}r/s",
       "ok #{active_number(state[:success].to_i, tty)}", "err #{active_number(state[:errors].to_i, tty)}",
       "found #{active_number(state[:found].to_i, tty)}"]
    end

    def portscan_status_parts(state, tty: $stdout.tty?)
      ["#{active_number(state[:current].to_i, tty)}/#{state[:total].to_i}",
       "open #{active_number(state[:open].to_i, tty)}"]
    end

    def subdomain_status_parts(state, tty: $stdout.tty?)
      [state[:stage].to_s, "#{active_number(state[:current].to_i, tty)}/#{state[:total].to_i}",
       "found #{active_number(state[:found].to_i, tty)}", color_dynamic_numbers(state[:detail], tty)]
        .reject(&:empty?)
    end

    def generic_status_parts(state, tty: $stdout.tty?)
      parts = []
      phase = state[:phase].to_s
      stage = state[:stage].to_s
      detail = color_dynamic_numbers(state[:detail], tty) if state[:detail]
      parts << phase if phase == 'failed' || (stage.empty? && detail.to_s.empty?)
      parts << stage unless stage.empty?
      parts << detail if detail
      parts.reject(&:empty?)
    end

    def active_number(value, tty)
      return value.to_s unless tty

      "#{Y}#{value}#{W}"
    end

    def color_dynamic_numbers(value, tty)
      text = value.to_s
      return text unless tty

      text.gsub(/\d+(?:\.\d+)?/) { |number| active_number(number, tty) }
    end

    def active_progress_rail=(rail)
      @active_progress_rail = rail
    end

    def active_progress_rail
      @active_progress_rail
    end

    def with_terminal_output(io = $stdout, &block)
      rail = active_progress_rail
      return block.call unless rail&.active? && io.equal?($stdout)

      rail.with_output(&block)
    end

    def prefix(type)
      color = COLORS.fetch(type)
      symbol = SYMBOLS.fetch(type)
      "#{color}#{symbol}#{W}"
    end
  end
end
