# frozen_string_literal: true

require_relative 'nokizaru/version'
require_relative 'nokizaru/ui'
require_relative 'nokizaru/progress_rail'
require_relative 'nokizaru/paths'
require_relative 'nokizaru/settings'
require_relative 'nokizaru/log'
require_relative 'nokizaru/interrupt_state'
require_relative 'nokizaru/cli_argv'
require_relative 'nokizaru/connection_pool'
require_relative 'nokizaru/http_client'
require_relative 'nokizaru/request_headers'
require_relative 'nokizaru/context'
require_relative 'nokizaru/export_manager'
require_relative 'nokizaru/findings/engine'
require_relative 'nokizaru/cli'

module Nokizaru
  # Always shut down the HTTP client pool on exit so long-running scans release connections
  at_exit do
    HTTPClient.shutdown
  rescue StandardError
    # Exit cleanup is best effort
  end
end
