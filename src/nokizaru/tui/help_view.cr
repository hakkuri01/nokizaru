require "../terminal_text"
require "./hud"
require "./view"

module Nokizaru
  module Tui
    # The flag and key reference, reachable with h from the form. The content
    # mirrors the classic --help, dressed in the dashboard's node and bracket
    # vocabulary and grouped like the form. Scrolls with j/k; q or h returns.
    module HelpView
      extend self

      R         = Hud::R
      C         = Hud::C
      W         = Hud::W
      FAINT     = Hud::FAINT
      FAINT_RED = Hud::FAINT_RED
      CHEATS    = [Hud::Cheat.new("j/k", "scroll"), Hud::Cheat.new("q", "back")]
      FLAGW     = 14

      # Sections of [flag, description]; the formats line names what the Formats
      # field accepts.
      SECTIONS = [
        {"MODULES", [
          {"--full", "Run every module"},
          {"--headers", "Response headers and target profile"},
          {"--sslinfo", "SSL certificate information"},
          {"--whois", "Whois / RDAP lookup"},
          {"--dns", "DNS enumeration"},
          {"--sub", "Sub-domain enumeration"},
          {"--arch", "Local tech fingerprint, enriched by a Wappalyzer key"},
          {"--crawl", "Crawl the target"},
          {"--dir", "Directory enumeration"},
          {"--wayback", "Wayback Machine snapshots"},
          {"--ps", "Fast TCP port scan"},
        ]},
        {"OPTIONS", [
          {"-w", "Wordlist: small, medium, large, or a path"},
          {"-e", "Extensions, comma separated (txt,php,xml)"},
          {"-dt", "Directory enum threads [50]"},
          {"-pt", "Port scan concurrency [50]"},
          {"-p", "Ports: 80,443,1000-65535 or all"},
          {"-T", "Base timeout / module budget seconds [30]"},
          {"-r", "Follow redirects during directory enum"},
          {"--insecure", "Skip TLS certificate verification for the target"},
          {"--headless", "Run with no TUI: JSON on stdout, progress on stderr"},
        ]},
        {"EXPORT", [
          {"--export", "Write results to the export directory"},
          {"-o", "Formats, comma separated: txt, json, html"},
          {"-cd", "Export directory for this run"},
          {"-of", "Export filename base for this run"},
        ]},
        {"KEYS", [
          {"j / k", "Move between fields (scroll results on the dashboard)"},
          {"← / →", "Move across the module chips"},
          {"space", "Toggle a switch or the focused module"},
          {"i", "Edit a text or number field"},
          {"esc", "Leave INSERT mode"},
          {"enter", "Run the scan"},
          {"tab", "Switch module tabs on the dashboard"},
          {"q", "Back one screen, or quit from the form"},
          {"h", "Open or close this help"},
          {"ctrl+c", "Quit from anywhere"},
          {"mouse", "Drag to select & copy; wheel scrolls the results"},
        ]},
      ]

      def frame(cols : Int32, rows : Int32, offset : Int32) : Array(String)
        geo = Layout.measure(cols, rows, 0)
        return View.tiny(cols, rows) if geo.mode.tiny?

        lines = content
        window = lines[clamp(offset, lines, geo), geo.pane_height]? || [] of String
        middle = {} of Int32 => String
        window.each_with_index { |line, index| middle[geo.pane_top + index] = line }
        top = Hud.identity_rows(geo, CHEATS) + ["#{R}├─◈#{W} #{R}Flags & Keys#{W}"]
        View.compose(geo, top, middle, Hud.bottom([status(offset, lines, geo)], CHEATS, geo))
      end

      def max_offset(cols : Int32, rows : Int32) : Int32
        geo = Layout.measure(cols, rows, 0)
        return 0 if geo.mode.tiny?

        [content.size - geo.pane_height, 0].max
      end

      private def clamp(offset : Int32, lines : Array(String), geo : Layout::Geometry) : Int32
        offset.clamp(0, [lines.size - geo.pane_height, 0].max)
      end

      private def status(offset : Int32, lines : Array(String), geo : Layout::Geometry) : String
        more = [lines.size - geo.pane_height, 0].max
        return "#{R}◈#{W} Flags & Keys" if more.zero?

        "#{R}◈#{W} Flags & Keys #{FAINT}#{offset.clamp(0, more)}/#{more}#{W}"
      end

      private def content : Array(String)
        rows = [] of String
        SECTIONS.each do |name, entries|
          rows << divider(name)
          entries.each { |flag, desc| rows << entry(flag, desc) }
          rows << ""
        end
        rows
      end

      private def divider(name : String) : String
        "#{FAINT_RED}── #{W}#{R}#{name}#{W} #{FAINT_RED}#{"─" * [28 - name.size, 1].max}#{W}"
      end

      private def entry(flag : String, desc : String) : String
        "  #{R}⟦#{W} #{C}#{flag.ljust(FLAGW)}#{W}#{R}⟧#{W}  #{desc}"
      end
    end
  end
end
