# frozen_string_literal: true

require_relative 'test_helper'

class FindingsRulesTest < Minitest::Test
  HeaderRules = Nokizaru::Findings::HeaderRules
  TLSRules = Nokizaru::Findings::TLSRules
  DNSRules = Nokizaru::Findings::DNSRules
  DirectoryRules = Nokizaru::Findings::DirectoryRules

  def test_header_rules_return_empty_for_non_hash_input
    assert_empty HeaderRules.call(nil)
  end

  def test_header_rules_suppress_posture_findings_when_header_fetch_failed
    findings = HeaderRules.call('headers' => {}, 'error' => 'Failed to retrieve headers')

    assert_empty findings
  end

  def test_header_rules_detect_missing_security_headers_and_cookie_flags
    findings = HeaderRules.call(
      'headers' => {
        'Content-Security-Policy' => "default-src 'self'",
        'Set-Cookie' => 'session=abc; Secure, prefs=dark; HttpOnly; SameSite=Lax'
      }
    )

    ids = findings.map { |finding| finding['id'] }
    assert_includes ids, 'headers.missing_strict_transport_security'
    assert_includes ids, 'headers.missing_x_content_type_options'
    assert(findings.any? { |finding| finding['id'].start_with?('cookies.missing_flags') })
  end

  def test_header_rules_accept_array_cookie_values_and_complete_flags
    cookies = [
      'session=abc; Secure; HttpOnly; SameSite=Lax',
      'prefs=dark; Secure; HttpOnly; SameSite=Strict'
    ]
    findings = HeaderRules.cookie_flag_findings(cookies)

    assert_empty findings
  end

  def test_tls_rules_detect_expired_and_expiring_certificates
    expired = TLSRules.call('cert' => { 'notAfter' => (Time.now - 86_400).utc.iso8601 })
    expiring = TLSRules.call('not_after' => (Time.now + (3 * 86_400)).utc.iso8601)

    assert_equal ['tls.cert_expired'], finding_ids(expired)
    assert_equal ['tls.cert_expiring'], finding_ids(expiring)
  end

  def test_tls_rules_ignore_invalid_or_distant_certificates
    assert_empty TLSRules.call('not_after_gmt' => 'not a timestamp')
    assert_empty TLSRules.call('notAfter' => (Time.now + (90 * 86_400)).utc.iso8601)
    assert_nil TLSRules.parse_time('not a timestamp')
  end

  def test_dns_rules_detect_missing_and_present_email_records
    missing = DNSRules.call('records' => { 'TXT' => ['google-site-verification=abc'] })
    present = DNSRules.call(
      'records' => { 'TXT' => ['v=spf1 include:_spf.example.com ~all'], 'DMARC' => ['v=DMARC1; p=none'] }
    )

    assert_equal %w[dns.missing_spf dns.missing_dmarc], finding_ids(missing)
    assert_empty present
    assert_empty DNSRules.call(nil)
  end

  def test_dns_rules_accept_legacy_record_shapes
    result = { 'txt' => ['V=SPF1 -all'], 'dmarc' => ['V=DMARC1; p=reject'] }

    assert DNSRules.spf_record_present?(result)
    assert DNSRules.dmarc_record_present?(result)
  end

  def test_directory_rules_prioritize_interesting_prioritized_paths
    finding = DirectoryRules.call(
      'prioritized_found' => ['https://example.com/admin', 'https://example.com/public'],
      'confirmed_found' => ['https://example.com/.git']
    ).first

    assert_equal 'dir.interesting_paths', finding['id']
    assert_includes finding['evidence'], '/admin'
    refute_includes finding['evidence'], '.git'
  end

  def test_directory_rules_fall_back_to_confirmed_paths_and_preview_limit
    interesting = Array.new(21) { |idx| "https://example.com/api/#{idx}" }
    finding = DirectoryRules.call('confirmed_found' => interesting).first

    assert_equal 'dir.interesting_paths', finding['id']
    assert_includes finding['evidence'], "\u2026"
    assert_empty DirectoryRules.call('confirmed_found' => ['https://example.com/about'])
    assert_empty DirectoryRules.call(nil)
  end

  def test_engine_collects_and_normalizes_findings
    engine = Nokizaru::Findings::Engine.new
    findings = engine.run(
      'modules' => {
        'headers' => { 'headers' => {} },
        'dns' => { 'records' => {} },
        'directory_enum' => { 'confirmed_found' => ['https://example.com/admin'] }
      }
    )

    assert(findings.all? { |finding| finding['id'] && finding['severity'] })
    assert_includes findings.map { |finding| finding['module'] }, 'headers'
    assert_includes findings.map { |finding| finding['module'] }, 'dns'
    assert_includes findings.map { |finding| finding['module'] }, 'directory_enum'
  end

  private

  def finding_ids(findings)
    findings.map { |finding| finding['id'] }
  end
end
