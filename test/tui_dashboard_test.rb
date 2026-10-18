# frozen_string_literal: true

require_relative 'tui_support'

class TUIDashboardTest < Minitest::Test
  include TUISupport

  def test_follow_moves_focus_to_each_running_module
    dash = dashboard
    tick(dash, current: :headers, phases: { headers: 'running' })

    assert_equal :headers, dash.focused_tab.key

    tick(dash, current: :dns, phases: { headers: 'done', sslinfo: 'done', whois: 'done', dns: 'running' })

    assert_equal :dns, dash.focused_tab.key
    assert_equal %i[done done done running], dash.tabs.first(4).map(&:state)
  end

  def test_manual_tab_change_stops_follow
    dash = dashboard
    tick(dash, current: :headers, phases: { headers: 'running' })
    key(dash, 'tab')

    refute dash.follow
    assert_equal :sslinfo, dash.focused_tab.key

    key(dash, 'f')

    assert dash.follow
  end

  def test_number_keys_jump_and_zero_is_tenth
    dash = dashboard
    key(dash, '4')

    assert_equal :dns, dash.focused_tab.key

    key(dash, '0')

    assert_equal :wayback, dash.focused_tab.key
  end

  def test_tail_pins_to_new_lines_until_scrolled_up
    dash = dashboard(modules: %i[dir])
    tick(dash, current: :dir, phases: { dir: 'running' }, modules: %i[dir])
    lines(dash, :dir, (1..100).map { |index| "line #{index}" })

    assert_includes plain(dash).join("\n"), 'line 100'

    key(dash, 'k')
    lines(dash, :dir, ['line 101'])

    refute_includes plain(dash).join("\n"), 'line 101'

    key(dash, 'G')

    assert_includes plain(dash).join("\n"), 'line 101'
  end

  def test_g_scrolls_to_the_top
    dash = dashboard(modules: %i[dir])
    tick(dash, current: :dir, phases: { dir: 'running' }, modules: %i[dir])
    lines(dash, :dir, (1..100).map { |index| "line #{index}" })
    key(dash, 'g')

    assert(plain(dash).any? { |row| row.include?('line 1') && !row.include?('line 10') })
  end

  def test_tab_glyphs_track_module_state
    dash = dashboard(modules: %i[headers sslinfo whois dns])
    tick(dash, current: :dns, modules: %i[headers sslinfo whois dns],
               phases: { headers: 'done', sslinfo: 'failed', whois: 'skipped', dns: 'running' })
    strip = dash.view[dash.geometry.tab_row]

    assert_includes strip, "#{Nokizaru::UI::G}⟦+⟧"
    assert_includes strip, "#{Nokizaru::UI::R}⟦✘⟧"
    assert_includes strip, "#{Nokizaru::UI::Y}⟦!⟧"
    assert_includes strip, "#{Nokizaru::UI::Y}⟦■⟧#{Nokizaru::UI::W} #{Nokizaru::UI::R}DNS"
  end

  def test_completion_lands_on_summary_and_shows_the_status
    dash = dashboard(modules: %i[headers sub dns])
    tick(dash, current: :dns, phases: { headers: 'done', dns: 'done' }, modules: %i[headers sub dns])
    done(dash, export_dir: '/tmp/exports/example.com')

    assert_equal %i[done skipped done done], dash.tabs.map(&:state)
    assert_equal :summary, dash.focused_tab.key
    assert_includes plain(dash).join("\n"), '⟦+⟧ Completed in 12.50s // Exported /tmp/exports/example.com'
  end

  def test_non_zero_exit_reports_a_stopped_scan
    dash = dashboard(modules: %i[sub])
    tick(dash, current: :sub, phases: { sub: 'running' }, modules: %i[sub])
    done(dash, status: 1)

    assert_equal :failed, dash.phase
    assert_includes plain(dash).join("\n"), '⟦✘⟧ Scan stopped (exit 1)'
  end

  def test_stored_skip_status_marks_the_tab
    dash = dashboard(modules: %i[arch])
    tick(dash, current: :arch, phases: { arch: 'done' }, statuses: { arch: 'skipped_no_key' }, modules: %i[arch])

    assert_equal :skipped, dash.tabs.first.state
  end

  def test_lines_for_an_unknown_tag_land_in_summary
    dash = dashboard(modules: %i[headers])
    lines(dash, :prelude, ['stray'])

    assert_equal ['stray'], dash.tabs.last.lines
  end
end
