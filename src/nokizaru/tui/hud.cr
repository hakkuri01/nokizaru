require "../version"
require "../ui"
require "../terminal_text"
require "./layout"
require "./profile"

module Nokizaru
  module Tui
    # The HUD chrome in Nokizaru's own glyphs: a top-left identity and run cluster
    # on a left trunk, and a bottom-right status cluster on a right trunk, with
    # mirrored rails. Phase-agnostic: the opening, the form, and the dashboard all
    # supply a profile for the top and a status line plus cheatsheet for the
    # bottom. The rail caps are a calculated, symmetric diagonal (a port of Jekyll
    # // Hyde's header_cap): both top<->bottom pairs mirror at cols-1, and the
    # inner-vs-outer offset is identical top and bottom at every width.
    module Hud
      extend self

      # One cheatsheet entry: a key, its label, and whether the label is lit (an
      # unlit label greys out while the key keeps the accent).
      struct Cheat
        getter key : String
        getter label : String
        getter? lit : Bool

        def initialize(@key : String, @label : String, @lit : Bool = true)
        end
      end

      R         = UI::R
      C         = UI::C
      W         = UI::W
      FAINT     = "\e[2m"
      FAINT_RED = "\e[2;31m"

      LABEL_WIDTH = "IP Address".size
      SOLID_TRUNK = 4

      def top(profile : Profile, geo : Layout::Geometry, cheats : Array(Cheat)) : Array(String)
        rows = identity_rows(geo, cheats)
        branches(profile).each { |label, value| rows << branch(label, value, geo.cols) }
        rows
      end

      # The head rail and the NOKIZARU // version identity, bracketed like Jekyll //
      # Hyde's wordmark. Row 0 is the outer rail at the main-rail length; the
      # identity rail below is the inner rail, run out so its signal cap lands at
      # the mirror of the cheatsheet rail's cap (cols-1-inner_cap), the calculated
      # diagonal shared top and bottom.
      def identity_rows(geo : Layout::Geometry, cheats : Array(Cheat)) : Array(String)
        main = Layout.main_rail(geo.cols)
        identity = "#{R}┣━┤#{W} #{R}NOKIZARU#{W} #{R}//#{W} v#{VERSION} #{R}├━#{W}"
        cap = inner_cap(geo.cols, cheats)
        len = cap ? geo.cols - cap - TerminalText.width(identity) : main - 5 - TerminalText.width(identity)
        ["#{R}┌#{W}#{rail(main)}", "#{identity}#{rail([len, 3].max)}"]
      end

      # Any number of status readouts, each on its own branch row, then the
      # cheatsheet rail and the corner.
      def bottom(readouts : Array(String), cheats : Array(Cheat), geo : Layout::Geometry) : Array(String)
        main = Layout.main_rail(geo.cols)
        rows = readouts.map { |text| right_branch(text, geo.cols) }
        rows << cheat_row(cheats, geo.cols)
        rows << "#{" " * (geo.cols - 1 - main)}#{mirrored_rail(main)}#{R}┘#{W}"
        rows
      end

      def compact_top(profile : Profile, cols : Int32) : String
        identity = "#{R}◈#{W} #{R}NOKIZARU#{W} #{R}//#{W} v#{VERSION}  ⟦ #{C}"
        target = TerminalText.truncate(TerminalText.sanitize(profile.target), [cols - 30, 1].max)
        "#{identity}#{target}#{W} ⟧"
      end

      def compact_status(status : String, cols : Int32) : String
        text = TerminalText.truncate(status, cols - 1)
        "#{" " * [cols - 1 - TerminalText.width(text), 0].max}#{text}"
      end

      def left_trunk(geo : Layout::Geometry, row : Int32) : String
        trunk(row - 2 - geo.branches, geo.rows)
      end

      def right_trunk(geo : Layout::Geometry, row : Int32) : String
        status_row = geo.status_row
        return "" if status_row.nil?

        offset = status_row - 1 - row
        offset < 0 ? "" : trunk(offset, geo.rows, blank: "")
      end

      private def branches(profile : Profile) : Array(Tuple(String, String))
        rows = [{"Target", profile.target}, {"IP Address", profile.ip},
                {"Modules", profile.modules}, {"Switches", profile.switches}]
        notice = profile.notice
        rows << {"Notice", notice} if notice
        rows
      end

      # The classic dotted-leader row, hung off the trunk as a tree branch.
      private def branch(label : String, value : String, cols : Int32) : String
        lead = "#{R}├─◈#{W} #{label}#{"." * (LABEL_WIDTH - label.size + 3)}⟦ "
        room = cols - 2 - TerminalText.width(lead) - 2
        "#{lead}#{C}#{TerminalText.truncate(TerminalText.sanitize(value), room)}#{W} ⟧"
      end

      private def right_branch(text : String, cols : Int32) : String
        fitted = TerminalText.truncate(text, cols - 5)
        "#{" " * (cols - 4 - TerminalText.width(fitted))}#{fitted} #{R}◈─┨#{W}"
      end

      # The cheatsheet in a bracket on the inner rail: a signal cap at the reference
      # column, dashes out to the bracket, then the spine. Its cap mirrors the
      # identity rail's cap above. Falls back to a plain right-aligned bracket only
      # when the sheet is too wide to seat a cap at this width.
      private def cheat_row(cheats : Array(Cheat), cols : Int32) : String
        bracket = cheat_bracket(cheats)
        cap = inner_cap(cols, cheats)
        return no_cap_cheats(bracket, cols) unless cap

        dashes = cols - 5 - TerminalText.width(bracket) - cap
        "#{" " * cap}#{R}▱▰▰#{W}#{FAINT_RED}#{"╌" * [dashes, 0].max}#{W}#{bracket}#{R}─┤#{W}"
      end

      private def no_cap_cheats(bracket : String, cols : Int32) : String
        fitted = TerminalText.truncate(bracket, cols - 3)
        "#{" " * [cols - 2 - TerminalText.width(fitted), 0].max}#{fitted}#{R}─┤#{W}"
      end

      private def cheat_bracket(cheats : Array(Cheat)) : String
        "#{R}┤#{W} #{cheatsheet(cheats)} #{R}├#{W}"
      end

      # The inner rail's cap column, the reference the identity rail mirrors at
      # cols-1-inner_cap: a design offset, pulled left of the cheatsheet bracket
      # when one would overlap, so the two inner rails stay a symmetric diagonal off
      # the outer main rails at every width. nil when it runs off-screen.
      private def inner_cap(cols : Int32, cheats : Array(Cheat)) : Int32?
        col = [cols - 20 - (cols * 2 // 5), cols - 6 - TerminalText.width(cheat_bracket(cheats))].min
        col < 0 ? nil : col
      end

      private def rail(len : Int32) : String
        solid, dashed = rail_parts(len)
        return "#{R}#{"─" * len}#{W}" if dashed < 0

        "#{R}#{"─" * solid}#{W}#{FAINT_RED}#{"╌" * dashed}#{W}#{R}▰▰▱#{W}"
      end

      private def mirrored_rail(len : Int32) : String
        solid, dashed = rail_parts(len)
        return "#{R}#{"─" * len}#{W}" if dashed < 0

        "#{R}▱▰▰#{W}#{FAINT_RED}#{"╌" * dashed}#{W}#{R}#{"─" * solid}#{W}"
      end

      # Solid for three fifths, dashed after, capped by the three signal cells.
      private def rail_parts(len : Int32) : Tuple(Int32, Int32)
        solid = len * 3 // 5
        {solid, len - 3 - solid}
      end

      private def trunk(offset : Int32, rows : Int32, blank : String = " ") : String
        return blank if offset < 0 || offset > Layout.trunk_length(rows) - 1

        offset < SOLID_TRUNK ? "#{R}│#{W}" : "#{FAINT_RED}╎#{W}"
      end

      # cheats join by Jekyll // Hyde's middle-dot separator; an unlit label greys
      # out, the key always carries the accent.
      private def cheatsheet(cheats : Array(Cheat)) : String
        cheats.map do |cheat|
          shown = cheat.lit? ? cheat.label : "#{FAINT}#{cheat.label}#{W}"
          "#{R}#{cheat.key}#{W} #{shown}"
        end.join("#{FAINT} · #{W}")
      end
    end
  end
end
