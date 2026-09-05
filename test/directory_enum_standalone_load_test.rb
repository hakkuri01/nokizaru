# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'

class DirectoryEnumStandaloneLoadTest < Minitest::Test
  DirectoryEnum = Nokizaru::Modules::DirectoryEnum

  def test_standalone_facade_api
    script = <<~'RUBY'
      require 'nokizaru/modules/dirrec'

      mod = Nokizaru::Modules::DirectoryEnum
      positional_rejected = begin
        mod.call('https://example.com', 1, 2, 3, 4, 5, 6, 7)
        false
      rescue ArgumentError
        true
      end

      puts "public=#{mod.singleton_methods.sort.inspect}"
      puts "helpers_private=#{%i[prepare_scan join_url encode_path_word].all? { |name| mod.private_methods.include?(name) }}"
      puts "public_constants=#{mod.constants(false).inspect}"
      puts "config_constant_private=#{mod.const_defined?(:MODE_FULL, false) && mod.const_get(:MODE_FULL, false) == 'full'}"
      puts "parameters=#{mod.method(:call).parameters.inspect}"
      puts "positional_rejected=#{positional_rejected}"
    RUBY
    lib = File.expand_path('../lib', __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-I', lib, '-e', script)

    assert_predicate status, :success?, stderr
    assert_equal <<~OUTPUT, stdout
      public=[:call]
      helpers_private=true
      public_constants=[]
      config_constant_private=true
      parameters=[[:req, :target], [:keyreq, :threads], [:keyreq, :timeout_s], [:keyreq, :wordlist], [:keyreq, :allow_redirects], [:keyreq, :verify_ssl], [:keyreq, :extensions], [:keyreq, :ctx], [:key, :request_headers]]
      positional_rejected=true
    OUTPUT
  end

  def test_call_maps_options_and_orchestrates_without_network
    captured = []
    events = []
    scan = {}
    runtime = {}
    finalized = {}
    prepare = proc { |options| scan.tap { captured << options }.tap { events << :prepare } }

    DirectoryEnum.stub(:prepare_scan, prepare) do
      DirectoryEnum.stub(:print_banner, proc { events << :banner }) do
        DirectoryEnum.stub(:init_runtime, proc { runtime.tap { events << :runtime } }) do
          DirectoryEnum.stub(:run_workers, proc { events << :workers }) do
            DirectoryEnum.stub(:finalize_scan, proc { finalized.tap { events << :finalize } }) do
              assert_same finalized, call_directory_enum
            end
          end
        end
      end
    end

    assert_equal %i[prepare banner runtime workers finalize], events
    assert_equal expected_directory_options, captured.first
  end

  def test_call_normalizes_nil_request_headers
    captured = nil

    prepare = proc do |options|
      captured = options
      {}
    end

    DirectoryEnum.stub(:prepare_scan, prepare) do
      DirectoryEnum.stub(:print_banner, nil) do
        DirectoryEnum.stub(:init_runtime, {}) do
          DirectoryEnum.stub(:run_workers, nil) do
            DirectoryEnum.stub(:finalize_scan, nil) do
              DirectoryEnum.call('https://example.com', **public_directory_options, request_headers: nil)
            end
          end
        end
      end
    end

    assert_equal({}, captured[:request_headers])
  end

  private

  def call_directory_enum
    DirectoryEnum.call('https://example.com', **public_directory_options)
  end

  def public_directory_options
    {
      threads: 8, timeout_s: 2.5, wordlist: '/tmp/words', allow_redirects: true,
      verify_ssl: false, extensions: 'php,txt', ctx: :context
    }
  end

  def expected_directory_options
    {
      target: 'https://example.com', threads: 8, timeout_s: 2.5, wdlist: '/tmp/words',
      allow_redirects: true, verify_ssl: false, filext: 'php,txt', ctx: :context, request_headers: {}
    }
  end
end
