# frozen_string_literal: true

module Nokizaru
  module TUI
    # Draws the command form: the HUD clusters around a node-tree of fields, the focused field marked, module
    # chips in the dashboard's glyph vocabulary, and the live `nokizaru …` command pinned at the foot. A pure
    # renderer over a Form; header values never appear, only their count
    module FormView
      module_function

      R = Hud::R
      G = Hud::G
      Y = Hud::Y
      C = Hud::C
      W = Hud::W
      FAINT = Hud::FAINT
      FAINT_RED = Hud::FAINT_RED
      LABELW = Form::FIELDS.map { |field| field.label.length }.max
      ROLE = { cmd: FAINT, mod: R, flag: FAINT, value: C }.freeze
      NORMAL_CHEATS = [%w[j/k field], ['←/→', 'chip'], %w[space pick], %w[i edit], %w[h help], %w[enter run],
                       %w[q quit]].freeze
      INSERT_CHEATS = [%w[type edit], %w[enter run], %w[esc normal]].freeze

      def frame(form)
        geo = Layout.measure(form.cols, form.rows, 4, footers: 2)
        return View.tiny(geo.cols, geo.rows) if geo.mode == :tiny
        return compact(form, geo) if geo.mode == :compact

        View.compose(geo, Hud.top(form.profile, geo, cheats(form)), full_middle(form, geo),
                     Hud.bottom(readouts(form), cheats(form), geo))
      end

      def full_middle(form, geo)
        command = command_lines(form, geo.pane_width)
        field_height = [geo.pane_height - command.length - 1, 1].max
        middle = field_region(form, geo, field_height, geo.pane_width)
        command.each_with_index { |line, index| middle[geo.pane_top + field_height + 1 + index] = line }
        middle
      end

      def compact(form, geo)
        command = command_lines(form, geo.cols - 2)
        rows = [Hud.compact_top(form.profile, geo.cols)]
        region = field_region(form, geo, [geo.pane_height - command.length, 1].max, geo.cols - 2)
        (1...geo.status_row).each { |row| rows << " #{region[row]}" }
        first = [geo.status_row - command.length, 1].max
        command.first(geo.status_row - first).each_with_index { |line, index| rows[first + index] = " #{line}" }
        rows << Hud.compact_status(status(form), geo.cols)
      end

      # The scrolled field list placed into a row hash, keeping the focused field in view
      def field_region(form, geo, height, width)
        rows, focus_row = build_rows(form, width)
        first = focus_row < height ? 0 : focus_row - height + 1
        window = rows[first, height] || []
        window.each_with_index.to_h { |line, index| [geo.pane_top + index, line] }
      end

      # The field list as plain styled rows, with the display row of the focused field for scrolling
      def build_rows(form, width)
        rows = ["#{R}◈#{W} #{R}Compose Scan#{W}", '']
        focus_row = 0
        group = nil
        Form::FIELDS.each_with_index do |field, index|
          if field.group != group
            (rows << divider(field.group)
             group = field.group)
          end
          focus_row = rows.length if index == form.focus
          rows.concat(field_lines(form, field, index, width))
        end
        [rows, focus_row]
      end

      def divider(group)
        "#{FAINT_RED}── #{W}#{FAINT}#{group}#{W} #{FAINT_RED}#{'─' * [24 - group.length, 1].max}#{W}"
      end

      def field_lines(form, field, index, width)
        focused = index == form.focus
        head = "#{cursor(focused)} #{node(field, focused)} #{label(field, focused)}"
        return [head] + chip_lines(form, focused, width) if field.kind == :modules

        ["#{head}#{well(form, field, focused)}"]
      end

      def cursor(focused)
        focused ? "#{R}▸#{W}" : ' '
      end

      def node(field, focused)
        color = focused || field.required ? R : FAINT
        "#{color}#{field.required ? '◈' : '◇'}#{W}"
      end

      def label(field, focused)
        color = if focused
                  R
                else
                  (field.required ? W : FAINT)
                end
        dots = '.' * [LABELW - field.label.length + 3, 3].max
        "#{color}#{field.label}#{W}#{FAINT}#{dots}#{W}"
      end

      def well(form, field, focused)
        badge = field.flag ? " #{FAINT}[#{field.flag.sub(/\A-+/, '')}]#{W}" : ''
        "⟦ #{value(form, field, focused)} ⟧#{badge}"
      end

      def value(form, field, focused)
        return toggle_value(form.value(field.key)) if field.kind == :toggle

        text_value(form, field, focused)
      end

      def toggle_value(on)
        on ? "#{G}on#{W}" : "#{FAINT}off#{W}"
      end

      # Values can arrive prefilled from argv, so they are sanitized like any other text that reaches the terminal
      def text_value(form, field, focused)
        raw = form.value(field.key).to_s
        return caret_value(raw, form.caret) if focused && form.insert
        return "#{FAINT}#{hint(field)}#{W}" if raw.empty?

        "#{C}#{TerminalText.sanitize(raw)}#{W}"
      end

      def caret_value(raw, caret)
        at = caret.clamp(0, raw.length)
        "#{C}#{TerminalText.sanitize(raw[0, at])}#{R}▏#{C}#{TerminalText.sanitize(raw[at..])}#{W}"
      end

      def hint(field)
        field.kind == :number ? 'default' : '…'
      end

      # The module multiselect as chips in the tab glyph vocabulary, the focused chip marked, wrapped to width
      def chip_lines(form, field_focused, width)
        chips = Form::MODULE_CHIPS.each_with_index.map do |(key, name), index|
          on = form.module_on?(key)
          glyph = on ? "#{G}⟦+⟧#{W}" : "#{FAINT}⟦·⟧#{W}"
          mark = field_focused && index == form.chip
          shown = if mark
                    "#{R}#{name}#{W}"
                  else
                    (on ? "#{W}#{name}#{W}" : "#{FAINT}#{name}#{W}")
                  end
          "#{glyph} #{shown}"
        end
        pack(chips, [width - 4, 8].max).map { |line| "    #{line}" }
      end

      # Greedy pack of styled chips into lines no wider than width
      def pack(chips, width)
        lines = [+'']
        used = 0
        chips.each do |chip|
          size = TerminalText.width(chip)
          if used.positive? && used + 2 + size > width
            lines << +''
            used = 0
          end
          lines.last << '  ' if used.positive?
          lines.last << chip
          used += (used.positive? ? 2 : 0) + size
        end
        lines
      end

      def command_lines(form, width)
        text = +'› '
        form.command_segments.each_with_index do |(value, role), index|
          text << ' ' if index.positive?
          text << "#{ROLE.fetch(role, W)}#{TerminalText.sanitize(value)}#{W}"
        end
        TerminalText.wrap(text, width)
      end

      # Full mode carries the vim mode and the readiness light on their own branch rows
      def readouts(form)
        [mode_readout(form), light_readout(form)]
      end

      def mode_readout(form)
        form.insert ? "#{Y}INSERT#{W}" : "#{R}NORMAL#{W}"
      end

      def light_readout(form)
        return "#{R}⟦✘⟧#{W} #{TerminalText.sanitize(form.error)}" if form.error
        return "#{Y}◉ LAUNCHING#{W}" if form.launching

        form.ready? ? "#{G}◉ READY#{W}" : "#{FAINT}○ STANDBY#{W}"
      end

      # Compact mode has room for one line, so the two readouts share it without a divider
      def status(form)
        "#{mode_readout(form)}  #{light_readout(form)}"
      end

      def cheats(form)
        (form.insert ? INSERT_CHEATS : NORMAL_CHEATS).map { |key, tag| [key, tag, true] }
      end
    end
  end
end
