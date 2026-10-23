require "../ui"
require "../terminal_text"
require "./progress"

module Nokizaru
  module Tui
    # The live scan status: a pulsing signal rail and a one-line summary of the
    # current module. Rendered for the dashboard status row and (in the runner
    # phase) the classic progress rail. Always colored, since both callers draw to
    # a terminal. The per-module rich detail (dir/port/subdomain counts) lands when
    # the modules report live progress in the runner phase; until then every module
    # shows the generic phase/stage/detail summary.
    module StatusLine
      extend self

      R = UI::R
      W = UI::W
      Y = UI::Y

      # The pulse head sweeps right to 6 and back, a 12-frame cycle.
      PULSE_HEAD_POSITIONS = [0, 1, 2, 3, 4, 5, 6, 5, 4, 3, 2, 1]

      def render(snapshot : Progress::Snapshot, frame_index : Int32, width : Int32? = nil) : String
        rail = bracketed_pulse_rail(frame_index)
        body = "#{rail} #{status_text(snapshot)}"
        if limit = width
          return constrained(snapshot, rail, limit) if TerminalText.width(body) >= limit
        end
        body
      end

      private def bracketed_pulse_rail(frame_index : Int32) : String
        "#{R}⟦#{W}#{pulse_rail(frame_index)}#{R}⟧#{W}"
      end

      private def pulse_rail(frame_index : Int32) : String
        index = frame_index % PULSE_HEAD_POSITIONS.size
        head = PULSE_HEAD_POSITIONS[index]
        moving_right = index <= 6
        cells = Array.new(7, "·")
        3.times do |offset|
          pos = moving_right ? head - offset : head + offset
          next if pos < 0 || pos >= cells.size

          cells[pos] = pulse_block(offset)
        end
        cells.join
      end

      private def pulse_block(offset : Int32) : String
        case offset
        when 0 then "\e[38;5;226m■#{W}"
        when 1 then "\e[38;5;220m■#{W}"
        else        "\e[38;5;178m■#{W}"
        end
      end

      private def constrained(snapshot : Progress::Snapshot, rail : String, width : Int32) : String
        available = width - 1
        rail_width = TerminalText.width(rail)
        return "" if available < rail_width

        suffix = available - rail_width - 1
        return rail if suffix <= 0

        "#{rail} #{TerminalText.truncate(status_text(snapshot), suffix)}"
      end

      private def status_text(snapshot : Progress::Snapshot) : String
        current = snapshot.current_module
        state = current ? snapshot.modules[current]? : nil
        segments = [
          module_run_count(snapshot),
          module_label(current, state),
          status_parts(state).join(" "),
        ]
        segments.reject(&.empty?).join(" #{R}//#{W} ")
      end

      private def module_run_count(snapshot : Progress::Snapshot) : String
        enabled = snapshot.enabled_modules
        current = snapshot.current_module
        index = current ? enabled.index(current) : nil
        "Module #{active_number((index || 0) + 1)}/#{enabled.size}"
      end

      private def module_label(key : String?, state : Progress::ModuleState?) : String
        label = state.try(&.label.strip) || ""
        label.empty? ? (key || "") : label
      end

      # Generic for every module now; the dir/port/subdomain detail parts arrive
      # with live module progress in the runner phase.
      private def status_parts(state : Progress::ModuleState?) : Array(String)
        return [] of String if state.nil?

        parts = [] of String
        phase = state.phase.to_s.downcase
        stage = state.stage
        detail = state.detail.empty? ? nil : color_dynamic_numbers(state.detail)
        parts << phase if phase == "failed" || (stage.empty? && (detail.nil? || detail.empty?))
        parts << stage unless stage.empty?
        detail.try { |text| parts << text }
        parts.reject(&.empty?)
      end

      private def active_number(value : Int32) : String
        "#{Y}#{value}#{W}"
      end

      private def color_dynamic_numbers(value : String) : String
        value.gsub(/\d+(?:\.\d+)?/) { |number| "#{Y}#{number}#{W}" }
      end
    end
  end
end
