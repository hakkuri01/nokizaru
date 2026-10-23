# frozen_string_literal: true

module Nokizaru
  module TUI
    # Per-screen message handling for App: the opening animation, the form, the help page, and the dashboard.
    # Split from App so the router and its transitions stay small
    module AppScreens
      private

      def opening(message)
        case message
        when Messages::Resize then resize(message)
        when Messages::Tick then advance(message.now)
        when Messages::Key then message.name == 'ctrl+c' ? [:quit] : open_form
        end
      end

      # Marks dirty so the final clean frame draws when the reveal settles; otherwise the loop stops rendering
      # on the last glitched frame and leaves static artifacts behind
      def advance(now)
        @elapsed = now - @clock0
        @dirty = true
        nil
      end

      def open_form
        @screen = :form
        @dirty = true
        []
      end

      def on_form(message)
        case message
        when Messages::Resize then resize(message)
        when Messages::Key then form_key(message.name)
        end
      end

      # Ctrl+C quits from any form state, including INSERT and a launch that never went live
      def form_key(name)
        @dirty = true
        return [:quit] if name == 'ctrl+c'

        case @form.key(name)
        when :run then @form.launching = true
                       [:run_scan]
        when :quit then [:quit]
        when :help then show_help
        else []
        end
      end

      def show_help
        @help_offset = 0
        @screen = :help
        @dirty = true
        []
      end

      def on_help(message)
        case message
        when Messages::Resize then resize(message)
        when Messages::Key then help_key(message.name)
        end
      end

      def help_key(name)
        @dirty = true
        case name
        when 'q', 'h' then @screen = :form
        when 'j', 'down' then @help_offset = (@help_offset + 1).clamp(0, HelpView.max_offset(@cols, @rows))
        when 'k', 'up' then @help_offset = [@help_offset - 1, 0].max
        when 'ctrl+c' then return [:quit]
        end
        []
      end

      def on_dashboard(message)
        return dashboard_key(message.name) if message.is_a?(Messages::Key)

        resize(message) if message.is_a?(Messages::Resize)
        @dashboard.update(message)
        []
      end

      def dashboard_key(name)
        case name
        when 'q' then [:stop_and_form]
        when 'ctrl+c' then [:quit]
        else
          @dashboard.update(Messages::Key.new(name: name))
          []
        end
      end

      def resize(message)
        @cols = message.cols
        @rows = message.rows
        @form.resize(@cols, @rows)
        @dashboard&.update(message)
        @dirty = true
        []
      end
    end
  end
end
