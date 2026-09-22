# frozen_string_literal: true

require_relative 'test_helper'

class WaybackHTTPTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback
  FakeResponse = Struct.new(:status, :body, :headers)

  def test_get_applies_caller_timeout_to_request
    observed_timeout = nil
    request = proc do |_uri, timeout_s: nil, **_kwargs|
      observed_timeout = timeout_s
      FakeResponse.new(200, 'ok', {})
    end

    Wayback::HTTP.stub(:request, request) do
      response = Wayback::HTTP.get(URI('https://web.archive.org/cdx'), timeout_s: 1.25)

      assert_equal 200, response.status
      assert_in_delta 1.25, observed_timeout
    end
  end

  def test_get_reports_timeout_without_propagating_it
    reported = false

    Wayback::HTTP.stub(:request, ->(*) { raise Timeout::Error, 'source deadline' }) do
      response = Wayback::HTTP.get(
        URI('https://web.archive.org/cdx'), timeout_s: 1.25, on_timeout: -> { reported = true }
      )

      assert_nil response
      assert reported
    end
  end

  def test_429_retries_three_total_attempts_without_retry_after
    attempts = 0
    request = proc do
      attempts += 1
      FakeResponse.new(429, 'retry', {})
    end

    Wayback::HTTP.stub(:request, request) do
      Wayback::HTTP.stub(:sleep, nil) do
        Wayback::HTTP.get(URI('https://web.archive.org/cdx'), timeout_s: 1.0)
      end
    end

    assert_equal 3, attempts
  end

  def test_retry_delay_uses_original_bounded_backoff
    assert_in_delta 0.2, Wayback::HTTP.retry_delay(1, nil)
    assert_in_delta 0.4, Wayback::HTTP.retry_delay(2, nil)

    Process.stub(:clock_gettime, 10.0) do
      assert_in_delta 0.15, Wayback::HTTP.retry_delay(2, 10.4)
    end
  end

  def test_retry_requires_request_budget
    response = FakeResponse.new(429, 'retry', {})

    assert Wayback::HTTP.retryable?(response, 1, nil, 0.251)
    refute Wayback::HTTP.retryable?(response, 1, nil, 0.25)
  end

  def test_request_preserves_http_client_transport_policy
    client = Object.new
    client.define_singleton_method(:with) { |**| raise 'transport retries must not be overridden' }
    client.define_singleton_method(:get) { |_url, **_options| FakeResponse.new(200, 'ok', {}) }

    Nokizaru::HTTPClient.stub(:for_host, client) do
      response = Wayback::HTTP.request(URI('https://web.archive.org/cdx'), timeout_s: 1.0)

      assert_equal 200, response.status
    end
  end
end
