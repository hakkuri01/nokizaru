# frozen_string_literal: true

require_relative 'test_helper'

class PortRulesTest < Minitest::Test
  PortRules = Nokizaru::Findings::PortRules

  def test_structured_sensitive_ports_use_enriched_evidence
    result = {
      'ports' => [
        {
          'port' => 6379,
          'service' => 'Redis',
          'category' => 'database',
          'exposure' => 'sensitive'
        }
      ]
    }

    finding = PortRules.call(result).first

    assert_equal 'ports.sensitive_open', finding['id']
    assert_includes finding['evidence'], '6379 (Redis) [database]'
  end

  def test_non_sensitive_structured_ports_do_not_emit_findings
    result = {
      'ports' => [
        {
          'port' => 443,
          'service' => 'HTTPS',
          'category' => 'web',
          'exposure' => 'standard'
        }
      ]
    }

    assert_empty PortRules.call(result)
  end

  def test_low_confidence_sensitive_ports_do_not_emit_findings
    result = { 'ports' => [{ 'port' => 6379, 'exposure' => 'sensitive', 'confidence' => 'low' }] }

    assert_empty PortRules.call(result)
  end
end
