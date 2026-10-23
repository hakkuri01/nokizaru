# frozen_string_literal: true

require_relative 'terminal_text'
require_relative 'banner'
require_relative 'ui'
require_relative 'interrupt_state'
require_relative 'tui/messages'
require_relative 'tui/layout'
require_relative 'tui/hud'
require_relative 'tui/tab'
require_relative 'tui/capture'
require_relative 'tui/feed'
require_relative 'tui/decoder'
require_relative 'tui/screen'
require_relative 'tui/terminal'
require_relative 'tui/pane'
require_relative 'tui/view'
require_relative 'tui/keys'
require_relative 'tui/scan_events'
require_relative 'tui/dashboard'
require_relative 'tui/scene'
require_relative 'tui/form_command'
require_relative 'tui/form_keys'
require_relative 'tui/form'
require_relative 'tui/form_view'
require_relative 'tui/help_view'
require_relative 'tui/app_screens'
require_relative 'tui/app'
require_relative 'tui/program'
require_relative 'tui/session'

module Nokizaru
  # The interactive dashboard app: an animated opening, a vim-motion command form, then the scan dashboard.
  # It runs only on a terminal; piped or redirected runs keep the classic one-shot line output
  module TUI
    module_function

    def enabled?(input: $stdin, output: $stdout)
      input.respond_to?(:tty?) && input.tty? && output.respond_to?(:tty?) && output.tty?
    end

    def run(options, argv = [])
      Session.new(options: options, argv: argv).run
    end
  end
end
