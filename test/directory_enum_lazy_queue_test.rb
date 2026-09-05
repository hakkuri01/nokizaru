# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumLazyQueueTest < Minitest::Test
  DirectoryEnum = Nokizaru::Modules::DirectoryEnum

  def test_lazy_queue_resumes_extension_phase_after_signal_enabled_without_rebuild
    scan = lazy_scan(words: %w[admin login], filext: 'php')
    runtime = { extension_state: { enabled: false } }
    queue = DirectoryEnum.__send__(:build_work_queue, scan, runtime)

    assert_equal 'https://example.com/robots.txt', queue.pop(true)
    assert_equal 'https://example.com/admin', queue.pop(true)
    assert_equal 'https://example.com/login', queue.pop(true)
    assert_raises(ThreadError) { queue.pop(true) }

    runtime[:extension_state][:enabled] = true

    assert_equal 'https://example.com/admin.php', queue.pop(true)
    assert_equal 'https://example.com/login.php', queue.pop(true)
  end

  def test_lazy_queue_deduplicates_seed_base_and_extension_candidates
    scan = lazy_scan(words: %w[admin admin robots.txt], filext: 'php')
    runtime = { extension_state: { enabled: true } }
    queue = DirectoryEnum.__send__(:build_work_queue, scan, runtime)
    urls = drain_queue(queue)

    assert_equal [
      'https://example.com/robots.txt',
      'https://example.com/admin',
      'https://example.com/admin.php'
    ], urls
  end

  private

  def lazy_scan(words:, filext: '')
    {
      normalized_target: 'https://example.com',
      url_plan: {
        seed_urls: ['https://example.com/robots.txt'],
        words: words,
        extensions: DirectoryEnum.__send__(:file_extensions, filext)
      }
    }
  end

  def drain_queue(queue)
    urls = []
    loop { urls << queue.pop(true) }
  rescue ThreadError
    urls
  end
end
