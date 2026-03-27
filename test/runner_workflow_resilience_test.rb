# frozen_string_literal: true

require_relative 'test_helper'

class RunnerWorkflowResilienceTest < Minitest::Test
  def test_run_core_modules_continues_when_one_module_raises
    runner = Nokizaru::CLI::Runner.new({}, [])
    ctx = Nokizaru::Context.new(run: { 'modules' => {} }, options: {})
    info = {
      hostname: 'example.com',
      ssl_port: 443,
      domain: 'example.com',
      suffix: 'com',
      dns_servers: [],
      timeout: 2.0
    }
    enabled = {
      headers: true,
      sslinfo: true,
      whois: false,
      dns: false,
      sub: false,
      arch: false
    }
    ssl_called = false

    Nokizaru::Modules::Headers.stub(:call, proc { raise StandardError, 'boom' }) do
      Nokizaru::Modules::SSLInfo.stub(:call, proc { |_hostname, _port, _ctx| ssl_called = true }) do
        runner.send(:run_core_modules, enabled, 'https://example.com', info, ctx)
      end
    end

    assert_equal true, ssl_called
    assert_equal 'failed', ctx.run.dig('modules', 'headers', 'status')
    assert_match(/StandardError: boom/, ctx.run.dig('modules', 'headers', 'error'))
  end

  def test_safe_run_module_marks_timeout_and_continues
    runner = Nokizaru::CLI::Runner.new({}, [])
    ctx = Nokizaru::Context.new(run: { 'modules' => {} }, options: {})

    runner.send(:safe_run_module, :whois, true, ctx, timeout_s: 0.01) { sleep(0.05) }

    assert_equal true, ctx.run.dig('modules', 'whois', 'timed_out')
    assert_equal 'failed', ctx.run.dig('modules', 'whois', 'status')
  end
end
