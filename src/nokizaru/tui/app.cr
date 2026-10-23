require "../cli/options"
require "./profile"
require "./messages"
require "./form"
require "./form_view"
require "./scene"
require "./help_view"
require "./dashboard"

module Nokizaru
  module Tui
    # The top-level model: a router over four screens (opening, form, help,
    # dashboard). It performs transitions and emits commands the controller runs;
    # it owns no I/O and is driven by messages, so the whole interaction is testable
    # without a terminal. The Ruby app/app_screens pair is one class here.
    class App
      enum Screen
        Opening
        Form
        Help
        Dashboard
      end

      # The commands the model asks the controller to run.
      enum Command
        RunScan
        StopAndForm
        Quit
      end

      getter screen : Screen
      getter form : Form
      getter dashboard : Dashboard?
      getter cols : Int32
      getter rows : Int32

      def initialize(@form : Form, @banner : Array(String), now : Float64, opening : Bool = true, launch : Profile? = nil)
        @clock0 = now
        @elapsed = 0.0
        @cols = @form.cols
        @rows = @form.rows
        @help_offset = 0
        @dirty = true
        @dashboard = nil
        if launch
          # Power-user launch (§12a): open straight on the dashboard with the scan
          # already running. q still steps back to the (prefilled) form as it does
          # from any dashboard, so a quick double-tap exits.
          @screen = Screen::Dashboard
          @dashboard = Dashboard.new(launch, now, @cols, @rows)
        else
          @screen = opening ? Screen::Opening : Screen::Form
        end
      end

      def update(message : Messages::Message) : Array(Command)
        route(message)
      end

      def view : Array(String)
        case @screen
        when .opening? then Scene.frame(@banner, @cols, @rows, @elapsed, (@elapsed * 120).to_i)
        when .form?    then FormView.frame(@form)
        when .help?    then HelpView.frame(@cols, @rows, @help_offset)
        else                @dashboard.try(&.view) || [] of String
        end
      end

      def animating? : Bool
        return Scene.animating?(@elapsed) if @screen.opening?

        @screen.dashboard? && (@dashboard.try(&.running?) || false)
      end

      def dirty? : Bool
        return true if @dirty
        return animating? if @screen.opening?

        @screen.dashboard? && (@dashboard.try(&.dirty?) || false)
      end

      def clean! : Nil
        @dirty = false
        @dashboard.try(&.clean!) if @screen.dashboard?
      end

      # The typed options a launched scan runs with.
      def scan_options : CLI::Options
        @form.to_options
      end

      def enter_form(error : String? = nil) : Nil
        @form.launching = false
        @form.error = error
        @dashboard = nil
        @screen = Screen::Form
        @dirty = true
      end

      private def enter_dashboard(profile : Profile) : Nil
        @dashboard = Dashboard.new(profile, @clock0 + @elapsed, @cols, @rows)
        @form.launching = false
        @screen = Screen::Dashboard
        @dirty = true
      end

      private def route(message : Messages::Message) : Array(Command)
        return launch_outcome(message) if launch_outcome?(message)

        case @screen
        when .opening? then opening(message)
        when .form?    then on_form(message)
        when .help?    then on_help(message)
        else                on_dashboard(message)
        end
      end

      # A launch ends on the dashboard, or back on the form with the reason; a
      # failure raised before the scan went live is the second kind, since the
      # dashboard never opened to show it.
      private def launch_outcome?(message : Messages::Message) : Bool
        case message
        when Messages::ScanStarted, Messages::ScanAborted then true
        when Messages::ScanFailed                         then @form.launching?
        else                                                   false
        end
      end

      private def launch_outcome(message : Messages::Message) : Array(Command)
        case message
        when Messages::ScanStarted then enter_dashboard(message.profile)
        when Messages::ScanAborted then enter_form(message.reason)
        when Messages::ScanFailed  then enter_form(message.reason)
        end
        [] of Command
      end

      private def opening(message : Messages::Message) : Array(Command)
        case message
        when Messages::Resize then resize(message)
        when Messages::Tick   then advance(message.now)
        when Messages::Key    then message.name == "ctrl+c" ? [Command::Quit] : open_form
        else                       [] of Command
        end
      end

      # Marks dirty so the final clean frame draws when the reveal settles;
      # otherwise the loop stops rendering on the last glitched frame.
      private def advance(now : Float64) : Array(Command)
        @elapsed = now - @clock0
        @dirty = true
        [] of Command
      end

      private def open_form : Array(Command)
        @screen = Screen::Form
        @dirty = true
        [] of Command
      end

      private def on_form(message : Messages::Message) : Array(Command)
        case message
        when Messages::Resize then resize(message)
        when Messages::Key    then form_key(message.name)
        else                       [] of Command
        end
      end

      # Ctrl+C quits from any form state, including INSERT and a launch that never
      # went live.
      private def form_key(name : String) : Array(Command)
        @dirty = true
        return [Command::Quit] if name == "ctrl+c"

        case @form.key(name)
        when Form::Action::Run
          @form.launching = true
          [Command::RunScan]
        when Form::Action::Quit then [Command::Quit]
        when Form::Action::Help then show_help
        else                         [] of Command
        end
      end

      private def show_help : Array(Command)
        @help_offset = 0
        @screen = Screen::Help
        @dirty = true
        [] of Command
      end

      private def on_help(message : Messages::Message) : Array(Command)
        case message
        when Messages::Resize then resize(message)
        when Messages::Key    then help_key(message.name)
        else                       [] of Command
        end
      end

      private def help_key(name : String) : Array(Command)
        @dirty = true
        case name
        when "q", "h"    then @screen = Screen::Form
        when "j", "down" then @help_offset = (@help_offset + 1).clamp(0, HelpView.max_offset(@cols, @rows))
        when "k", "up"   then @help_offset = [@help_offset - 1, 0].max
        when "ctrl+c"    then return [Command::Quit]
        end
        [] of Command
      end

      private def on_dashboard(message : Messages::Message) : Array(Command)
        return dashboard_key(message.name) if message.is_a?(Messages::Key)

        resize(message) if message.is_a?(Messages::Resize)
        @dashboard.try(&.update(message))
        [] of Command
      end

      # q steps back one level from the dashboard to the (prefilled) form, from
      # which q quits; so a double-tap is a quick exit for a power-user launch,
      # with no special command. Ctrl+C is always a hard quit.
      private def dashboard_key(name : String) : Array(Command)
        case name
        when "q"      then [Command::StopAndForm]
        when "ctrl+c" then [Command::Quit]
        else
          @dashboard.try(&.update(Messages::Key.new(name)))
          [] of Command
        end
      end

      private def resize(message : Messages::Resize) : Array(Command)
        @cols = message.cols
        @rows = message.rows
        @form.resize(@cols, @rows)
        @dashboard.try(&.update(message))
        @dirty = true
        [] of Command
      end
    end
  end
end
