# frozen_string_literal: true

require_relative 'test_helper'

class WaybackHTTPTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback
  FakeResponse = Struct.new(:status, :body)

  def test_get_applies_caller_timeout_to_request
    observed_timeout = nil

    request_stub = proc do |_uri, timeout_s: nil, **_kwargs|
      observed_timeout = timeout_s
      FakeResponse.new(200, 'ok')
    end

    with_http_stub(:request, request_stub) do
      response = Wayback::HTTP.get(URI('https://web.archive.org/cdx'), timeout_s: 1.25)

      assert_equal 200, response.status
      assert_equal 1.25, observed_timeout
    end
  end

  def test_retry_loop_stops_without_budget_for_second_attempt
    attempts = 0
    request_stub = proc do
      attempts += 1
      FakeResponse.new(500, 'retry')
    end

    with_http_stub(:request, request_stub) do
      Wayback::HTTP.get(URI('https://web.archive.org/cdx'), timeout_s: 0.05)
    end

    assert_equal 1, attempts
  end

  private

  def with_http_stub(method_name, value)
    original = Wayback::HTTP.method(method_name)
    Wayback::HTTP.singleton_class.send(:define_method, method_name) do |*args, **kwargs|
      value.respond_to?(:call) ? value.call(*args, **kwargs) : value
    end
    yield
  ensure
    Wayback::HTTP.singleton_class.send(:define_method, method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end
end
