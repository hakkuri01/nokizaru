# frozen_string_literal: true

require 'timeout'
require_relative 'test_helper'

class HttpResultHelpersTest < Minitest::Test
  def test_ssl_error_messages_are_catalog_backed
    helper = helper_for(OpenSSL::SSL::SSLError.new('wrong version number'))

    assert_equal 'SSL/TLS handshake failed - server may not support HTTPS on this port',
                 helper.send(:parse_ssl_error, helper.error)
  end

  def test_io_error_messages_distinguish_closed_stream_and_broken_pipe
    closed = helper_for(IOError.new('closed stream'))
    broken = helper_for(IOError.new('Broken pipe'))
    generic = helper_for(IOError.new('read failed'))

    assert_equal 'Connection closed by server - target may not support HTTPS or dropped the connection',
                 closed.send(:handle_io_error, closed.error)
    assert_equal 'Connection reset - target closed the connection unexpectedly',
                 broken.send(:handle_io_error, broken.error)
    assert_equal 'I/O error: read failed', generic.send(:handle_io_error, generic.error)
  end

  def test_descriptor_closed_messages
    descriptor = helper_for(StandardError.new('descriptor closed'))

    assert descriptor.send(:descriptor_closed?)
    assert_equal 'Connection closed unexpectedly - target may have dropped the connection',
                 descriptor.send(:descriptor_message)
  end

  def test_timeout_detection_covers_timeout_error
    assert helper_for(Timeout::Error.new).send(:timeout_error?)
  end

  def test_timeout_detection_covers_errno_timeout
    assert helper_for(Errno::ETIMEDOUT.new).send(:timeout_error?)
  end

  def test_descriptor_helpers_return_nil_for_unrelated_errors
    helper = helper_for(StandardError.new('generic failure'))

    refute helper.send(:descriptor_closed?)
    assert_nil helper.send(:descriptor_message)
  end

  def test_parse_ssl_error_uses_fallback_for_unknown_ssl_messages
    helper = helper_for(OpenSSL::SSL::SSLError.new('unexpected alert'))

    assert_equal 'SSL/TLS error: unexpected alert', helper.send(:parse_ssl_error, helper.error)
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
  end
end
