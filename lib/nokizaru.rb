# frozen_string_literal: true

require_relative 'nokizaru/version'
require_relative 'nokizaru/paths'
require_relative 'nokizaru/settings'
require_relative 'nokizaru/log'
require_relative 'nokizaru/connection_pool'
require_relative 'nokizaru/http_client'
require_relative 'nokizaru/context'
require_relative 'nokizaru/workspace'
require_relative 'nokizaru/cache_store'
require_relative 'nokizaru/diff'
require_relative 'nokizaru/export_manager'
require_relative 'nokizaru/findings/engine'
require_relative 'nokizaru/cli'

module Nokizaru
  # Ensure connections are properly closed on exit
  # Always attempt client pool shutdown so long-running scans exit cleanly
  at_exit do
    HTTPClient.shutdown
  rescue StandardError
    # Ignore shutdown errors
  end
end
