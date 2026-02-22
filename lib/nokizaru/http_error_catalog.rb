# frozen_string_literal: true

module Nokizaru
  # Shared message catalogs for HTTP transport error normalization
  module HTTPErrorCatalog
    SSL_HINTS = {
      'wrong version number' => 'Try using HTTP instead of HTTPS',
      'record layer failure' => 'Try using HTTP instead of HTTPS',
      'certificate verify failed' => 'Use -s flag to disable SSL verification (testing only)'
    }.freeze

    SSL_MESSAGES = {
      'wrong version number' => 'SSL/TLS handshake failed - server may not support HTTPS on this port',
      'certificate verify failed' => 'SSL certificate verification failed - likely self-signed certificate',
      'tlsv1 alert' => 'SSL/TLS version mismatch - server requires different TLS version',
      'record layer failure' => 'SSL/TLS handshake failed - server does not support HTTPS on this port'
    }.freeze

    SIMPLE_MESSAGES = {
      Errno::ECONNREFUSED => 'Connection refused - target is not listening on this port',
      SocketError => 'DNS resolution failed - could not resolve hostname'
    }.freeze
  end
end
