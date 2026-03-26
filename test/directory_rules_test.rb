# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryRulesTest < Minitest::Test
  def test_uses_prioritized_found_for_interesting_paths
    dir_result = {
      'found' => [
        'https://example.com/admin',
        'https://example.com/graphql'
      ],
      'prioritized_found' => ['https://example.com/api'],
      'confirmed_found' => ['https://example.com/admin']
    }

    findings = Nokizaru::Findings::DirectoryRules.call(dir_result)

    assert_equal 1, findings.length
    finding = findings.first
    assert_equal 'Prioritized interesting paths discovered', finding['title']
    assert_includes finding['evidence'], 'https://example.com/api'
    refute_includes finding['evidence'], 'https://example.com/admin'
  end

  def test_returns_empty_without_prioritized_or_confirmed_interesting_paths
    dir_result = {
      'found' => ['https://example.com/admin'],
      'prioritized_found' => [],
      'confirmed_found' => []
    }

    findings = Nokizaru::Findings::DirectoryRules.call(dir_result)
    assert_empty findings
  end
end
