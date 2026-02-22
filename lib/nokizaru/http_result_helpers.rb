# frozen_string_literal: true

module Nokizaru
  # Private helper methods shared by HttpResult
  module HttpResultHelpers
    private

    def descriptor_message
      return nil unless descriptor_closed?

      'Connection closed unexpectedly - target may have dropped the connection'
    end

    def io_descriptor_hint
      return nil unless @error.is_a?(IOError)

      message = @error.message.to_s
      return nil unless message.include?('descriptor closed') || message.include?('closed stream')

      'Try using HTTP instead of HTTPS'
    end

    def descriptor_hint
      return nil unless descriptor_closed?

      'Try using HTTP instead of HTTPS'
    end

    def descriptor_closed?
      message = @error.message.to_s
      message.include?('descriptor closed') || message.include?('Broken pipe')
    end

    def parse_ssl_error(error)
      msg = error.message

      Nokizaru::HTTPErrorCatalog::SSL_MESSAGES.each do |pattern, text|
        return text if msg.include?(pattern)
      end

      "SSL/TLS error: #{msg}"
    end

    def timeout_error?
      @error.is_a?(Errno::ETIMEDOUT) || @error.is_a?(Timeout::Error)
    end

    def handle_io_error(error)
      msg = error.message.to_s
      if msg.include?('closed stream') || msg.include?('descriptor')
        'Connection closed by server - target may not support HTTPS or dropped the connection'
      elsif msg.include?('Broken pipe')
        'Connection reset - target closed the connection unexpectedly'
      else
        "I/O error: #{msg}"
      end
    end
  end
end
