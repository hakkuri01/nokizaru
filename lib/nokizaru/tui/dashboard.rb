# frozen_string_literal: true

module Nokizaru
  module TUI
    # The scan screen: one tab per module plus a Summary tab, results streaming on each tab's scaffold, the HUD
    # carrying the run profile and the live status line. A plain model driven by messages; the app owns q and quit
    class Dashboard
      include DashboardNav
      include ScanEvents

      PULSE_S = 0.12
      LABELS = { headers: 'Headers', sslinfo: 'SSL', whois: 'Whois', dns: 'DNS', sub: 'Subdomains', arch: 'Arch',
                 ps: 'Ports', crawl: 'Crawler', dir: 'Dir Enum', wayback: 'Wayback' }.freeze
      R = UI::R
      G = UI::G
      W = UI::W
      FAINT = Hud::FAINT

      attr_reader :profile, :tabs, :focus, :follow, :phase, :snapshot, :frame, :outcome, :failure

      def initialize(profile:, now:, cols: 80, rows: 24)
        @profile = profile
        @tabs = profile[:modules_enabled].map { |key| Tab.new(key, LABELS.fetch(key, key.to_s)) }
        @tabs << Tab.new(:summary, 'Summary')
        @by_key = @tabs.to_h { |tab| [tab.key, tab] }
        @started_at = now
        @focus = 0
        @follow = true
        @phase = :running
        @frame = 0
        @cols = cols
        @rows = rows
        @dirty = true
      end

      def update(message)
        case message
        when Messages::Key then on_key(message.name)
        when Messages::Resize then on_resize(message)
        when Messages::Tick then on_tick(message)
        when Messages::Lines then on_lines(message.items)
        when Messages::ScanDone then on_done(message)
        when Messages::ScanFailed then on_failed(message.reason)
        end
        nil
      end

      def view
        View.dashboard(self)
      end

      def dirty?
        @dirty
      end

      def clean!
        @dirty = false
      end

      def running?
        @phase == :running
      end

      def focused_tab
        @tabs[@focus]
      end

      def geometry
        Layout.measure(@cols, @rows, @profile[:notice] ? 5 : 4)
      end

      def status_text(width)
        case @phase
        when :running then @snapshot ? UI.run_status_line(@snapshot, frame_index: @frame, tty: true, width: width) : ''
        when :done then done_text(@outcome)
        else "#{R}⟦✘⟧#{W} #{TerminalText.sanitize(@failure.to_s)}"
        end
      end

      def done_text(outcome)
        text = "#{G}⟦+⟧#{W} Completed in #{UI::Y}#{format('%.2f', outcome.elapsed.to_f)}s#{W}"
        return text unless outcome.export_dir

        "#{text} #{R}//#{W} Exported #{UI::C}#{TerminalText.sanitize(outcome.export_dir)}#{W}"
      end

      def cheats
        [['tab', 'module', true], ['j/k', 'scroll', true], ['f', 'follow', @follow], ['q', 'back', true]]
      end

      private

      def on_resize(message)
        @cols = message.cols
        @rows = message.rows
        @dirty = true
      end

      def on_lines(items)
        summary = @by_key[:summary]
        items.each { |tag, text| (@by_key[tag] || summary).append(text) }
        if summary.state == :pending && !summary.lines.empty?
          summary.state = :running
          @focus = @tabs.length - 1 if @follow
        end
        @dirty = true
      end
    end
  end
end
