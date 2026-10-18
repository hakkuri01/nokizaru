# frozen_string_literal: true

module Nokizaru
  module TUI
    # The HUD chrome in Nokizaru's own glyphs: a top-left identity and run cluster on a left trunk, and a
    # bottom-right status cluster on a right trunk, with mirrored rails. Phase-agnostic: the opening, the form,
    # and the dashboard all supply a profile for the top and a status line plus cheatsheet for the bottom
    module Hud
      module_function

      R = UI::R
      G = UI::G
      Y = UI::Y
      C = UI::C
      W = UI::W
      FAINT = "\e[2m"
      FAINT_RED = "\e[2;31m"
      LABEL_WIDTH = 'IP Address'.length
      SOLID_TRUNK = 4

      def top(profile, geo, cheats)
        rows = identity_rows(geo, cheats)
        branches(profile).each { |label, value| rows << branch(label, value, geo.cols) }
        rows
      end

      # The head rail and the NOKIZARU // version identity, bracketed like Jekyll // Hyde's wordmark. Row 0 is the
      # outer rail at the main-rail length; the identity rail below is the inner rail, run out so its ▰▰▱ lands at
      # the mirror of the cheatsheet rail's cap (cols-1-inner_cap), a calculated diagonal shared top and bottom
      def identity_rows(geo, cheats)
        main = Layout.main_rail(geo.cols)
        identity = "#{R}┣━┤#{W} #{R}NOKIZARU#{W} #{R}//#{W} v#{VERSION} #{R}├━#{W}"
        cap = inner_cap(geo.cols, cheats)
        len = cap ? geo.cols - cap - TerminalText.width(identity) : main - 5 - TerminalText.width(identity)
        ["#{R}┌#{W}#{rail(main)}", "#{identity}#{rail([len, 3].max)}"]
      end

      # Any number of status readouts, each on its own branch row, then the cheatsheet rail and the corner. The
      # form hands up two readouts (mode and light); the opening, help, and dashboard hand up one
      def bottom(readouts, cheats, geo)
        main = Layout.main_rail(geo.cols)
        Array(readouts).map { |text| right_branch(text, geo.cols) } +
          [cheat_row(cheats, geo.cols),
           "#{' ' * (geo.cols - 1 - main)}#{mirrored_rail(main)}#{R}┘#{W}"]
      end

      def compact_top(profile, cols)
        identity = "#{R}◈#{W} #{R}NOKIZARU#{W} #{R}//#{W} v#{VERSION}  ⟦ #{C}"
        "#{identity}#{TerminalText.truncate(TerminalText.sanitize(profile[:target].to_s), [cols - 30, 1].max)}#{W} ⟧"
      end

      def compact_status(status, cols)
        text = TerminalText.truncate(status, cols - 1)
        "#{' ' * [cols - 1 - TerminalText.width(text), 0].max}#{text}"
      end

      def branches(profile)
        rows = [['Target', profile[:target]], ['IP Address', profile[:ip]], ['Modules', profile[:modules]],
                ['Switches', profile[:switches]]]
        rows << ['Notice', profile[:notice]] if profile[:notice]
        rows
      end

      # The classic dotted-leader row, hung off the trunk as a tree branch
      def branch(label, value, cols)
        lead = "#{R}├─◈#{W} #{label}#{'.' * (LABEL_WIDTH - label.length + 3)}⟦ "
        room = cols - 2 - TerminalText.width(lead) - 2
        "#{lead}#{C}#{TerminalText.truncate(TerminalText.sanitize(value.to_s), room)}#{W} ⟧"
      end

      def right_branch(text, cols)
        fitted = TerminalText.truncate(text, cols - 5)
        "#{' ' * (cols - 4 - TerminalText.width(fitted))}#{fitted} #{R}◈─┨#{W}"
      end

      # The cheatsheet in a ┤ … ├ bracket on the inner rail: a ▱▰▰ cap at the reference column, dashes out to the
      # bracket, then the spine. Its cap mirrors the identity rail's cap above. Falls back to a plain right-aligned
      # bracket only when the sheet is too wide to seat a cap at this width
      def cheat_row(cheats, cols)
        bracket = cheat_bracket(cheats)
        cap = inner_cap(cols, cheats)
        return no_cap_cheats(bracket, cols) unless cap

        dashes = cols - 5 - TerminalText.width(bracket) - cap
        "#{' ' * cap}#{R}▱▰▰#{W}#{FAINT_RED}#{'╌' * [dashes, 0].max}#{W}#{bracket}#{R}─┤#{W}"
      end

      def no_cap_cheats(bracket, cols)
        fitted = TerminalText.truncate(bracket, cols - 3)
        "#{' ' * [cols - 2 - TerminalText.width(fitted), 0].max}#{fitted}#{R}─┤#{W}"
      end

      def cheat_bracket(cheats)
        "#{R}┤#{W} #{cheatsheet(cheats)} #{R}├#{W}"
      end

      # The inner rail's ▱ cap column, the reference the identity rail mirrors at cols-1-inner_cap (Jekyll // Hyde's
      # header_cap): a design offset, pulled left of the cheatsheet bracket when one would overlap, so the two
      # inner rails stay a symmetric diagonal off the outer main rails at every width. nil when it runs off-screen
      def inner_cap(cols, cheats)
        col = [cols - 20 - (cols * 2 / 5), cols - 6 - TerminalText.width(cheat_bracket(cheats))].min
        col.negative? ? nil : col
      end

      def rail(len)
        solid, dashed = rail_parts(len)
        return "#{R}#{'─' * len}#{W}" if dashed.negative?

        "#{R}#{'─' * solid}#{W}#{FAINT_RED}#{'╌' * dashed}#{W}#{R}▰▰▱#{W}"
      end

      def mirrored_rail(len)
        solid, dashed = rail_parts(len)
        return "#{R}#{'─' * len}#{W}" if dashed.negative?

        "#{R}▱▰▰#{W}#{FAINT_RED}#{'╌' * dashed}#{W}#{R}#{'─' * solid}#{W}"
      end

      # Solid for three fifths, dashed after, capped by the three signal cells
      def rail_parts(len)
        solid = len * 3 / 5
        [solid, len - 3 - solid]
      end

      def left_trunk(geo, row)
        trunk(row - 2 - geo.branches, geo.rows)
      end

      def right_trunk(geo, row)
        offset = geo.status_row - 1 - row
        offset.negative? ? '' : trunk(offset, geo.rows, blank: '')
      end

      def trunk(offset, rows, blank: ' ')
        return blank unless offset.between?(0, Layout.trunk_length(rows) - 1)

        offset < SOLID_TRUNK ? "#{R}│#{W}" : "#{FAINT_RED}╎#{W}"
      end

      # cheats is a list of [key, label, lit]; an unlit label greys out, the key always carries the accent, and
      # entries are joined by Jekyll // Hyde's middle-dot separator
      def cheatsheet(cheats)
        cheats.map do |key, label, lit|
          shown = lit ? label : "#{FAINT}#{label}#{W}"
          "#{R}#{key}#{W} #{shown}"
        end.join("#{FAINT} · #{W}")
      end
    end
  end
end
