# frozen_string_literal: true

require_relative 'tui_support'

class TUIAppTest < Minitest::Test
  include TUISupport

  def test_opening_any_key_opens_the_form
    model = app

    assert_equal :opening, model.screen

    assert_equal [], key(model, 'x')
    assert_equal :form, model.screen
  end

  def test_opening_ctrl_c_quits
    model = app

    assert_equal [:quit], key(model, 'ctrl+c')
  end

  def test_nb_starts_on_the_form
    assert_equal :form, app(opening: false).screen
  end

  def test_opening_animates_then_holds
    model = app
    model.update(M::Tick.new(now: 0.3, snapshot: nil, statuses: {}))

    assert_predicate model, :animating?

    model.update(M::Tick.new(now: 2.0, snapshot: nil, statuses: {}))

    refute_predicate model, :animating?
  end

  def test_opening_lands_on_the_clean_settled_frame
    model = app
    model.update(M::Tick.new(now: 0.3, snapshot: nil, statuses: {}))
    mid = model.view
    model.update(M::Tick.new(now: 1.5, snapshot: nil, statuses: {}))

    assert_predicate model, :dirty?, 'a final clean render is pending once the reveal settles'
    settled = model.view
    banner = %w[BANNER ART]
    base = Nokizaru::TUI::Scene.base(model.form.profile, banner, model.cols, model.rows)

    refute_equal mid, settled, 'the reveal animated'
    assert_equal base, settled, 'it lands on the definitive frame with no static artifacts'
  end

  def test_h_opens_help_and_q_returns_to_the_form
    model = app(opening: false)
    key(model, 'h')

    assert_equal :help, model.screen
    text = plain(model).join("\n")

    assert_includes text, 'Flags & Keys'
    assert_includes text, '--full'

    key(model, 'q')

    assert_equal :form, model.screen
  end

  def test_help_scrolls_to_reveal_the_export_formats
    model = app(opening: false)
    key(model, 'h')
    30.times { key(model, 'j') }

    assert_includes plain(model).join("\n"), 'txt, json, html'
  end

  def test_form_enter_runs_when_ready
    model = app(prefill: { target: 'https://example.com', headers: true }, opening: false)

    assert_equal [:run_scan], key(model, 'enter')
    assert model.form.launching
  end

  def test_form_enter_is_a_no_op_without_a_target
    model = app(opening: false)

    assert_equal [], key(model, 'enter')
    refute model.form.launching
  end

  def test_form_q_quits_and_esc_is_ignored
    assert_equal [:quit], key(app(opening: false), 'q')
    assert_equal [], key(app(opening: false), 'esc')
  end

  def test_ctrl_c_quits_the_form_in_normal_insert_and_while_launching
    assert_equal [:quit], key(app(opening: false), 'ctrl+c')

    insert = app(opening: false)
    key(insert, 'i')

    assert insert.form.insert
    assert_equal [:quit], key(insert, 'ctrl+c')

    launching = app(prefill: { target: 'https://example.com', headers: true }, opening: false)
    key(launching, 'enter')

    assert_equal [:quit], key(launching, 'ctrl+c')
  end

  def test_a_failure_before_the_scan_goes_live_returns_to_a_working_form
    model = app(prefill: { target: 'https://exa mple.com', headers: true }, opening: false)
    key(model, 'enter')
    model.update(M::ScanFailed.new(reason: 'Unexpected error: URI::InvalidURIError: bad URI'))

    assert_equal :form, model.screen
    refute model.form.launching
    assert_includes plain(model).join("\n"), 'InvalidURIError'
    assert_equal [:quit], key(model, 'q')
  end

  def test_a_failure_after_the_scan_goes_live_stays_on_the_dashboard
    model = dashboard_app
    model.update(M::ScanFailed.new(reason: 'Unexpected error: RuntimeError: boom'))

    assert_equal :dashboard, model.screen
  end

  def test_scan_started_enters_the_dashboard
    model = app(prefill: { target: 'https://x.com', full: true }, opening: false)
    model.update(M::ScanStarted.new(profile: profile))

    assert_equal :dashboard, model.screen
    assert_equal FULL.length + 1, model.dashboard.tabs.length
  end

  def test_scan_aborted_returns_to_the_form_with_an_error
    model = app(prefill: { target: 'bad', headers: true }, opening: false)
    model.update(M::ScanStarted.new(profile: profile))
    model.update(M::ScanAborted.new(reason: 'Protocol Missing'))

    assert_equal :form, model.screen
    assert_includes plain(model).join("\n"), 'Protocol Missing'
  end

  def test_dashboard_q_returns_to_the_form_and_ctrl_c_quits
    model = dashboard_app

    assert_equal :dashboard, model.screen
    assert_equal [:stop_and_form], key(model, 'q')

    assert_equal [:quit], key(dashboard_app, 'ctrl+c')
  end

  def test_dashboard_nav_keys_reach_the_dashboard
    model = dashboard_app

    assert_equal [], key(model, 'tab')

    refute model.dashboard.follow
  end

  def test_enter_form_after_a_run_keeps_the_prefilled_values
    model = app(prefill: { target: 'https://x.com', full: true }, opening: false)
    model.update(M::ScanStarted.new(profile: profile))
    model.enter_form

    assert_equal :form, model.screen
    assert_equal 'https://x.com', model.form.value(:target)
  end

  private

  def dashboard_app
    model = app(prefill: { target: 'https://x.com', full: true }, opening: false)
    model.update(M::ScanStarted.new(profile: profile))
    model
  end
end
