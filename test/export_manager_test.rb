# frozen_string_literal: true

require 'tmpdir'
require_relative 'test_helper'

class ExportManagerTest < Minitest::Test
  def test_export_writes_each_supported_format_to_custom_destination
    Dir.mktmpdir do |dir|
      paths = Nokizaru::ExportManager.new.export(
        sample_run,
        domain: 'example.com',
        formats: %w[txt json html],
        output: { custom_directory: dir, custom_basename: 'report' }
      )

      assert_equal %w[html json txt], paths.keys.sort
      paths.each_value { |path| assert File.file?(path) }
      assert_equal 'https://example.com', JSON.parse(File.read(paths['json'])).dig('meta', 'target')
    end
  end

  def test_export_rejects_unsupported_formats
    assert_raises(ArgumentError) do
      Nokizaru::ExportManager.new.export(sample_run, domain: 'example.com', formats: ['xml'])
    end
  end

  def test_export_filename_must_be_a_plain_name
    Dir.mktmpdir do |dir|
      ['../../keys', 'sub/report', '..', '.hidden', 'a\\b'].each do |name|
        output = { custom_directory: File.join(dir, 'out'), custom_basename: name }
        assert_raises(ArgumentError, name) do
          Nokizaru::ExportManager.new.export(sample_run, domain: 'example.com', formats: ['json'], output: output)
        end
      end

      assert_empty Dir.glob(File.join(dir, '**', '*.json'))
    end
  end

  def test_exports_and_their_new_directory_are_owner_only
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'new-exports')
      output = { custom_directory: target, custom_basename: 'report' }
      formats = %w[txt json html]
      paths = Nokizaru::ExportManager.new.export(sample_run, domain: 'example.com', formats: formats, output: output)

      paths.each_value { |path| assert_equal 0o600, File.stat(path).mode & 0o777, path }
      assert_equal 0o700, File.stat(target).mode & 0o777
    end
  end

  def test_prepare_checks_everything_before_a_long_scan_and_writes_nothing
    Dir.mktmpdir do |dir|
      target = File.join(dir, 'later')
      manager = Nokizaru::ExportManager.new

      assert_raises(ArgumentError) do
        manager.prepare(domain: 'example.com', formats: ['jsno'], output: { custom_directory: target })
      end
      refute_path_exists target

      manager.prepare(domain: 'example.com', formats: ['json'], output: { custom_directory: target })

      assert_empty Dir.children(target)
    end
  end

  def test_txt_export_renders_wayback_categories_readably
    Dir.mktmpdir do |dir|
      run = sample_run
      run['modules']['wayback'] = {
        'status' => 'complete', 'archive_status' => 'degraded',
        'review_urls' => ['https://example.com/admin'],
        'javascript_urls' => ['https://example.com/app.js'], 'parameter_counts' => { 'id' => 2 },
        'urls' => ['https://example.com/admin', 'https://example.com/ordinary'],
        'url_records' => [{ 'url' => 'https://example.com/ordinary', 'source' => 'wayback',
                            'sources' => ['wayback'] }],
        'historical_snapshots' => [{
          'timestamp' => '20250829000000', 'reasons' => ['one_year'],
          'snapshot_url' => 'https://web.archive.org/web/20250829000000/https://example.com/admin'
        }],
        'changed_snapshots' => [{
          'timestamp' => '20260829000000', 'reasons' => ['changed'], 'changes' => %w[content status],
          'snapshot_url' => 'https://web.archive.org/web/20260829000000/https://example.com/admin'
        }],
        'source_health' => { 'cdx' => { 'status' => 'timeout', 'reason' => 'timeout', 'records' => 0 } },
        'truncation' => { 'truncated' => true, 'limit' => 25, 'resume_key' => 'dead-key' }
      }
      path = Nokizaru::ExportManager.new.export(
        run, domain: 'example.com', formats: ['txt'], output: { custom_directory: dir, custom_basename: 'wayback' }
      )['txt']
      output = File.read(path)

      assert_includes output, "Review (1)\n  https://example.com/admin"
      assert_includes output, "Javascript (1)\n  https://example.com/app.js"
      assert_includes output, 'Parameters: id=2'
      assert_includes output, 'Archive Status: degraded'
      assert_includes output, "wayback\thttps://example.com/ordinary"
      assert_includes output, "Historical snapshots (1)\n  20250829000000\tone_year\thttps://web.archive.org/web/"
      assert_includes output,
                      "State-change snapshots (1)\n  20260829000000\tchanged(content,status)\thttps://web.archive.org/web/"
      assert_includes output, "Raw URLs (2)\n  https://example.com/admin\n  https://example.com/ordinary"
      refute_includes output, 'Truncated:'
      refute_includes output, 'dead-key'
      refute_includes output, "'review_urls'=>"
    end
  end

  private

  def sample_run
    {
      'meta' => { 'target' => 'https://example.com', 'started_at' => '2026-08-29T00:00:00Z' },
      'modules' => { 'headers' => { 'headers' => { 'server' => 'fixture' } } },
      'findings' => []
    }
  end
end
