# frozen_string_literal: true

require_relative 'test_helper'
require 'minitest/mock'

class TUIProfileTest < Minitest::Test
  OPTIONS = { full: true, w: 'large', dt: 80, export: true, r: true, header: 'Cookie: session=hunter2' }.freeze
  ARGV_GIVEN = ['--full', '--no-wayback', '-H', 'X-Api: topsecret', '-H', 'Cookie: session=hunter2'].freeze

  def planned_runner(target: 'https://example.com:80', options: OPTIONS, argv: ARGV_GIVEN,
                     headers: { 'X-Api' => 'topsecret', 'Cookie' => 'session=hunter2' })
    runner = Nokizaru::CLI::Runner.new(options, argv)
    runner.instance_variable_set(:@target, target)
    runner.instance_variable_set(:@info, ip: nil, ip_resolution_error: 'stub resolver failure',
                                         request_headers: headers)
    runner.instance_variable_set(:@enabled, runner.send(:resolve_enabled_modules))
    runner.instance_variable_set(:@ctx, Nokizaru::Context.new(run: { 'modules' => {} }, options: {}))
    runner
  end

  def test_profile_summarizes_the_run_as_invoked
    profile = planned_runner.tui_profile

    assert_equal 'https://example.com:80', profile[:target]
    assert_equal 'unresolved (stub resolver failure)', profile[:ip]
    assert_equal 'full  no-wayback', profile[:modules]
    assert_equal '--export  -dt 80  -w large  -H ×2  -r', profile[:switches]
    assert_equal 'Using https with port 80', profile[:notice]
    assert_equal %i[headers sslinfo whois dns sub arch ps crawl dir], profile[:modules_enabled]
  end

  def test_request_header_values_never_reach_the_profile
    text = planned_runner.tui_profile.to_s

    refute_includes text, 'topsecret'
    refute_includes text, 'hunter2'
  end

  def test_selected_modules_and_no_switches
    runner = planned_runner(target: 'https://example.com', options: { headers: true, dns: true }, argv: [],
                            headers: {})
    profile = runner.tui_profile

    assert_equal 'headers  dns', profile[:modules]
    assert_equal 'none', profile[:switches]
    assert_nil profile[:notice]
  end

  def test_module_statuses_read_each_module_storage_key
    runner = planned_runner
    runner.instance_variable_get(:@ctx).run['modules']['architecture_fingerprinting'] = { 'status' => 'skipped_no_key' }
    runner.instance_variable_get(:@ctx).run['modules']['crawler'] = { 'status' => 'complete' }

    statuses = runner.module_statuses

    assert_equal 'skipped_no_key', statuses[:arch]
    assert_equal 'complete', statuses[:crawl]
    assert_equal '', statuses[:dns]
  end

  def test_module_failures_merge_into_the_module_storage_key
    runner = planned_runner
    ctx = runner.instance_variable_get(:@ctx)
    ctx.run['modules']['architecture_fingerprinting'] = { 'technologies' => [] }

    runner.send(:handle_module_failure, :arch, ctx, RuntimeError.new('boom'))

    assert_equal 'failed', ctx.run['modules']['architecture_fingerprinting']['status']
    assert_equal [], ctx.run['modules']['architecture_fingerprinting']['technologies']
    refute ctx.run['modules'].key?('arch')
  end

  def test_scan_launches_the_dashboard_on_a_terminal
    captured = nil
    Nokizaru::TUI.stub(:enabled?, true) do
      Nokizaru::TUI.stub(:run, ->(opts, _argv) { captured = opts }) do
        Nokizaru::CLI.start(['--headers', '--target', 'https://x.com'])
      end
    end

    assert_equal 'https://x.com', captured[:target]
    assert captured[:headers]
  end

  def test_saving_a_key_stays_classic_even_on_a_terminal
    launched = false
    Nokizaru::TUI.stub(:enabled?, true) do
      Nokizaru::TUI.stub(:run, ->(_opts, _argv) { launched = true }) do
        Nokizaru::CLI::Runner.stub(:new, ->(*) { Struct.new(:run).new(nil) }) do
          Nokizaru::CLI.start(['-k', 'shodan@abc'])
        end
      end
    end

    refute launched, 'a -k invocation does not open the dashboard'
  end

  def test_tui_flag_without_a_terminal_exits_with_a_message
    out = StringIO.new
    Nokizaru::TUI.stub(:enabled?, false) do
      $stdout = out
      error = assert_raises(SystemExit) { Nokizaru::CLI.start(['--tui']) }

      assert_equal 1, error.status
    ensure
      $stdout = STDOUT
    end

    assert_includes out.string, 'needs an interactive terminal'
  end

  def test_default_runner_factory_builds_a_cli_runner
    session = Nokizaru::TUI::Session.new(options: { target: 'https://x.com', headers: true })
    factory = session.instance_variable_get(:@runner_factory)

    assert_instance_of Nokizaru::CLI::Runner, factory.call({ headers: true }, [])
  end

  def test_dashboard_needs_both_ends_to_be_terminals
    tty = Class.new(StringIO) { def tty? = true }.new

    assert Nokizaru::TUI.enabled?(input: tty, output: tty)
    refute Nokizaru::TUI.enabled?(input: tty, output: StringIO.new)
    refute Nokizaru::TUI.enabled?(input: StringIO.new, output: tty)
  end

  def test_classic_rows_drop_hostile_escapes_but_keep_color
    io = StringIO.new

    Nokizaru::UI.row(:info, "Server\e]0;owned\a", "nginx\e[2J\e]52;c;ZXZpbA==\a", io: io)
    Nokizaru::UI.line(:info, "found \e[31m//\e[0m /admin\e[1A", io: io)

    refute_match(/\e\]|\e\[2J|\e\[1A/, io.string)
    assert_includes io.string, "Server...#{Nokizaru::UI::W}⟦ #{Nokizaru::UI::C}nginx"
    assert_includes io.string, "\e[31m//\e[0m /admin"
  end
end
