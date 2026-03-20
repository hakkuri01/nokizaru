# frozen_string_literal: true

require_relative 'test_helper'

class CrawlerBudgetTest < Minitest::Test
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
end
