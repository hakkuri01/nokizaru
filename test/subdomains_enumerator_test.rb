# frozen_string_literal: true

require_relative 'test_helper'

class SubdomainsEnumeratorTest < Minitest::Test
  FakeHTTP = Struct.new(:id)

  class FakeBaseHTTP
    attr_reader :profiles

    def initialize
      @profiles = []
      @sequence = 0
      @mutex = Mutex.new
    end

    def with(timeout:)
      @mutex.synchronize do
        @profiles << timeout
        @sequence += 1
        FakeHTTP.new(@sequence)
      end
    end
  end

  def test_result_set_filters_and_deduplicates_during_collection
    set = Nokizaru::Modules::Subdomains::ResultSet.new('example.com', Nokizaru::Modules::Subdomains::VALID)

    values = [
      'api.example.com',
      ' api.example.com ',
      '*.example.com',
      'bad/name.example.com',
      'other.test',
      nil
    ]
    set.concat(values)

    assert_equal ['*.example.com', 'api.example.com'], set.to_a.sort
  end

  def test_run_subdomain_jobs_reuses_clients_for_matching_timeout_profiles
    base_http = FakeBaseHTTP.new
    seen = {}
    seen_mutex = Mutex.new
    jobs = %w[A B C].map do |name|
      [name, proc { |http| seen_mutex.synchronize { seen[name] = http.id } }]
    end
    vendor_timeouts = {
      'A' => 8.0,
      'B' => 8.0,
      'C' => 10.0
    }

    Nokizaru::Modules::Subdomains.run_subdomain_jobs(jobs, base_http, vendor_timeouts, 5.0)

    assert_equal 2, base_http.profiles.length
    assert_equal seen['A'], seen['B']
    refute_equal seen['A'], seen['C']
  end
end
