# frozen_string_literal: true

require_relative 'test_helper'

class WaybackHistoryTest < Minitest::Test
  Wayback = Nokizaru::Modules::Wayback
  NOW = Time.utc(2026, 9, 27, 12)
  TIMESTAMPS = %w[20250927120000 20260327120000 20260629120000 20260920120000].freeze

  def test_selects_age_anchors_and_latest_content_transition
    records = [
      record('https://example.com/api/users?id=1', '20250927120000', 'old'),
      record('https://example.com/api/users?id=1', '20260327120000', 'six-month'),
      record('https://example.com/api/users?id=1', '20260629120000', 'three-month'),
      record('https://example.com/api/users?id=1', '20260920120000', 'latest')
    ]

    selected = select(records)
    historical = selected[:historical]
    changed = selected[:changed]

    assert_equal(%w[three_months six_months one_year], historical.flat_map { |row| row['reasons'] })
    assert_equal '20260920120000', changed.first['timestamp']
    assert_includes changed.first['changes'], 'content'
    assert_includes changed.first['signal'], 'api'
  end

  def test_skips_age_anchor_when_archive_history_is_too_young
    records = [record('https://example.com/admin', '20260920120000', 'new')]

    selection = select(records)

    assert_empty selection[:historical]
    assert_empty selection[:changed]
  end

  def test_accepts_capture_newer_than_anchor_when_within_tolerance
    capture = record('https://example.com/admin', '20260709120000', 'newer')
              .merge('anchor_reason' => 'three_months')

    selection = Wayback::History.select([], historical_records: [capture], now: NOW)

    assert_equal ['three_months'], selection[:historical].first['reasons']
  end

  def test_changed_root_is_useful_without_path_signals
    records = [
      record('https://example.com/', '20250827120000', 'old'),
      record('https://example.com/', '20260920120000', 'new')
    ]

    selected = select(records)[:changed]

    assert(selected.any? { |snapshot| snapshot['reasons'].include?('changed') })
  end

  def test_digest_only_change_on_ordinary_path_is_not_high_signal
    records = [
      record('https://example.com/news', '20250827120000', 'old'),
      record('https://example.com/news', '20260920120000', 'new')
    ]

    assert_empty select(records)[:changed]
  end

  def test_status_transition_on_ordinary_path_is_high_signal
    records = [
      record('https://example.com/removed', '20250827120000', 'same'),
      record('https://example.com/removed', '20260920120000', 'same').merge('statuscode' => '404')
    ]

    selected = select(records)[:changed]

    assert(selected.any? { |snapshot| snapshot['changes'].include?('status') })
  end

  def test_noise_assets_never_enter_operator_batch
    records = [
      record('https://example.com/logo.png', '20250827120000', 'old'),
      record('https://example.com/logo.png', '20260920120000', 'new')
    ]

    selection = select(records)

    assert_empty selection[:historical]
    assert_empty selection[:changed]
  end

  def test_equivalent_scheme_port_and_root_variants_share_one_history
    records = [
      record('http://example.com:80', '20250827120000', 'old'),
      record('https://example.com/', '20260920120000', 'new')
    ]

    selected = select(records)

    assert_equal 1, selected[:historical].length
    assert_equal 1, selected[:changed].length
  end

  def test_stale_capture_is_not_mislabeled_as_recent_anchor
    records = [record('https://example.com/admin', '20200101120000', 'old')]

    assert_empty select(records)[:historical]
  end

  def test_selection_is_hard_capped_and_balances_reasons
    selected = select(dense_records)

    assert_equal 15, selected[:historical].length
    assert_equal 30, selected[:changed].length
    Wayback::History::ANCHORS.each_key do |reason|
      assert_equal(5, selected[:historical].count { |snapshot| snapshot['reasons'] == [reason] })
    end

    historical_keys = snapshot_keys(selected[:historical])
    changed_keys = snapshot_keys(selected[:changed])

    assert_empty historical_keys & changed_keys
    assert_equal changed_keys.length, changed_keys.map(&:first).uniq.length
  end

  private

  def select(records)
    Wayback::History.select(records, historical_records: anchor_records(records), now: NOW)
  end

  def anchor_records(records)
    records.filter_map do |entry|
      reason = case entry['timestamp']
               when /\A2025/ then 'one_year'
               when /\A202603/ then 'six_months'
               when /\A202606/ then 'three_months'
               end
      entry.merge('anchor_reason' => reason) if reason
    end
  end

  def dense_records
    30.times.flat_map do |index|
      url = "https://example.com/api/item/#{index}"
      TIMESTAMPS.each_with_index.map do |timestamp, version|
        record(url, timestamp, "#{version}-#{index}")
      end
    end
  end

  def snapshot_keys(snapshots)
    snapshots.map { |snapshot| [snapshot['url'], snapshot['timestamp']] }
  end

  def record(url, timestamp, digest)
    {
      'url' => url, 'timestamp' => timestamp, 'digest' => digest, 'statuscode' => '200', 'mimetype' => 'text/html',
      'snapshot_url' => "https://web.archive.org/web/#{timestamp}/#{url}"
    }
  end
end
