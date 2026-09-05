# frozen_string_literal: true

require_relative 'test_helper'

class ConnectionPoolTest < Minitest::Test
  def test_ssl_options_allow_httpx_default_alpn_protocols
    options = Nokizaru::ConnectionPool.new.send(:ssl_options, true)

    refute_includes options.keys, :alpn_protocols
  end

  def test_ssl_options_preserve_explicit_verification_disable
    options = Nokizaru::ConnectionPool.new.send(:ssl_options, false)

    assert_equal OpenSSL::SSL::VERIFY_NONE, options[:verify_mode]
    refute_includes options.keys, :alpn_protocols
  end

  def test_default_headers_do_not_send_http1_connection_header_over_http2
    keys = Nokizaru::ConnectionPool::DEFAULT_HEADERS.keys.map(&:downcase)

    refute_includes keys, 'connection'
  end
end
