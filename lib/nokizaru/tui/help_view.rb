# frozen_string_literal: true

module Nokizaru
  module TUI
    # The flag and key reference, reachable with h from the form. The content mirrors the classic --help, dressed
    # in the dashboard's node and bracket vocabulary and grouped like the form. Scrolls with j/k; q or h returns
    module HelpView
      module_function

      R = Hud::R
      C = Hud::C
      W = Hud::W
      FAINT = Hud::FAINT
      FAINT_RED = Hud::FAINT_RED
      CHEATS = [%w[j/k scroll], %w[q back]].freeze
      FLAGW = 14

      # Sections of [flag, description]; the formats line names what the Formats field accepts
      SECTIONS = [
        ['MODULES', [
          ['--full', 'Run every module'],
          ['--headers', 'Response headers and target profile'],
          ['--sslinfo', 'SSL certificate information'],
          ['--whois', 'Whois / RDAP lookup'],
          ['--dns', 'DNS enumeration'],
          ['--sub', 'Sub-domain enumeration'],
          ['--arch', 'Architecture fingerprinting (needs a Wappalyzer key)'],
          ['--crawl', 'Crawl the target'],
          ['--dir', 'Directory enumeration'],
          ['--wayback', 'Wayback Machine snapshots'],
          ['--ps', 'Fast TCP port scan']
        ]],
        ['OPTIONS', [
          ['-w', 'Wordlist: small, medium, large, or a path'],
          ['-e', 'Extensions, comma separated (txt,php,xml)'],
          ['-dt', 'Directory enum threads [50]'],
          ['-pt', 'Port scan concurrency [50]'],
          ['-p', 'Ports: 80,443,1000-65535 or all'],
          ['-T', 'Base timeout / module budget seconds [30]'],
          ['-r', 'Follow redirects during directory enum'],
          ['-s', 'Verify SSL during directory enum']
        ]],
        ['EXPORT', [
          ['--export', 'Write results to the export directory'],
          ['-o', 'Formats, comma separated: txt, json, html'],
          ['-cd', 'Export directory for this run'],
          ['-of', 'Export filename base for this run']
        ]],
        ['KEYS', [
          ['j / k', 'Move between fields (scroll results on the dashboard)'],
          ['← / →', 'Move across the module chips'],
          ['space', 'Toggle a switch or the focused module'],
          ['i', 'Edit a text or number field'],
          ['esc', 'Leave INSERT mode'],
          ['enter', 'Run the scan'],
          ['tab', 'Switch module tabs on the dashboard'],
          ['q', 'Back one screen, or quit from the form'],
          ['h', 'Open or close this help'],
          ['ctrl+c', 'Quit from anywhere'],
          ['mouse', 'Drag to select & copy; wheel scrolls the results']
        ]]
      ].freeze

      def frame(cols, rows, offset)
        geo = Layout.measure(cols, rows, 0)
        return View.tiny(cols, rows) if geo.mode == :tiny

        lines = content
        window = lines[clamp(offset, lines, geo), geo.pane_height] || []
        middle = window.each_with_index.to_h { |line, index| [geo.pane_top + index, line] }
        top = Hud.identity_rows(geo, CHEATS) + ["#{R}├─◈#{W} #{R}Flags & Keys#{W}"]
        View.compose(geo, top, middle, Hud.bottom(status(offset, lines, geo), CHEATS, geo))
      end

      def max_offset(cols, rows)
        geo = Layout.measure(cols, rows, 0)
        return 0 if geo.mode == :tiny

        [content.length - geo.pane_height, 0].max
      end

      def clamp(offset, lines, geo)
        offset.clamp(0, [lines.length - geo.pane_height, 0].max)
      end

      def status(offset, lines, geo)
        more = [lines.length - geo.pane_height, 0].max
        return "#{R}◈#{W} Flags & Keys" if more.zero?

        "#{R}◈#{W} Flags & Keys #{FAINT}#{offset.clamp(0, more)}/#{more}#{W}"
      end

      def content
        rows = []
        SECTIONS.each do |name, entries|
          rows << divider(name)
          entries.each { |flag, desc| rows << entry(flag, desc) }
          rows << ''
        end
        rows
      end

      def divider(name)
        "#{FAINT_RED}── #{W}#{R}#{name}#{W} #{FAINT_RED}#{'─' * [28 - name.length, 1].max}#{W}"
      end

      def entry(flag, desc)
        "  #{R}⟦#{W} #{C}#{flag.ljust(FLAGW)}#{W}#{R}⟧#{W}  #{desc}"
      end
    end
  end
end
