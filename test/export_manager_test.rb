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

  private

  def sample_run
    {
      'meta' => { 'target' => 'https://example.com', 'started_at' => '2026-08-29T00:00:00Z' },
      'modules' => { 'headers' => { 'headers' => { 'server' => 'fixture' } } },
      'findings' => []
    }
  end
end
