# frozen_string_literal: true

require 'stringio'
require 'zlib'

require_relative 'test_helper'

class CrawlerBudgetTest < Minitest::Test
  FakeResponse = Struct.new(:code, :headers, :body) do
    def [](key)
      headers.to_h[key]
    end
  end

  class FakeContext
    attr_reader :run, :artifacts

    def initialize
      @run = { 'modules' => {} }
      @artifacts = []
    end

    def add_artifact(name, value)
      @artifacts << [name, value]
    end
  end

  def test_apply_adaptive_budget_degrades_heavy_target_limits
    result = Nokizaru::Modules::Crawler.send(:initialize_result)
    result['internal_links'] = Array.new(Nokizaru::Modules::Crawler::HEAVY_INTERNAL_LINKS_THRESHOLD, 'https://example.com/a')
    result['js_links'] = Array.new(Nokizaru::Modules::Crawler::HEAVY_JS_LINKS_THRESHOLD, 'https://example.com/app.js')

    Nokizaru::Modules::Crawler.send(:apply_adaptive_budget!, result)

    assert_equal 'degraded', result.dig('__control__', :degraded) ? 'degraded' : 'standard'
    assert_equal Nokizaru::Modules::Crawler::DEGRADED_MAX_JS_TARGETS,
                 Nokizaru::Modules::Crawler.send(:adaptive_limit, result, :max_js_targets)
    assert_includes result.dig('__control__', :notes), 'heavy_target'
  end

  def test_sm_crawl_short_circuits_when_wall_clock_budget_is_exhausted
    result = Nokizaru::Modules::Crawler.send(:initialize_result)
    result['__control__'][:deadline_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1

    links = Nokizaru::Modules::Crawler.send(:sm_crawl, result, ['https://example.com/sitemap.xml'], {})

    assert_empty links
    assert_includes result.dig('__control__', :notes), 'wall_clock_budget_exhausted'
  end

  def test_js_crawl_short_circuits_when_wall_clock_budget_is_exhausted
    result = Nokizaru::Modules::Crawler.send(:initialize_result)
    result['__control__'][:deadline_at] = Process.clock_gettime(Process::CLOCK_MONOTONIC) - 1

    links = Nokizaru::Modules::Crawler.send(:js_crawl, result, ['https://example.com/app.js'], 'https://example.com',
                                            {})

    assert_empty links
    assert_includes result.dig('__control__', :notes), 'wall_clock_budget_exhausted'
  end

  def test_finalize_crawl_prints_top_level_link_previews
    ctx = FakeContext.new
    result = Nokizaru::Modules::Crawler.send(:initialize_result)
    result['robots_links'] = ['https://example.com/robots.txt']
    result['sitemap_links'] = ['https://example.com/sitemap.xml']
    result['internal_links'] = ['https://example.com/admin']
    result['external_links'] = ['https://cdn.example.net/app.js']
    result['images'] = ['https://example.com/logo.png']
    result['js_links'] = ['https://example.com/app.js']
    result['urls_inside_js'] = ['https://example.com/api']
    result['urls_inside_sitemap'] = ['https://example.com/blog']
    result['stats'] = { 'total_urls' => ['https://example.com/admin'] }
    result['high_signal_urls'] = ['https://example.com/admin']

    output, = capture_io do
      Nokizaru::Modules::Crawler.send(:finalize_crawl!, ctx, result)
    end

    assert_includes output, 'Robots Links Preview'
    assert_includes output, 'Sitemap Links Preview'
    assert_includes output, 'Internal Links Preview'
    assert_includes output, 'External Links Preview'
    assert_includes output, 'Image Links Preview'
  end

  def test_sitemap_follows_same_scope_redirect_before_adding_link
    result = Nokizaru::Modules::Crawler.send(:initialize_result)
    success = FakeResponse.new('200', { 'content-type' => 'application/xml' }, '<urlset/>')

    with_crawler_stub(:fetch_following_same_scope_redirects, {
                        response: success,
                        effective_url: 'https://www.example.com/sitemap.xml',
                        redirect_hops: 1,
                        stop_reason: nil
                      }) do
      links = nil
      capture_io do
        links = Nokizaru::Modules::Crawler.send(:sitemap, result, 'https://example.com/sitemap.xml', [], {})
      end
      assert_includes links, 'https://www.example.com/sitemap.xml'
    end
  end

  def test_parse_sitemap_document_supports_xml_gz_payloads
    result = Nokizaru::Modules::Crawler.send(:initialize_result)
    xml = '<urlset><url><loc>https://example.com/a</loc></url><sitemap><loc>https://example.com/child.xml.gz</loc></sitemap></urlset>'
    zipped = StringIO.new
    Zlib::GzipWriter.wrap(zipped) { |gzip| gzip.write(xml) }
    response = FakeResponse.new('200', { 'content-encoding' => 'gzip' }, zipped.string)

    with_crawler_stub(:fetch_following_same_scope_redirects, {
                        response: response,
                        effective_url: 'https://example.com/sitemap.xml.gz',
                        redirect_hops: 0,
                        stop_reason: nil
                      }) do
      page_links, child_sitemaps = Nokizaru::Modules::Crawler.send(
        :parse_sitemap_document,
        result,
        'https://example.com/sitemap.xml.gz',
        {}
      )

      assert_includes page_links, 'https://example.com/a'
      assert_includes child_sitemaps, 'https://example.com/child.xml.gz'
    end
  end

  def test_fetch_following_same_scope_redirects_blocks_cross_scope_redirects
    redirect = FakeResponse.new('301', { 'location' => 'https://evil.example/sitemap.xml' }, '')

    with_crawler_stub(:http_get, redirect) do
      fetch = Nokizaru::Modules::Crawler.send(
        :fetch_following_same_scope_redirects,
        'https://example.com/sitemap.xml',
        request_headers: {}
      )

      assert_equal :cross_scope, fetch[:stop_reason]
      assert_equal 'https://example.com/sitemap.xml', fetch[:effective_url]
      assert_equal '301', fetch[:response].code
    end
  end

  private

  def with_crawler_stub(method_name, value)
    crawler = Nokizaru::Modules::Crawler
    original = crawler.method(method_name)
    crawler.singleton_class.send(:define_method, method_name) { |*_args, **_kwargs| value }
    yield
  ensure
    crawler.singleton_class.send(:define_method, method_name) do |*args, **kwargs, &block|
      original.call(*args, **kwargs, &block)
    end
  end
end
