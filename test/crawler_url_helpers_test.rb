# frozen_string_literal: true

require_relative 'test_helper'

class CrawlerURLHelpersTest < Minitest::Test
  Crawler = Nokizaru::Modules::Crawler

  def test_url_filter_rejects_fragment_script_mail_and_malformed_links
    assert_nil Crawler.send(:url_filter, 'https://example.com/app', '#section')
    assert_nil Crawler.send(:url_filter, 'https://example.com/app', 'javascript:alert(1)')
    assert_nil Crawler.send(:url_filter, 'https://example.com/app', 'mailto:test@example.com')
    assert_nil Crawler.send(:url_filter, 'not a url', 'admin')
  end

  def test_url_filter_resolves_relative_links_against_page_directory
    assert_equal 'https://example.com/app/admin', Crawler.send(:url_filter, 'https://example.com/app', 'admin')
    assert_equal 'https://example.com/app/static/app.css',
                 Crawler.send(:url_filter, 'https://example.com/app/page', '../static/app.css')
  end

  def test_internal_link_allows_same_registrable_domain_and_rejects_external_hosts
    host = Crawler.send(:target_host, 'https://www.example.com/app')

    assert_equal 'https://api.example.com/admin',
                 Crawler.send(:internal_link, 'https://www.example.com/app', host, 'https://api.example.com/admin')
    assert_nil Crawler.send(:internal_link, 'https://www.example.com/app', host, 'https://evil.test/admin')
  end

  def test_external_link_allows_only_different_http_hosts
    host = Crawler.send(:target_host, 'https://www.example.com/app')

    assert_equal 'https://evil.test/admin', Crawler.send(:external_link, host, 'https://evil.test/admin')
    assert_nil Crawler.send(:external_link, host, 'https://api.example.com/admin')
    assert_nil Crawler.send(:external_link, host, '/relative')
  end

  def test_link_scope_fails_closed_when_public_suffix_has_no_domain
    PublicSuffix.stub(:domain, nil) do
      host = Crawler.send(:target_host, 'https://unknown/app')

      assert_equal 'https://unknown/admin', Crawler.send(:internal_link, 'https://unknown/app', host, '/admin')
      assert_nil Crawler.send(:internal_link, 'https://unknown/app', host, 'https://other/admin')
      assert_nil Crawler.send(:external_link, host, 'https://unknown/admin')
      assert_equal 'https://other/admin', Crawler.send(:external_link, host, 'https://other/admin')
    end
  end

  def test_main_http_status_failure_preserves_error_and_removes_control_state
    result = Crawler.send(:initialize_result)
    ctx = Struct.new(:run).new({ 'modules' => {} })
    failure = Crawler.send(:failure_status, 'HTTP status 503', 'http_status', http_status: 503)
    logs = []

    output, = capture_io do
      Nokizaru::Log.stub(:write, ->(message) { logs << message }) do
        Crawler.send(:fail_crawl, result, ctx, failure)
      end
    end

    payload = ctx.run.dig('modules', 'crawler')

    assert_equal 'HTTP status 503', payload['error']
    assert_equal 'failed', payload['status']
    assert_equal 'http_status', payload['failure_reason']
    assert_equal 503, payload['http_status']
    refute payload.key?('__control__')
    assert_includes output, 'HTTP status 503 (http_status)'
    assert_includes logs, '[crawler] HTTP status 503 (http_status)'
  end

  def test_main_fetch_failures_distinguish_transport_and_request_errors
    transport = Crawler.send(:main_fetch_error, response: nil, error: IOError.new('closed'), transport: true)
    request = Crawler.send(:main_fetch_error, response: nil, error: ArgumentError.new('bad'), transport: false)

    assert_equal %w[transport_error IOError], transport.values_at(:failure_reason, :error_class)
    assert_equal 'Failed to fetch target: closed', transport[:message]
    assert_equal %w[request_error ArgumentError], request.values_at(:failure_reason, :error_class)
  end

  def test_fallback_user_agent_follows_redirect_and_records_fetch_state
    responses = [response(403), response(301, '/welcome'), response(200, nil, '<html>ok</html>')]
    requests = []
    fetch = lambda do |url, request_headers:, user_agent:|
      requests << [url, request_headers, user_agent]
      { response: responses.shift, error: nil, transport: false }
    end

    status = Crawler.stub(:main_http_get, fetch) do
      Crawler.send(:fetch_page_status, 'https://example.com', request_headers: { 'Authorization' => 'secret' })
    end

    assert status[:ok]
    assert_equal 'degraded', status[:outcome]
    assert_equal Crawler::FALLBACK_USER_AGENT, status[:active_user_agent]
    assert_equal [Crawler::USER_AGENT, Crawler::FALLBACK_USER_AGENT, Crawler::FALLBACK_USER_AGENT],
                 requests.map(&:last)
    assert_equal({ status: 403, location: nil, hops: 0, effective_url: 'https://example.com/' },
                 status.dig(:fetch, :primary))
    assert_equal 1, status.dig(:fetch, :fallback, :hops)
    assert_equal '/welcome', status.dig(:fetch, :fallback, :location)
    assert_equal 'https://example.com/welcome', status.dig(:fetch, :fallback, :effective_url)
  end

  def test_fallback_refusal_is_degraded
    responses = [response(403), response(403)]
    fetch = ->(*) { { response: responses.shift, error: nil, transport: false } }

    status = Crawler.stub(:main_http_get, fetch) do
      Crawler.send(:fetch_page_status, 'https://example.com')
    end

    assert status[:fail]
    assert_equal 'degraded', status[:outcome]
    assert_equal 'refused', status[:failure_reason]
    assert_equal 403, status.dig(:fetch, :fallback, :status)
  end

  def test_redirect_loop_is_reported_before_budget
    responses = [response(301, '/next'), response(301, '/')]
    calls = 0
    fetch = lambda do |*|
      calls += 1
      { response: responses.shift, error: nil, transport: false }
    end

    status = Crawler.stub(:main_http_get, fetch) do
      Crawler.send(:fetch_page_status, 'https://example.com')
    end

    assert_equal 2, calls
    assert_equal 'redirect_loop', status[:failure_reason]
    assert_equal 'degraded', status[:outcome]
  end

  def test_acyclic_redirect_chain_uses_full_budget
    responses = [response(301, '/one'), response(302, '/two'), response(200)]
    fetch = ->(*) { { response: responses.shift, error: nil, transport: false } }

    status = Crawler.stub(:main_http_get, fetch) do
      Crawler.send(:fetch_page_status, 'https://example.com')
    end

    assert status[:ok]
    assert_equal 2, status.dig(:fetch, :primary, :hops)
    assert_equal 'https://example.com/two', status[:effective_url]
  end

  def test_cross_scope_redirect_exposes_handoff_without_fetching_destination
    calls = 0
    fetch = lambda do |*|
      calls += 1
      { response: response(301, 'https://other.test/login'), error: nil, transport: false }
    end

    status = Crawler.stub(:main_http_get, fetch) do
      Crawler.send(:fetch_page_status, 'https://example.com')
    end

    assert_equal 1, calls
    assert_equal 'degraded', status[:outcome]
    assert_equal 'https://other.test/login', status[:canonical_handoff]
    assert_equal 'redirect_canonical_handoff', status[:failure_reason]
  end

  def test_https_downgrade_is_failed_without_fetching_destination
    calls = 0
    fetch = lambda do |*|
      calls += 1
      { response: response(301, 'http://example.com/login'), error: nil, transport: false }
    end

    status = Crawler.stub(:main_http_get, fetch) do
      Crawler.send(:fetch_page_status, 'https://example.com')
    end

    assert_equal 1, calls
    assert_equal 'failed', status[:outcome]
    assert_equal 'redirect_unsafe_redirect', status[:failure_reason]
  end

  def test_custom_headers_are_stripped_on_origin_change
    responses = [response(301, 'https://api.example.com/data'), response(200)]
    headers = []
    fetch = lambda do |_url, request_headers:, **|
      headers << request_headers
      { response: responses.shift, error: nil, transport: false }
    end

    Crawler.stub(:main_http_get, fetch) do
      Crawler.send(:fetch_page_status, 'https://www.example.com', request_headers: { 'X-Token' => 'secret' })
    end

    assert_equal [{ 'X-Token' => 'secret' }, {}], headers
  end

  def test_transport_failure_is_failed
    failure = { response: nil, error: IOError.new('connection reset'), transport: true }

    status = Crawler.stub(:main_http_get, failure) do
      Crawler.send(:fetch_page_status, 'https://example.com')
    end

    assert_equal 'failed', status[:outcome]
    assert_equal 'transport_error', status[:failure_reason]
    assert_equal 'IOError', status[:error_class]
  end

  def test_parse_robots_body_extracts_allow_disallow_and_sitemaps
    body = <<~ROBOTS
      User-agent: *
      Disallow: /admin
      Allow: /public
      Sitemap: https://example.com/sitemap.xml
      Disallow:
    ROBOTS

    links, sitemaps = Crawler.send(:parse_robots_body, body, 'https://example.com')

    assert_equal ['https://example.com/admin', 'https://example.com/public', 'https://example.com/sitemap.xml'], links
    assert_equal ['https://example.com/sitemap.xml'], sitemaps
  end

  def test_parse_robots_line_ignores_malformed_lines
    assert_nil Crawler.send(:parse_robots_line, 'User-agent: *', 'https://example.com')
    assert_nil Crawler.send(:parse_robots_line, 'Disallow:', 'https://example.com')
  end

  def test_parse_robots_line_resolves_relative_sitemap_urls
    parsed = Crawler.send(:parse_robots_line, 'sitemap:/maps/sitemap.xml', 'https://example.com')

    assert_equal 'https://example.com/maps/sitemap.xml', parsed[:sitemap]
  end

  def test_sitemap_crawl_records_external_maps_without_fetching_them
    result = Crawler.send(:initialize_result)
    fetched = []
    same_scope = 'https://maps.example.com/root.xml'
    external = 'https://maps.example.net/external.xml'
    nested_same_scope = 'https://maps.example.com/nested.xml?token=test'
    nested_external = 'https://cdn.example.net/nested.xml'
    parser = lambda do |_result, url, _headers|
      fetched << url
      [[], url == same_scope ? [nested_same_scope, nested_external] : []]
    end

    Crawler.stub(:parse_sitemap_document, parser) do
      Crawler.send(:sm_crawl, result, [same_scope, external], 'https://www.example.com', {})
    end

    assert_equal [same_scope, nested_same_scope], fetched
    assert_equal [same_scope, external, nested_same_scope, nested_external], result['sitemap_links']
  end

  def test_sitemap_scope_rejects_non_http_urls_and_distinct_ip_hosts
    refute Crawler.send(:sitemap_candidate?, 'ftp://example.com/sitemap.xml')
    refute Crawler.send(:same_scope_url?, 'http://10.0.0.1/sitemap.xml', '127.0.0.1')
    assert Crawler.send(:same_scope_url?, 'http://127.0.0.1/sitemap.xml', '127.0.0.1')
  end

  def test_sitemap_body_only_decodes_actual_gzip_bytes
    response = Struct.new(:body).new('<urlset/>')
    compressed = StringIO.new
    Zlib::GzipWriter.wrap(compressed) { |gzip| gzip.write('<urlset/>') }

    assert_equal '<urlset/>', Crawler.send(:sitemap_body, response, 'https://example.com/sitemap.xml.gz')
    assert_equal '<urlset/>', Crawler.send(:sitemap_body, Struct.new(:body).new(compressed.string), 'ignored')
  end

  def test_javascript_url_sanitization_rejects_invalid_and_trims_punctuation
    assert_equal 'https://example.com/api', Crawler.send(:sanitize_extracted_url, 'https://example.com/api);')
    assert_equal '', Crawler.send(:sanitize_extracted_url, 'ftp://example.com/file')
    assert_equal '', Crawler.send(:sanitize_extracted_url, 'not a url')
  end

  def test_javascript_normalization_keeps_same_scope_unique_urls
    found = [
      'https://example.com/api/v1/users',
      'https://cdn.example.com/static/app.js',
      'https://evil.test/api',
      'https://example.com/api/v1/users'
    ]

    urls = Crawler.send(:normalize_extracted_urls, found, 'https://www.example.com/app')

    assert_equal ['https://example.com/api/v1/users', 'https://cdn.example.com/static/app.js'], urls
  end

  def test_javascript_scope_helpers_handle_public_suffix_and_invalid_urls
    assert Crawler.send(:same_scope_url?, 'https://api.example.com/admin', 'www.example.com')
    refute Crawler.send(:same_scope_url?, 'https://example.net/admin', 'www.example.com')
    refute Crawler.send(:same_scope_url?, 'not a url', 'www.example.com')
  end

  def test_scoped_js_targets_dedupes_caps_and_rejects_out_of_scope_urls
    result = { '__control__' => { limits: { max_js_targets: 2 } } }
    links = [
      'https://example.com/a.js',
      'https://cdn.example.com/b.js',
      'https://evil.test/c.js',
      'https://example.com/a.js',
      'not a url'
    ]

    targets = Crawler.send(:scoped_js_targets, result, links, 'https://www.example.com/app')

    assert_equal ['https://example.com/a.js', 'https://cdn.example.com/b.js'], targets
  end

  def test_crawler_async_fanout_is_bounded_and_complete
    active = 0
    maximum = 0
    seen = []
    experimental_warnings = Warning[:experimental]

    Crawler.send(:each_concurrently, (1..12).to_a) do |item|
      active += 1
      maximum = [maximum, active].max
      sleep(0.001)
      seen << item
      active -= 1
    end

    assert_equal((1..12).to_a, seen.sort)
    assert_operator maximum, :>, 1
    assert_operator maximum, :<=, Crawler::MAX_FETCH_WORKERS
    assert_equal experimental_warnings, Warning[:experimental]
  end

  def test_crawler_preview_has_one_terminal_tree_branch
    output, = capture_io do
      Crawler.send(:print_links_preview, 'Links', (1..9).map { |index| "https://example.com/#{index}" })
    end

    assert_equal 1, output.scan('└─◈').length
    assert_includes output, 'More'
  end

  def test_crawler_stats_score_and_high_signal_ordering
    urls = [
      'https://example.com/assets/app.js',
      'https://example.com/admin/settings?tab=users',
      'https://example.com/api/v1/users'
    ]

    high_signal = Crawler.send(:high_signal_urls_from_list, urls)

    assert_equal ['https://example.com/admin/settings?tab=users', 'https://example.com/api/v1/users'], high_signal
    assert_equal 0, Crawler.send(:score_url, 'not a url')
  end

  private

  def response(status, location = nil, body = '')
    headers = location ? { 'location' => location } : {}
    Struct.new(:status, :headers, :body).new(status, headers, body)
  end
end
