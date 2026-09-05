# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumBatchTest < Minitest::Test
  DirectoryEnum = Nokizaru::Modules::DirectoryEnum
  Response = Struct.new(:status, :body, :version, keyword_init: true)

  def test_next_request_batch_obeys_current_concurrency_and_request_budget
    runtime = batch_runtime(%w[a b c d], current: 2, max_requests: 3)

    assert_equal %w[a b], DirectoryEnum.__send__(:next_request_batch, runtime)
    assert_equal 2, runtime[:issued]
    assert_equal ['c'], DirectoryEnum.__send__(:next_request_batch, runtime)
    assert_equal 3, runtime[:issued]
    assert_empty DirectoryEnum.__send__(:next_request_batch, runtime)
  end

  def test_request_urls_preserves_order_for_batched_gets
    client = BatchGetClient.new
    urls = %w[https://example.com/a https://example.com/b]
    stop_state = { request_method: :get, request_headers: {}, allow_redirects: false }

    responses = DirectoryEnum.__send__(:request_urls, client, urls, stop_state)

    assert_equal urls, responses.map(&:body)
    assert_equal [[urls, {}]], client.calls
  end

  def test_request_urls_uses_manual_redirect_fallback_for_custom_headers_with_redirects
    client = RedirectFallbackClient.new
    urls = %w[https://example.com/a https://example.com/b]
    stop_state = { request_method: :get, request_headers: { 'X-Test' => '1' }, allow_redirects: true }

    responses = DirectoryEnum.__send__(:request_urls, client, urls, stop_state)

    assert_equal urls, responses.map(&:body)
    assert_equal [[urls.first, { 'X-Test' => '1' }], [urls.last, { 'X-Test' => '1' }]], client.single_get_calls
    assert_empty client.batch_get_calls
  end

  def test_request_url_does_not_drop_headers_after_request_errors
    stop_state = { request_method: :get, request_headers: { 'X-Test' => '1' }, allow_redirects: false }

    [NoMethodError, ArgumentError].each do |error_class|
      assert_raises(error_class) do
        DirectoryEnum.__send__(:request_url, HeaderErrorClient.new(error_class), 'https://example.com/a', stop_state)
      end
    end
  end

  def test_head_batch_confirms_multiple_candidate_statuses_in_original_order
    client = MultiCandidateHeadClient.new
    urls = %w[https://example.com/a https://example.com/b https://example.com/c https://example.com/d]
    stop_state = { request_method: :head, request_headers: {}, allow_redirects: false }

    responses = DirectoryEnum.__send__(:request_urls, client, urls, stop_state)

    assert_equal [200, 404, 200, 200], responses.map(&:status)
    assert_equal %w[confirmed-a head-b confirmed-c confirmed-d], responses.map(&:body)
    assert_equal [[urls[0], urls[2], urls[3]]], client.get_calls
  end

  def test_batch_dispatch_candidate_requires_https_without_manual_redirect_headers
    stop_state = { request_headers: {}, allow_redirects: false }

    assert DirectoryEnum.__send__(:batch_dispatch_candidate?, { normalized_target: 'https://example.com' }, stop_state)
    refute DirectoryEnum.__send__(:batch_dispatch_candidate?, { normalized_target: 'http://example.com' }, stop_state)

    header_redirect_state = { request_headers: { 'X-Test' => '1' }, allow_redirects: true }

    refute DirectoryEnum.__send__(
      :batch_dispatch_candidate?, { normalized_target: 'https://example.com' }, header_redirect_state
    )
  end

  def test_http2_batch_responses_detects_confirmed_protocol
    h2 = Response.new(status: 200, body: 'ok', version: '2.0')
    h1 = Response.new(status: 200, body: 'ok', version: '1.1')

    assert DirectoryEnum.__send__(:http2_batch_responses?, [Nokizaru::HttpResult.new(h2)])
    refute DirectoryEnum.__send__(:http2_batch_responses?, [Nokizaru::HttpResult.new(h1)])
  end

  def test_batch_limit_probes_small_until_http2_confirmed
    runtime = { concurrency_state: { current: 10 } }

    assert_equal 2, DirectoryEnum.__send__(:batch_limit, false, runtime)
    assert_nil DirectoryEnum.__send__(:batch_limit, true, runtime)
  end

  def test_decorate_stats_exports_dispatch_telemetry
    stats = {}
    runtime = dispatch_stats_runtime

    DirectoryEnum.__send__(:decorate_dir_output_stats!, runtime, stats)

    assert_equal 'http2_batch', stats[:dispatch_mode]
    assert_equal true, stats[:dispatch_http2_confirmed]
    assert_equal '', stats[:dispatch_fallback_reason]
    assert_equal '', stats[:stop_status_code_shape]

    exported = DirectoryEnum.__send__(:dir_runtime_adaptive_stats, stats)

    assert_equal 'http2_batch', exported['dispatch_mode']
    assert_equal true, exported['dispatch_http2_confirmed']
    assert_equal '', exported['dispatch_fallback_reason']
    assert_nil exported['stop_status_code_shape']
  end

  def batch_runtime(urls, current:, max_requests:)
    {
      mutex: Mutex.new,
      issued: 0,
      start_time: Time.now,
      stop_state: { stop: false, budgets: { max_requests: max_requests } },
      concurrency_state: { current: current },
      queue: DirectoryEnum.__send__(:build_work_queue, urls),
      activity_state: {}
    }
  end

  def dispatch_stats_runtime
    confidence_context = DirectoryEnum.__send__(:init_confidence_context, { options: { ctx: nil } })
    {
      confidence_context: confidence_context,
      adaptation_state: {},
      extension_state: { enabled: false, reason: nil },
      dispatch_state: { mode: 'http2_batch', http2_confirmed: true, fallback_reason: nil },
      concurrency_state: { current: 50 },
      first_actionable_at: nil,
      first_actionable_count: nil,
      stop_status_code_shape: nil
    }
  end

  class BatchGetClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def get(*urls, headers: {})
      @calls << [urls, headers]
      urls.map { |url| Response.new(status: 200, body: url) }
    end
  end

  class RedirectFallbackClient
    attr_reader :single_get_calls, :batch_get_calls

    def initialize
      @single_get_calls = []
      @batch_get_calls = []
    end

    def get(*urls, headers: {})
      if urls.length == 1
        @single_get_calls << [urls.first, headers]
      else
        @batch_get_calls << [urls, headers]
      end
      responses = urls.map { |url| Response.new(status: 200, body: url) }
      urls.length == 1 ? responses.first : responses
    end
  end

  class MultiCandidateHeadClient
    attr_reader :get_calls

    def initialize
      @get_calls = []
    end

    def head(*urls, headers: {})
      _headers = headers
      statuses = [200, 404, 301, 403]
      urls.map.with_index { |_url, index| Response.new(status: statuses[index], body: "head-#{('a'.ord + index).chr}") }
    end

    def get(*urls, headers: {})
      _headers = headers
      @get_calls << urls
      urls.map do |url|
        key = url.split('/').last
        Response.new(status: 200, body: "confirmed-#{key}")
      end
    end
  end

  class HeaderErrorClient
    def initialize(error_class)
      @error_class = error_class
    end

    def get(_url, headers: nil)
      return Response.new(status: 200, body: 'headers dropped') unless headers

      raise @error_class, 'request failed'
    end
  end
end
