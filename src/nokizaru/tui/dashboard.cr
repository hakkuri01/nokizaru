require "../ui"
require "../terminal_text"
require "./hud"
require "./view"
require "./pane"
require "./tab"
require "./profile"
require "./progress"
require "./status_line"
require "./messages"

module Nokizaru
  module Tui
    # The scan screen: one tab per module plus a Summary tab, results streaming on
    # each tab's scaffold, the HUD carrying the run profile and the live status
    # line. A plain model driven by messages; the app owns q and quit. The Ruby
    # dashboard/keys(DashboardNav)/scan_events trio is one class here.
    class Dashboard
      PULSE_S = 0.12

      LABELS = {
        "headers" => "Headers", "sslinfo" => "SSL", "whois" => "Whois", "dns" => "DNS",
        "sub" => "Subdomains", "arch" => "Arch", "ps" => "Ports", "crawl" => "Crawler",
        "dir" => "Dir Enum", "wayback" => "Wayback",
      }

      NEXT     = ["tab", "l", "right"]
      PREVIOUS = ["shift+tab", "h", "left"]
      LINES    = {"j" => 1, "down" => 1, "k" => -1, "up" => -1}

      R = UI::R
      G = UI::G
      W = UI::W

      enum Lifecycle
        Running
        Done
        Failed
      end

      getter profile : Profile
      getter tabs : Array(Tab)
      getter focus : Int32

      @by_key : Hash(String, Tab)
      @snapshot : Progress::Snapshot?
      @statuses : Hash(String, String)
      @outcome : Messages::ScanDone?
      @failure : String?

      def initialize(@profile : Profile, now : Float64, @cols : Int32 = 80, @rows : Int32 = 24)
        @tabs = @profile.modules_enabled.map { |key| Tab.new(key, LABELS[key]? || key) }
        @tabs << Tab.new("summary", "Summary")
        @by_key = @tabs.to_h { |tab| {tab.key, tab} }
        @started_at = now
        @focus = 0
        @follow = true
        @phase = Lifecycle::Running
        @frame = 0
        @snapshot = nil
        @statuses = {} of String => String
        @outcome = nil
        @failure = nil
        @dirty = true
      end

      def update(message : Messages::Message) : Nil
        case message
        when Messages::Key        then on_key(message.name)
        when Messages::Resize     then on_resize(message)
        when Messages::Tick       then on_tick(message)
        when Messages::Lines      then on_lines(message.items)
        when Messages::ScanDone   then on_done(message)
        when Messages::ScanFailed then on_failed(message.reason)
        end
      end

      def view : Array(String)
        View.dashboard(self)
      end

      def dirty? : Bool
        @dirty
      end

      def clean! : Nil
        @dirty = false
      end

      def running? : Bool
        @phase.running?
      end

      def focused_tab : Tab
        @tabs[@focus]
      end

      def geometry : Layout::Geometry
        Layout.measure(@cols, @rows, @profile.notice ? 5 : 4)
      end

      def status_text(width : Int32) : String
        case @phase
        when .running? then (snapshot = @snapshot) ? StatusLine.render(snapshot, @frame, width) : ""
        when .done?    then done_text(@outcome)
        else                "#{R}⟦✘⟧#{W} #{TerminalText.sanitize(@failure.to_s)}"
        end
      end

      def cheats : Array(Hud::Cheat)
        [Hud::Cheat.new("tab", "module"), Hud::Cheat.new("j/k", "scroll"),
         Hud::Cheat.new("f", "follow", @follow), Hud::Cheat.new("q", "back")]
      end

      private def done_text(outcome : Messages::ScanDone?) : String
        return "" if outcome.nil?

        text = "#{G}⟦+⟧#{W} Completed in #{UI::Y}#{"%.2f" % (outcome.elapsed || 0.0)}s#{W}"
        dir = outcome.export_dir
        return text unless dir

        "#{text} #{R}//#{W} Exported #{UI::C}#{TerminalText.sanitize(dir)}#{W}"
      end

      # --- navigation (the Ruby DashboardNav) ---

      private def on_key(name : String) : Nil
        navigate(name)
        @dirty = true
      end

      private def navigate(name : String) : Nil
        if NEXT.includes?(name)
          cycle(1)
        elsif PREVIOUS.includes?(name)
          cycle(-1)
        elsif name.matches?(/\A[0-9]\z/)
          jump(name == "0" ? 9 : name.to_i - 1)
        elsif delta = LINES[name]?
          scroll(delta)
        else
          page(name)
        end
      end

      private def page(name : String) : Nil
        height = geometry.pane_height
        case name
        when "ctrl+d"    then scroll(height // 2)
        when "ctrl+u"    then scroll(-(height // 2))
        when "pgdn"      then scroll(height)
        when "pgup"      then scroll(-height)
        when "g", "home" then focused_tab.scroll_to_top
        when "G", "end"  then focused_tab.follow_tail
        when "f"         then toggle_follow
        end
      end

      private def cycle(delta : Int32) : Nil
        @focus = (@focus + delta) % @tabs.size
        @follow = false
      end

      private def jump(index : Int32) : Nil
        return unless index < @tabs.size

        @focus = index
        @follow = false
      end

      # The pane reserves a head row and a spine gutter, so results scroll in the
      # rows below the head.
      private def scroll(delta : Int32) : Nil
        geo = geometry
        focused_tab.scroll(delta, [geo.pane_width - Pane::GUTTER, 1].max, [geo.pane_height - 1, 0].max)
      end

      private def toggle_follow : Nil
        @follow = !@follow
        follow_target if @follow
      end

      private def on_resize(message : Messages::Resize) : Nil
        @cols = message.cols
        @rows = message.rows
        @dirty = true
      end

      private def on_lines(items : Array(Messages::FeedLine)) : Nil
        summary = @by_key["summary"]
        items.each do |line|
          tag = line.tag
          tab = (tag ? @by_key[tag]? : nil) || summary
          tab.append(line.text)
        end
        if summary.state.pending? && !summary.lines.empty?
          summary.state = Tab::State::Running
          @focus = @tabs.size - 1 if @follow
        end
        @dirty = true
      end

      # --- scan following (the Ruby ScanEvents) ---

      private def on_tick(message : Messages::Tick) : Nil
        frame = ((message.now - @started_at) / PULSE_S).floor.to_i
        @dirty = true if running? && frame != @frame
        @frame = frame
        snapshot = message.snapshot
        observe(snapshot, message.statuses) if running? && snapshot
      end

      private def observe(snapshot : Progress::Snapshot, statuses : Hash(String, String)) : Nil
        return if snapshot == @snapshot && statuses == @statuses

        @snapshot = snapshot
        @statuses = statuses
        snapshot.modules.each do |key, state|
          tab = @by_key[key]?
          tab.state = tab_state(key, state.phase) if tab
        end
        follow_target
        @dirty = true
      end

      # A module that finished but stored a skip (no API key) or a failure shows as such.
      private def tab_state(key : String, phase : Progress::Phase) : Tab::State
        state = map_phase(phase)
        return state unless state.done?

        status = @statuses[key]? || ""
        return Tab::State::Skipped if status.starts_with?("skipped")

        status == "failed" ? Tab::State::Failed : Tab::State::Done
      end

      private def map_phase(phase : Progress::Phase) : Tab::State
        case phase
        when .running? then Tab::State::Running
        when .done?    then Tab::State::Done
        when .failed?  then Tab::State::Failed
        when .skipped? then Tab::State::Skipped
        else                Tab::State::Pending
        end
      end

      private def follow_target : Nil
        return unless @follow

        if running?
          current = @snapshot.try(&.current_module)
          target = current ? @tabs.index { |tab| tab.key == current } : nil
        else
          target = @tabs.size - 1
        end
        return unless target

        @focus = target if !running? || @tabs[target].state.running?
      end

      private def on_done(message : Messages::ScanDone) : Nil
        @outcome = message
        return finish(Lifecycle::Done) if message.status.zero?

        @failure = "Scan stopped (exit #{message.status})"
        finish(Lifecycle::Failed)
      end

      private def on_failed(reason : String) : Nil
        @failure = reason
        finish(Lifecycle::Failed)
      end

      private def finish(phase : Lifecycle) : Nil
        @phase = phase
        @tabs.each do |tab|
          tab.state = Tab::State::Skipped if tab.state.pending?
          tab.state = Tab::State::Failed if tab.state.running? && tab.key != "summary"
        end
        @by_key["summary"].state = phase.done? ? Tab::State::Done : Tab::State::Failed
        follow_target
        @dirty = true
      end
    end
  end
end
