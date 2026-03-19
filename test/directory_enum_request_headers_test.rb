# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumRequestHeadersTest < Minitest::Test
  FakeResponse = Struct.new(:status, :headers)

  class FakeClient
    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def get(url, headers: {})
      @requests << { method: :get, url: url, headers: headers }
      response = @responses.fetch(url)
      response.respond_to?(:call) ? response.call(headers) : response
    end

    def head(url, headers: {})
      @requests << { method: :head, url: url, headers: headers }
      response = @responses.fetch(url)
      response.respond_to?(:call) ? response.call(headers) : response
    end
  end

  def test_request_url_follows_same_scope_redirects_with_custom_headers
    client = FakeClient.new(
      'https://example.com/admin' => FakeResponse.new(302, { 'location' => '/dashboard' }),
      'https://example.com/dashboard' => FakeResponse.new(200, {})
    )

    response = Nokizaru::Modules::DirectoryEnum.send(
      :request_url,
      client,
      'https://example.com/admin',
      stop_state(allow_redirects: true)
    )

    assert_equal 200, response.status
    assert_equal 2, client.requests.length
    assert_equal 'PHPSESSID=abc123', client.requests[0][:headers]['Cookie']
    assert_equal 'PHPSESSID=abc123', client.requests[1][:headers]['Cookie']
  end

  def test_request_url_does_not_follow_cross_scope_redirects_with_custom_headers
    client = FakeClient.new(
      'https://example.com/admin' => FakeResponse.new(302, { 'location' => 'https://evil.example.net/landing' })
    )

    response = Nokizaru::Modules::DirectoryEnum.send(
      :request_url,
      client,
      'https://example.com/admin',
      stop_state(allow_redirects: true)
    )

    assert_equal 302, response.status
    assert_equal 1, client.requests.length
    assert_equal 'PHPSESSID=abc123', client.requests[0][:headers]['Cookie']
  end

  def test_follow_redirects_flag_help_text_is_directory_enum_specific
    desc = Nokizaru::CLIOptions::OPTION_DEFS.fetch(:r).fetch(:desc)

    assert_equal 'Follow redirects during directory enum [ Default : False ]', desc
    assert_includes Nokizaru::CLIClassInterface::HELP_EXTRA_ROWS,
                    ['-r', 'Follow redirects during directory enum [ Default : False ]']
  end

  private

  def stop_state(allow_redirects:)
    {
      request_method: :get,
      request_timeout: 2.0,
      request_headers: { 'Cookie' => 'PHPSESSID=abc123' },
      allow_redirects: allow_redirects
    }
  end
end
