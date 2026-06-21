# frozen_string_literal: true

require 'timeout'
require_relative 'test_helper'

class HttpResultHelpersTest < Minitest::Test
  def test_ssl_error_messages_and_hints_are_catalog_backed
    helper = helper_for(OpenSSL::SSL::SSLError.new('wrong version number'))

    assert_equal 'SSL/TLS handshake failed - server may not support HTTPS on this port',
                 helper.call_private(:parse_ssl_error, helper.error)
    assert_equal 'Try using HTTP instead of HTTPS', helper.call_private(:descriptor_hint_for_ssl_message)
  end

  def test_io_error_messages_distinguish_closed_stream_and_broken_pipe
    closed = helper_for(IOError.new('closed stream'))
    broken = helper_for(IOError.new('Broken pipe'))
    generic = helper_for(IOError.new('read failed'))

    assert_equal 'Connection closed by server - target may not support HTTPS or dropped the connection',
                 closed.call_private(:handle_io_error, closed.error)
    assert_equal 'Connection reset - target closed the connection unexpectedly',
                 broken.call_private(:handle_io_error, broken.error)
    assert_equal 'I/O error: read failed', generic.call_private(:handle_io_error, generic.error)
  end

  def test_descriptor_closed_messages_and_hints
    descriptor = helper_for(StandardError.new('descriptor closed'))

    assert descriptor.call_private(:descriptor_closed?)
    assert_equal 'Connection closed unexpectedly - target may have dropped the connection',
                 descriptor.call_private(:descriptor_message)
    assert_equal 'Try using HTTP instead of HTTPS', descriptor.call_private(:descriptor_hint)
  end

  def test_timeout_detection_covers_timeout_error
    assert helper_for(Timeout::Error.new).call_private(:timeout_error?)
  end

  def test_timeout_detection_covers_errno_timeout
    assert helper_for(Errno::ETIMEDOUT.new).call_private(:timeout_error?)
  end

  def test_descriptor_helpers_return_nil_for_unrelated_errors
    helper = helper_for(StandardError.new('generic failure'))

    refute helper.call_private(:descriptor_closed?)
    assert_nil helper.call_private(:descriptor_message)
    assert_nil helper.call_private(:descriptor_hint)
    assert_nil helper.call_private(:io_descriptor_hint)
  end

  def test_parse_ssl_error_uses_fallback_for_unknown_ssl_messages
    helper = helper_for(OpenSSL::SSL::SSLError.new('unexpected alert'))

    assert_equal 'SSL/TLS error: unexpected alert', helper.call_private(:parse_ssl_error, helper.error)
  end

  private

  def helper_for(error)
    HelperHost.new(error)
  end

  class HelperHost
    include Nokizaru::HttpResultHelpers

    attr_reader :error

    def initialize(error)
      @error = error
    end

    def call_private(name, *)
      send(name, *)
    end

    def descriptor_hint_for_ssl_message
      Nokizaru::HTTPErrorCatalog::SSL_HINTS.each do |pattern, hint|
        return hint if @error.message.include?(pattern)
      end
      nil
    end
  end
end
