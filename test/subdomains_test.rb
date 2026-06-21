# frozen_string_literal: true

require_relative 'test_helper'

class SubdomainsTest < Minitest::Test
  Subdomains = Nokizaru::Modules::Subdomains

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

  def test_run_subdomain_job_isolates_provider_exceptions
    job = ['ExplodingProvider', proc { raise 'provider failed' }]
    base_http = Object.new
    base_http.define_singleton_method(:with) { |**_kwargs| :http }

    output, = capture_io do
      Subdomains.run_subdomain_job(job, {}, base_http, Hash.new(1.0))
    end

    assert_includes output, 'ExplodingProvider Exception'
    assert_includes output, 'provider failed'
  end
end
