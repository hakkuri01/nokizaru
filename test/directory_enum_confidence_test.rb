# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumConfidenceTest < Minitest::Test
  FakeContext = Struct.new(:run)

  def test_build_scan_urls_keeps_full_wordlist_coverage
    words = (1..700).map { |idx| "w#{idx}" }
    ctx = FakeContext.new(
      {
        'modules' => {
          'crawler' => {
            'internal_links' => ['https://example.com/from-crawler']
          }
        }
      }
    )

    scan_urls = Nokizaru::Modules::DirectoryEnum.send(
      :build_scan_urls,
      { target: 'https://example.com', words: words, filext: '', ctx: ctx }
    )
    word_urls = Nokizaru::Modules::DirectoryEnum.send(:build_urls, 'https://example.com', words, '')

    assert_empty(word_urls - scan_urls)
    assert_includes scan_urls, 'https://example.com/from-crawler'
  end

  def test_finding_confidence_marks_soft_404_like_content_as_low
    sample = {
      status: 200,
      content_type: 'text/html',
      body_length: 180,
      title: 'welcome',
      fingerprint: 'abc123',
      location: nil,
      redirect_pattern: nil
    }
    baseline = {
      status: 200,
      content_type: 'text/html',
      body_length: 180,
      tolerance: 128,
      title: 'welcome',
      fingerprint: 'abc123'
    }

    decision = Nokizaru::Modules::DirectoryEnum.send(
      :finding_confidence,
      'https://example.com/random-path',
      200,
      sample,
      baseline,
      'https://example.com'
    )

    assert_equal :low, decision[:level]
    assert_equal 'soft_404_signature_match', decision[:reason]
  end

  def test_finding_confidence_marks_high_signal_content_as_confirmed
    sample = {
      status: 200,
      content_type: 'text/html',
      body_length: 280,
      title: 'admin panel',
      fingerprint: 'sig-1',
      location: nil,
      redirect_pattern: nil
    }

    decision = Nokizaru::Modules::DirectoryEnum.send(
      :finding_confidence,
      'https://example.com/admin',
      200,
      sample,
      nil,
      'https://example.com'
    )

    assert_equal :confirmed, decision[:level]
    assert_equal 'high_signal_content', decision[:reason]
  end

  def test_finding_confidence_marks_tiny_low_signal_content_as_low
    sample = {
      status: 200,
      content_type: 'text/html',
      body_length: 8,
      title: '',
      fingerprint: 'sig-2',
      location: nil,
      redirect_pattern: nil
    }

    decision = Nokizaru::Modules::DirectoryEnum.send(
      :finding_confidence,
      'https://example.com/aa',
      200,
      sample,
      nil,
      'https://example.com'
    )

    assert_equal :low, decision[:level]
    assert_equal 'low_information_response', decision[:reason]
  end

  def test_finding_confidence_marks_path_specific_redirect_as_likely
    sample = {
      status: 301,
      content_type: '',
      body_length: 0,
      title: nil,
      fingerprint: nil,
      location: 'example.com/portal',
      redirect_pattern: 'path_specific:https:example.com:/portal'
    }

    decision = Nokizaru::Modules::DirectoryEnum.send(
      :finding_confidence,
      'https://example.com/portal-entry',
      301,
      sample,
      nil,
      'https://example.com'
    )

    assert_equal :likely, decision[:level]
    assert_equal 'path_specific_redirect', decision[:reason]
  end

  def test_finding_confidence_marks_generic_sensitive_status_as_low
    sample = {
      status: 403,
      content_type: 'text/html',
      body_length: 8,
      title: '',
      fingerprint: 'deny-1',
      location: nil,
      redirect_pattern: nil
    }

    decision = Nokizaru::Modules::DirectoryEnum.send(
      :finding_confidence,
      'https://example.com/aa',
      403,
      sample,
      nil,
      'https://example.com'
    )

    assert_equal :low, decision[:level]
    assert_equal 'weak_sensitive_status', decision[:reason]
  end

  def test_finding_confidence_marks_high_signal_sensitive_status_as_confirmed
    sample = {
      status: 403,
      content_type: 'text/html',
      body_length: 12,
      title: '',
      fingerprint: 'deny-2',
      location: nil,
      redirect_pattern: nil
    }

    decision = Nokizaru::Modules::DirectoryEnum.send(
      :finding_confidence,
      'https://example.com/admin',
      403,
      sample,
      nil,
      'https://example.com'
    )

    assert_equal :confirmed, decision[:level]
    assert_equal 'high_signal_path', decision[:reason]
  end

  def test_track_confidence_finding_prints_low_confidence_to_stdout_list
    runtime = {
      stats: {
        confidence_levels: Hash.new(0),
        confidence_reasons: Hash.new(0),
        positive_statuses: Hash.new(0)
      },
      stdout_found: [],
      found: [],
      confirmed_found: [],
      low_confidence_found: [],
      progress_ui: {
        started_at_mono: nil,
        last_render_at: nil,
        last_plain_count: 0,
        ticker_active: false,
        ticker_stop: false,
        ticker_thread: nil
      },
      count: 1,
      start_time: Time.now
    }
    scan = { scan_target: 'https://example.com', total_urls: 10 }
    decision = { level: :low, reason: 'soft_404_signature_match' }

    capture_io do
      Nokizaru::Modules::DirectoryEnum.send(
        :track_confidence_finding,
        scan,
        runtime,
        'https://example.com/index.php',
        200,
        decision
      )
    end

    assert_includes runtime[:stdout_found], 'https://example.com/index.php'
    assert_empty runtime[:found]
    assert_includes runtime[:low_confidence_found], 'https://example.com/index.php'
  end
end
