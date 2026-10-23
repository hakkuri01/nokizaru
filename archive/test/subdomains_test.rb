# frozen_string_literal: true

require_relative 'test_helper'

class SubdomainsTest < Minitest::Test
  Subdomains = Nokizaru::Modules::Subdomains
  Providers = Nokizaru::Modules::SubdomainModules
  Response = Struct.new(:status, :body)

  def test_result_set_accepts_only_exact_or_dot_boundary_scope
    found = Subdomains::ResultSet.new('example.com', Subdomains::VALID)
    candidates = ['api.example.com', 'example.com', 'badexample.com', 'evil-example.com']

    found.concat(candidates)

    assert_equal ['api.example.com', 'example.com'], found.to_a.sort
  end

  def test_finalize_subdomains_rejects_suffix_collisions
    fake_found = Object.new
    fake_found.define_singleton_method(:to_a) do
      ['api.example.com', 'badexample.com', 'dev.example.com', 'evil-example.com']
    end

    assert_equal ['api.example.com', 'dev.example.com'], Subdomains.finalize_subdomains(fake_found, 'example.com')
  end

  def test_anubis_uses_documented_endpoint
    requested_url = nil
    http = Object.new
    http.define_singleton_method(:get) do |url|
      requested_url = url
      Struct.new(:status, :body).new(204, '')
    end

    Providers::AnubisDB.call('example.com', http, [])

    assert_equal 'https://anubisdb.com/anubis/subdomains/example.com', requested_url
  end

  def test_alienvault_skips_without_key
    requested = false
    http = Object.new
    http.define_singleton_method(:get) { |*| requested = true }

    Providers::Base.stub(:ensure_key, nil) do
      output, = capture_io { Providers::AlienVault.call('example.com', http, []) }

      assert_includes output, 'Skipping AlienVault'
    end
    refute requested
  end

  def test_alienvault_sends_documented_auth_header_without_leaking_key
    secret = 'private-otx-key'
    request = nil
    logs = []
    http = Object.new
    http.define_singleton_method(:get) do |url, headers:|
      request = [url, headers]
      Struct.new(:status, :body).new(200, '{"passive_dns":[]}')
    end

    output, = Nokizaru::Log.stub(:write, ->(message) { logs << message }) do
      Providers::Base.stub(:ensure_key, secret) do
        capture_io { Providers::AlienVault.call('example.com', http, []) }
      end
    end

    assert_equal 'https://otx.alienvault.com/api/v1/indicators/domain/example.com/passive_dns', request.first
    assert_equal({ 'X-OTX-API-KEY' => secret }, request.last)
    refute_includes output, secret
    refute_includes logs.join, secret
  end

  def test_quarantined_adapters_remain_loadable_but_are_not_default_providers
    assert defined?(Providers::CrtSh)
    assert defined?(Providers::ThreatMiner)
    refute_includes Subdomains.subdomain_provider_names, 'crt.sh'
    refute_includes Subdomains.subdomain_provider_names, 'ThreatMiner'
  end

  def test_crtsh_quarantine_contract
    request = nil
    found = []
    http = Object.new
    http.define_singleton_method(:get) do |url|
      request = url
      Response.new(200, '[{"name_value":"api.example.com\\n www.example.com "}]')
    end

    capture_io { Providers::CrtSh.call('example.com', http, found) }

    assert_equal 'https://crt.sh/?dNSName=%25.example.com&output=json', request
    assert_equal ['api.example.com', 'www.example.com'], found
    assert_in_delta 8.0, Subdomains.build_vendor_timeouts(12.0)['crt.sh']
  end

  def test_threatminer_quarantine_contract
    request = nil
    found = []
    http = Object.new
    http.define_singleton_method(:get) do |url, params:|
      request = [url, params]
      Response.new(200, '{"results":["api.example.com","www.example.com"]}')
    end

    capture_io { Providers::ThreatMiner.call('example.com', http, found) }

    assert_equal ['https://api.threatminer.org/v2/domain.php', { q: 'example.com', rt: '5' }], request
    assert_equal ['api.example.com', 'www.example.com'], found
    assert_in_delta 8.0, Subdomains.build_vendor_timeouts(12.0)['ThreatMiner']
  end

  def test_subdomain_http_disables_retries
    retry_options = nil
    build_options = nil
    client = Object.new
    client.define_singleton_method(:with) { |**options| retry_options = options }

    builder = lambda do |**options|
      build_options = options
      client
    end
    Nokizaru::HTTPClient.stub(:build, builder) { Subdomains.build_subdomain_http(12.0) }

    assert_equal({ max_retries: 0 }, retry_options)
    refute build_options[:follow_redirects]
  end

  def test_rate_limit_reason_uses_bounded_normalized_body_without_retry_after
    body = "  provider busy\n#{'x' * 300}  "
    response = Struct.new(:status, :headers, :body).new(429, {}, body)
    reason = Providers::Base.failure_reason(response)

    assert_equal 221, reason.length
    assert_match(/\Aprovider busy x+…\z/, reason)
    refute_includes reason, "\n"
  end

  def test_run_subdomain_job_isolates_provider_exceptions
    job = ['ExplodingProvider', proc { raise 'provider failed' }]
    base_http = Object.new
    base_http.define_singleton_method(:with) { |**_kwargs| :http }

    output, = capture_io do
      Subdomains.run_subdomain_job(job, base_http, Hash.new(1.0))
    end

    assert_includes output, 'ExplodingProvider Exception'
    assert_includes output, 'provider failed'
  end

  def test_run_subdomain_job_uses_vendor_cap_or_remaining_shared_budget
    observed_timeout = nil
    base_http = Object.new
    base_http.define_singleton_method(:with) { |timeout:| observed_timeout = timeout[:operation_timeout] }
    times = [10.0, 10.0]

    Subdomains.stub(:monotonic_time, -> { times.shift }) do
      Subdomains.run_subdomain_job(['Provider', ->(_http) {}], base_http, Hash.new(8.0), 15.0)
    end

    assert_in_delta 5.0, observed_timeout
  end

  def test_run_subdomain_job_reports_cumulative_timeout_without_sleeping
    base_http = Object.new
    base_http.define_singleton_method(:with) { |**| :http }
    timeout = proc { |_duration, &block| raise Timeout::Error if block }

    Nokizaru::Modules::SubdomainModules::Base.start_output_capture(['SlowProvider'])
    Timeout.stub(:timeout, timeout) do
      Subdomains.run_subdomain_job(['SlowProvider', ->(_http) {}], base_http, Hash.new(1.0))
    end
    health = Nokizaru::Modules::SubdomainModules::Base.provider_health(['SlowProvider'])

    assert_equal 'timeout', health.dig('providers', 0, 'status')
    assert_equal 'provider execution deadline exceeded', health.dig('providers', 0, 'reason')
  ensure
    Nokizaru::Modules::SubdomainModules::Base.stop_output_capture
  end

  def test_unstarted_jobs_receive_timeout_health_and_progress
    updates = []
    progress = Object.new
    progress.define_singleton_method(:update) { |*args, **kwargs| updates << [args, kwargs] }
    tracker = {
      total: 1, completed: Concurrent::AtomicFixnum.new(0), progress: progress, found: nil,
      elapsed: {}, mutex: Mutex.new
    }
    queue = Queue.new
    queue << ['QueuedProvider', nil]

    Nokizaru::Modules::SubdomainModules::Base.start_output_capture(['QueuedProvider'])
    Subdomains.finish_timed_out_jobs(queue, tracker)
    health = Nokizaru::Modules::SubdomainModules::Base.provider_health(['QueuedProvider'])

    assert_equal 'timeout', health.dig('providers', 0, 'status')
    assert_equal 1, health.dig('counts', 'timeout')
    assert_equal 1, updates.last.last[:current]
  ensure
    Nokizaru::Modules::SubdomainModules::Base.stop_output_capture
  end

  def test_provider_health_uses_captured_result_and_rate_limit_events
    base = Nokizaru::Modules::SubdomainModules::Base
    response = Struct.new(:status, :headers, :body).new(429, { 'Retry-After' => '90' }, '')
    base.start_output_capture(%w[Healthy Limited])
    base.found('Healthy', 3)
    base.print_status('Limited', response)

    health = base.provider_health(%w[Healthy Limited], 'Healthy' => 0.125, 'Limited' => 0.25)

    assert_equal 'healthy', health.dig('providers', 0, 'status')
    assert_equal 3, health.dig('providers', 0, 'result_count')
    assert_equal 'rate_limited', health.dig('providers', 1, 'status')
    assert_equal 'Retry-After: 30.0s', health.dig('providers', 1, 'reason')
    assert_equal({ 'total' => 2, 'healthy' => 1, 'rate_limited' => 1 }, health['counts'])
  ensure
    base.stop_output_capture
  end

  def test_provider_health_keeps_partial_results_degraded
    base = Nokizaru::Modules::SubdomainModules::Base
    base.start_output_capture(['Partial'])
    base.status_error('Partial', 503, 'service unavailable')
    base.found('Partial', 2)

    provider = base.provider_health(['Partial']).dig('providers', 0)

    assert_equal 'error', provider['status']
    assert_equal 'service unavailable', provider['reason']
    assert_equal 2, provider['result_count']
  ensure
    base.stop_output_capture
  end
end
