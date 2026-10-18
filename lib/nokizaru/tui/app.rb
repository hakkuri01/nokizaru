# frozen_string_literal: true

module Nokizaru
  module TUI
    # The top-level model: a router over four screens (opening, form, help, dashboard). It performs transitions
    # and emits commands the controller runs (:run_scan, :stop_and_form, :quit); it owns no I/O and is driven by
    # messages, so the whole interaction is testable without a terminal
    class App
      include AppScreens

      attr_reader :screen, :form, :dashboard, :cols, :rows

      def initialize(form:, banner:, now:, opening: true)
        @form = form
        @banner = banner
        @clock0 = now
        @elapsed = 0.0
        @cols = form.cols
        @rows = form.rows
        @screen = opening ? :opening : :form
        @help_offset = 0
        @dirty = true
      end

      def update(message)
        Array(route(message))
      end

      def view
        case @screen
        when :opening then Scene.frame(@form.profile, @banner, @cols, @rows, @elapsed, (@elapsed * 120).to_i)
        when :form then FormView.frame(@form)
        when :help then HelpView.frame(@cols, @rows, @help_offset)
        else @dashboard.view
        end
      end

      def animating?
        return Scene.animating?(@elapsed) if @screen == :opening

        @screen == :dashboard && @dashboard.running?
      end

      def dirty?
        return true if @dirty
        return animating? if @screen == :opening

        @screen == :dashboard && @dashboard.dirty?
      end

      def clean!
        @dirty = false
        @dashboard&.clean! if @screen == :dashboard
      end

      def scan_request
        @form.to_request
      end

      def enter_dashboard(profile)
        @dashboard = Dashboard.new(profile: profile, now: @clock0 + @elapsed, cols: @cols, rows: @rows)
        @form.launching = false
        @screen = :dashboard
        @dirty = true
      end

      def enter_form(error: nil)
        @form.launching = false
        @form.error = error
        @dashboard = nil
        @screen = :form
        @dirty = true
      end

      private

      def route(message)
        return launch_outcome(message) if launch_outcome?(message)

        case @screen
        when :opening then opening(message)
        when :form then on_form(message)
        when :help then on_help(message)
        else on_dashboard(message)
        end
      end

      # A launch ends on the dashboard, or back on the form with the reason; a failure raised before the scan went
      # live is the second kind, since the dashboard never opened to show it
      def launch_outcome?(message)
        case message
        when Messages::ScanStarted, Messages::ScanAborted then true
        when Messages::ScanFailed then @form.launching
        else false
        end
      end

      def launch_outcome(message)
        message.is_a?(Messages::ScanStarted) ? enter_dashboard(message.profile) : enter_form(error: message.reason)
        []
      end
    end
  end
end
