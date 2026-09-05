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
    host = Crawler.send(:target_public_suffix_domain, 'https://www.example.com/app')

    assert_equal 'https://api.example.com/admin',
                 Crawler.send(:internal_link, 'https://www.example.com/app', host, 'https://api.example.com/admin')
    assert_nil Crawler.send(:internal_link, 'https://www.example.com/app', host, 'https://evil.test/admin')
  end

  def test_external_link_allows_only_different_http_hosts
    host = Crawler.send(:target_public_suffix_domain, 'https://www.example.com/app')

    assert_equal 'https://evil.test/admin', Crawler.send(:external_link, host, 'https://evil.test/admin')
    assert_nil Crawler.send(:external_link, host, 'https://api.example.com/admin')
    assert_nil Crawler.send(:external_link, host, '/relative')
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
    refute Crawler.send(:same_scope_redirect?, 'https://example.com', 'ftp://example.com/file')
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
end
