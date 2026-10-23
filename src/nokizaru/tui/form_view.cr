require "../terminal_text"
require "./hud"
require "./view"
require "./form"

module Nokizaru
  module Tui
    # Draws the command form: the HUD clusters around a node-tree of fields, the
    # focused field marked, module chips in the dashboard's glyph vocabulary, and
    # the live `nokizaru ...` command pinned at the foot. A pure renderer over a
    # Form; header values never appear, only their count.
    module FormView
      extend self

      R         = Hud::R
      C         = Hud::C
      W         = Hud::W
      G         = UI::G
      Y         = UI::Y
      FAINT     = Hud::FAINT
      FAINT_RED = Hud::FAINT_RED

      LABELW = Form::FIELDS.max_of(&.label.size)
      ROLE   = {
        Form::Role::Cmd => FAINT, Form::Role::Mod => R,
        Form::Role::Flag => FAINT, Form::Role::Value => C,
      }
      NORMAL_CHEATS = [
        Hud::Cheat.new("j/k", "field"), Hud::Cheat.new("←/→", "chip"), Hud::Cheat.new("space", "pick"),
        Hud::Cheat.new("i", "edit"), Hud::Cheat.new("h", "help"), Hud::Cheat.new("enter", "run"),
        Hud::Cheat.new("q", "quit"),
      ]
      INSERT_CHEATS = [
        Hud::Cheat.new("type", "edit"), Hud::Cheat.new("enter", "run"), Hud::Cheat.new("esc", "normal"),
      ]

      def frame(form : Form) : Array(String)
        geo = Layout.measure(form.cols, form.rows, 4, footers: 2)
        return View.tiny(geo.cols, geo.rows) if geo.mode.tiny?
        return compact(form, geo) if geo.mode.compact?

        View.compose(geo, Hud.top(form.profile, geo, cheats(form)), full_middle(form, geo),
          Hud.bottom(readouts(form), cheats(form), geo))
      end

      private def full_middle(form : Form, geo : Layout::Geometry) : Hash(Int32, String)
        command = command_lines(form, geo.pane_width)
        field_height = [geo.pane_height - command.size - 1, 1].max
        middle = field_region(form, geo, field_height, geo.pane_width)
        command.each_with_index { |line, index| middle[geo.pane_top + field_height + 1 + index] = line }
        middle
      end

      private def compact(form : Form, geo : Layout::Geometry) : Array(String)
        status_row = geo.status_row || geo.rows
        command = command_lines(form, geo.cols - 2)
        rows = [Hud.compact_top(form.profile, geo.cols)]
        region = field_region(form, geo, [geo.pane_height - command.size, 1].max, geo.cols - 2)
        (1...status_row).each { |row| rows << " #{region[row]? || ""}" }
        first = [status_row - command.size, 1].max
        command.first(status_row - first).each_with_index { |line, index| rows[first + index] = " #{line}" }
        rows << Hud.compact_status(status(form), geo.cols)
        rows
      end

      # The scrolled field list placed into a row map, keeping the focused field in view.
      private def field_region(form : Form, geo : Layout::Geometry, height : Int32, width : Int32) : Hash(Int32, String)
        rows, focus_row = build_rows(form, width)
        first = focus_row < height ? 0 : focus_row - height + 1
        window = rows[first, height]? || [] of String
        middle = {} of Int32 => String
        window.each_with_index { |line, index| middle[geo.pane_top + index] = line }
        middle
      end

      # The field list as plain styled rows, with the display row of the focused
      # field for scrolling.
      private def build_rows(form : Form, width : Int32) : Tuple(Array(String), Int32)
        rows = ["#{R}◈#{W} #{R}Compose Scan#{W}", ""]
        focus_row = 0
        group = nil
        Form::FIELDS.each_with_index do |field, index|
          if field.group != group
            rows << divider(field.group)
            group = field.group
          end
          focus_row = rows.size if index == form.focus
          rows.concat(field_lines(form, field, index, width))
        end
        {rows, focus_row}
      end

      private def divider(group : String) : String
        "#{FAINT_RED}── #{W}#{FAINT}#{group}#{W} #{FAINT_RED}#{"─" * [24 - group.size, 1].max}#{W}"
      end

      private def field_lines(form : Form, field : Form::Field, index : Int32, width : Int32) : Array(String)
        focused = index == form.focus
        head = "#{cursor(focused)} #{node(field, focused)} #{label(field, focused)}"
        return [head] + chip_lines(form, focused, width) if field.kind.modules?

        ["#{head}#{well(form, field, focused)}"]
      end

      private def cursor(focused : Bool) : String
        focused ? "#{R}▸#{W}" : " "
      end

      private def node(field : Form::Field, focused : Bool) : String
        color = focused || field.required ? R : FAINT
        "#{color}#{field.required ? "◈" : "◇"}#{W}"
      end

      private def label(field : Form::Field, focused : Bool) : String
        color = focused ? R : (field.required ? W : FAINT)
        dots = "." * [LABELW - field.label.size + 3, 3].max
        "#{color}#{field.label}#{W}#{FAINT}#{dots}#{W}"
      end

      private def well(form : Form, field : Form::Field, focused : Bool) : String
        flag = field.flag
        badge = flag ? " #{FAINT}[#{flag.lstrip('-')}]#{W}" : ""
        "⟦ #{value(form, field, focused)} ⟧#{badge}"
      end

      private def value(form : Form, field : Form::Field, focused : Bool) : String
        return toggle_value(form.toggle?(field.key)) if field.kind.toggle?

        text_value(form, field, focused)
      end

      private def toggle_value(on : Bool) : String
        on ? "#{G}on#{W}" : "#{FAINT}off#{W}"
      end

      # Values can arrive prefilled from the invocation, so they are sanitized like
      # any other text that reaches the terminal.
      private def text_value(form : Form, field : Form::Field, focused : Bool) : String
        raw = form.text(field.key)
        return caret_value(raw, form.caret) if focused && form.insert?
        return "#{FAINT}#{hint(field)}#{W}" if raw.empty?

        "#{C}#{TerminalText.sanitize(raw)}#{W}"
      end

      private def caret_value(raw : String, caret : Int32) : String
        at = caret.clamp(0, raw.size)
        "#{C}#{TerminalText.sanitize(raw[0, at])}#{R}▏#{C}#{TerminalText.sanitize(raw[at..])}#{W}"
      end

      private def hint(field : Form::Field) : String
        field.kind.number? ? "default" : "…"
      end

      # The module multiselect as chips in the tab glyph vocabulary, the focused
      # chip marked, wrapped to width.
      private def chip_lines(form : Form, field_focused : Bool, width : Int32) : Array(String)
        chips = Form::MODULE_CHIPS.map_with_index do |chip, index|
          key, name = chip
          on = form.module_on?(key)
          glyph = on ? "#{G}⟦+⟧#{W}" : "#{FAINT}⟦·⟧#{W}"
          mark = field_focused && index == form.chip
          shown = if mark
                    "#{R}#{name}#{W}"
                  elsif on
                    "#{W}#{name}#{W}"
                  else
                    "#{FAINT}#{name}#{W}"
                  end
          "#{glyph} #{shown}"
        end
        pack(chips, [width - 4, 8].max).map { |line| "    #{line}" }
      end

      # Greedy pack of styled chips into lines no wider than width.
      private def pack(chips : Array(String), width : Int32) : Array(String)
        lines = [""]
        used = 0
        chips.each do |chip|
          size = TerminalText.width(chip)
          if used > 0 && used + 2 + size > width
            lines << ""
            used = 0
          end
          if used > 0
            lines[-1] = "#{lines[-1]}  #{chip}"
            used += 2 + size
          else
            lines[-1] = "#{lines[-1]}#{chip}"
            used += size
          end
        end
        lines
      end

      private def command_lines(form : Form, width : Int32) : Array(String)
        text = String.build do |io|
          io << "› "
          form.command_segments.each_with_index do |segment, index|
            value, role = segment
            io << " " if index > 0
            io << (ROLE[role]? || W) << TerminalText.sanitize(value) << W
          end
        end
        TerminalText.wrap(text, width)
      end

      # Full mode carries the vim mode and the readiness light on their own branch rows.
      private def readouts(form : Form) : Array(String)
        [mode_readout(form), light_readout(form)]
      end

      private def mode_readout(form : Form) : String
        form.insert? ? "#{Y}INSERT#{W}" : "#{R}NORMAL#{W}"
      end

      private def light_readout(form : Form) : String
        error = form.error
        return "#{R}⟦✘⟧#{W} #{TerminalText.sanitize(error)}" if error
        return "#{Y}◉ LAUNCHING#{W}" if form.launching?

        form.ready? ? "#{G}◉ READY#{W}" : "#{FAINT}○ STANDBY#{W}"
      end

      # Compact mode has room for one line, so the two readouts share it.
      private def status(form : Form) : String
        "#{mode_readout(form)}  #{light_readout(form)}"
      end

      private def cheats(form : Form) : Array(Hud::Cheat)
        form.insert? ? INSERT_CHEATS : NORMAL_CHEATS
      end
    end
  end
end
