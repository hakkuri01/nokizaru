# frozen_string_literal: true

require_relative 'test_helper'

class WhoisModuleTest < Minitest::Test
  Whois = Nokizaru::Modules::WhoisLookup
  Response = Struct.new(:status, :body)
  FIXTURES = {
    'whois/standard.txt' => "Domain Name: REDACTED-EXAMPLE.COM.\nRegistrar: REDACTED REGISTRAR\n" \
                            "No match for \"UNRELATED.EXAMPLE\".\n",
    'whois/jprs.txt' => "[Domain Name]                   REDACTED-EXAMPLE.JP\n" \
                        "[Registrant]                    REDACTED\n",
    'whois/jprs_attribute.txt' => "a. [Domain Name]                REDACTED-EXAMPLE.CO.JP\n" \
                                  "g. [Organization]               REDACTED\n",
    'whois/nominet.txt' => "Domain name:\n    redacted-example.uk\n\nRegistrant:\n    REDACTED\n",
    'whois/jprs_no_match.txt' => "No match!!\n",
    'rdap/no_service.json' => '{"rdapConformance":["rdap_level_0"],"errorCode":404,' \
                              '"title":"No RDAP service is available for this resource"}',
    'rdap/not_found.json' => '{"rdapConformance":["rdap_level_0"],"errorCode":404,' \
                             '"title":"Not Found","description":["REDACTED domain was not found"]}'
  }.freeze

  def test_parse_whois_lines_cleans_no_match_display_line
    pairs, misc = Whois.parse_whois_lines("No match for \"NONEXISTENT-EXAMPLE.COM\".\n")

    assert_empty pairs
    assert_equal ['No match for nonexistent-example.com'], misc
  end

  def test_raw_whois_disables_referrals_and_removes_registry_footer
    client = Minitest::Mock.new
    response = "Registry Domain: example.com\n>>> registry footer\nRegistrar Domain: example.com\n"
    client.expect(:lookup, response, ['example.com'])

    constructor = lambda do |**settings|
      assert_equal({ timeout: 10, referral: false }, settings)
      client
    end

    raw = ::Whois::Client.stub(:new, constructor) { Whois.raw_whois('example.com') }

    assert_equal "Registry Domain: example.com\n", raw
    client.verify
  end

  def test_recognizes_exact_positive_domain_formats
    assert_equal :usable, Whois.classify_whois(fixture('whois/standard.txt'), 'redacted-example.com')
    assert_equal :usable, Whois.classify_whois("Domain Name: REDACTED-EXAMPLE.COM\r\nRegistrar: REDACTED\r\n",
                                               'redacted-example.com')
    assert_equal :usable, Whois.classify_whois("Domain: REDACTED-EXAMPLE.COM.\n", 'redacted-example.com')
    assert_equal :usable, Whois.classify_whois(fixture('whois/jprs.txt'), 'redacted-example.jp')
    assert_equal :usable, Whois.classify_whois(fixture('whois/jprs_attribute.txt'), 'redacted-example.co.jp')
    assert_equal :usable, Whois.classify_whois(fixture('whois/nominet.txt'), 'redacted-example.uk')
    assert_equal :unusable, Whois.classify_whois("Domain Name: other.example\n", 'example.com')
  end

  def test_recognizes_only_matching_decorated_domain_fields
    assert_equal :usable, Whois.classify_whois("domain.............: REDACTED-EXAMPLE.FI\n", 'redacted-example.fi')
    assert_equal :unusable, Whois.classify_whois("domain.............: other.example\n", 'example.fi')
    assert_equal :unusable, Whois.classify_whois("registrant domain..: example.fi\n", 'example.fi')
  end

  def test_classification_decision_order_and_fallbacks
    assert_equal :not_found, Whois.classify_whois(fixture('whois/jprs_no_match.txt'), 'missing.jp')
    ordered = "Domain: example.com\nNo match!!\nThis WHOIS service has been retired; use RDAP instead.\n"

    assert_equal :retired, Whois.classify_whois(ordered, 'example.com')
    assert_equal :not_found, Whois.classify_whois("No match!!\nWHOIS service is not available\n")
    assert_equal :no_data, Whois.classify_whois("\n")
    assert_equal :unsupported, Whois.classify_whois("WHOIS service is not available for this suffix\n")
    assert_equal :unusable, Whois.classify_whois("Temporary registry notice\n")
    assert_equal :unusable, Whois.classify_whois("Registrant Name: Not Found\n", 'example.com')
    assert_equal :unusable, Whois.classify_whois("Registrar: Example\nCreation Date: 2000-01-01\n", 'example.com')
  end

  def test_positive_whois_normalizes_identity_and_does_not_call_rdap
    Whois.stub(:fetch_rdap, ->(*) { flunk 'RDAP should not be called' }) do
      Whois.stub(:raw_whois, fixture('whois/standard.txt')) do
        result = Whois.stub(:print_whois, nil) { Whois.whois_result('REDACTED-EXAMPLE', 'COM.') }

        assert_equal 'registered', result['status']
        assert_equal 'whois', result['source']
        assert_equal fixture('whois/standard.txt'), result['whois']
      end
    end
  end

  def test_negative_whois_does_not_call_rdap
    Whois.stub(:fetch_rdap, ->(*) { flunk 'RDAP should not be called' }) do
      result = Whois.stub(:print_whois, nil) do
        Whois.finish_whois('missing.example', fixture('whois/jprs_no_match.txt'), :not_found)
      end

      assert_equal({ 'whois' => fixture('whois/jprs_no_match.txt'), 'status' => 'not_found',
                     'source' => 'whois' }, result)
    end
  end

  def test_retired_whois_uses_fixed_rdap_url_and_stores_safe_summary
    client = Minitest::Mock.new
    client.expect(:get, Response.new(200, rdap_body), ['https://rdap.org/domain/example.com'])
    builder = lambda do |origin, **options|
      assert_equal 'https://rdap.org', origin
      assert_equal({ timeout_s: 10, headers: { 'Accept' => 'application/rdap+json' } }, options)
      client
    end

    result = Nokizaru::HTTPClient.stub(:for_host, builder) do
      Whois.stub(:print_whois, nil) do
        Whois.stub(:print_rdap, nil) { Whois.finish_whois('example.com', 'Use RDAP at https://evil.example/', :retired) }
      end
    end

    assert_equal 'registered', result['status']
    assert_equal 'rdap', result['source']
    assert_equal ['whois_retired'], result['reasons']
    client.verify
  end

  def test_rdap_summary_excludes_contact_data
    result = Whois.parse_rdap(rdap_body, 'example.com')

    assert_equal 'example.com', result['domain']
    assert_equal ['active'], result['registration_status']
    assert_equal [{ 'action' => 'registration', 'date' => '2000-01-01T00:00:00Z' }], result['events']
    assert_equal ['ns1.example.com'], result['nameservers']
    refute result.key?('entities')
    refute_includes result.to_s, 'private@example.com'
  end

  def test_authoritative_rdap_404_is_not_found
    result = Whois.stub(:fetch_rdap, Response.new(404, fixture('rdap/not_found.json'))) do
      Whois.rdap_result('missing.example', { 'whois' => '' }, 'whois_empty')
    end

    assert_equal({ 'whois' => '', 'status' => 'not_found', 'source' => 'rdap',
                   'reasons' => ['whois_empty'] }, result)
  end

  def test_rdap_org_404_without_service_is_degraded
    result = Whois.stub(:fetch_rdap, Response.new(404, fixture('rdap/no_service.json'))) do
      Whois.rdap_result('example.invalid', { 'whois' => '' }, 'whois_unsupported')
    end

    assert_equal 'degraded', result['status']
    assert_equal %w[whois_unsupported rdap_no_service], result['reasons']
    assert_equal result['error'], result['Error']
  end

  def test_expected_whois_errors_have_distinct_fallback_reasons
    errors = {
      ::Whois::ConnectionError.new('REDACTED transport failure') => 'whois_transport_error',
      ::Whois::ServerError.new('REDACTED server failure') => 'whois_unsupported'
    }

    errors.each do |error, reason|
      result = Whois.stub(:raw_whois, ->(*) { raise error }) do
        Whois.stub(:fetch_rdap, Response.new(503, '')) { Whois.whois_result('example', 'invalid') }
      end

      assert_equal [reason, 'rdap_server_error'], result['reasons']
      assert result.key?('Error')
      assert_equal '', result['whois']
    end
  end

  def test_degraded_result_preserves_raw_whois_and_legacy_error
    raw = "Temporary REDACTED registry notice\n"
    result = Whois.stub(:fetch_rdap, Response.new(503, '')) do
      Whois.stub(:print_whois, nil) { Whois.finish_whois('example.com', raw, :unusable) }
    end

    assert_equal raw, result['whois']
    assert_equal 'No usable registration data returned', result['Error']
  end

  def test_rdap_failures_have_stable_degraded_reasons
    cases = {
      Response.new(429, '') => 'rdap_rate_limited',
      Response.new(503, '') => 'rdap_server_error',
      Response.new(200, '{') => 'rdap_malformed_response',
      Response.new(200, JSON.generate('objectClassName' => 'domain', 'ldhName' => 'other.example')) =>
        'rdap_domain_mismatch'
    }

    cases.each do |response, reason|
      result = Whois.stub(:fetch_rdap, response) do
        Whois.rdap_result('example.com', { 'whois' => '' }, 'whois_unusable')
      end

      assert_equal 'degraded', result['status']
      assert_equal ['whois_unusable', reason], result['reasons']
      assert_equal 'No usable registration data returned', result['error']
      assert_equal result['error'], result['Error']
    end

    result = Whois.stub(:fetch_rdap, ->(*) { raise IOError }) do
      Whois.rdap_result('example.com', { 'whois' => '' }, 'whois_unusable')
    end

    assert_equal %w[whois_unusable rdap_transport_error], result['reasons']
  end

  def test_unsupported_whois_preserves_legacy_error_key
    result = Whois.stub(:fetch_rdap, Response.new(503, '')) do
      Whois.finish_whois('example.invalid', '', :unsupported, 'This domain suffix is not supported.')
    end

    assert_equal 'This domain suffix is not supported.', result['Error']
    assert_equal 'degraded', result['status']
    assert_equal %w[whois_unsupported rdap_server_error], result['reasons']
  end

  def test_successful_rdap_fallback_removes_stale_whois_error
    result = Whois.stub(:fetch_rdap, Response.new(200, rdap_body)) do
      Whois.stub(:print_rdap, nil) do
        Whois.finish_whois('example.com', '', :unsupported, 'This domain suffix is not supported.')
      end
    end

    assert_equal 'registered', result['status']
    refute result.key?('Error')
    refute result.key?('error')
  end

  private

  def fixture(path)
    FIXTURES.fetch(path)
  end

  def rdap_body
    JSON.generate(
      'objectClassName' => 'domain', 'ldhName' => 'EXAMPLE.COM.', 'handle' => '123', 'status' => ['active'],
      'events' => [{ 'eventAction' => 'registration', 'eventDate' => '2000-01-01T00:00:00Z' }],
      'nameservers' => [{ 'ldhName' => 'NS1.EXAMPLE.COM.' }],
      'entities' => [{ 'vcardArray' => ['vcard', [['email', {}, 'text', 'private@example.com']]] }]
    )
  end
end
