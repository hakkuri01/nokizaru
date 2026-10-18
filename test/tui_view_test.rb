# frozen_string_literal: true

require_relative 'tui_support'

class TUIViewTest < Minitest::Test
  include TUISupport

  SIZES = [[80, 24], [100, 32], [160, 48], [240, 60], [70, 20], [40, 10]].freeze
  ALLOWED_SGR = ['0', '31', '32', '33', '36', '2', '2;31', '38;5;226', '38;5;220', '38;5;178'].freeze
  # The HUD adopts Jekyll // Hyde's ┣━┤ bracket and ◈─┨ branch tee by design; the rest of its heavy chrome stays out
  BORROWED = %w[┃ ┏ ┛ ┫ ┠ ┇ ∕].freeze

  def dash_frame(cols, rows)
    dash = dashboard(modules: %i[headers sslinfo whois dns], cols: cols, rows: rows)
    tick(dash, current: :dns, modules: %i[headers sslinfo whois dns],
               phases: { headers: 'done', sslinfo: 'done', whois: 'done', dns: 'running' })
    lines(dash, :dns, [Nokizaru::UI.formatted_row(:info, 'A', '93.184.216.34'), "\e[36m#{'x' * 300}\e[0m"])
    dash
  end

  def form_model(cols, rows)
    app(prefill: { target: 'https://example.com', full: true, w: 'large', export: true }, cols: cols, rows: rows,
        opening: false)
  end

  def test_every_screen_fills_the_terminal_without_overflowing_a_row
    SIZES.each do |cols, rows|
      opening = app(cols: cols, rows: rows)
      opening.update(M::Tick.new(now: 0.4, snapshot: nil, statuses: {}))
      [opening.view, form_model(cols, rows).view, dash_frame(cols, rows).view].each do |frame|
        assert_equal rows, frame.length, "#{cols}x#{rows}"
        frame.each { |row| assert_operator Nokizaru::TerminalText.width(row), :<=, cols, "#{cols}x#{rows}: #{row.inspect}" }
      end
    end
  end

  def test_opening_reveals_then_settles
    model = app
    model.update(M::Tick.new(now: 0.3, snapshot: nil, statuses: {}))
    revealing = plain(model).join("\n")
    model.update(M::Tick.new(now: 2.0, snapshot: nil, statuses: {}))
    settled = plain(model).join("\n")

    refute_equal revealing, settled
    assert_includes settled, 'NOKIZARU // v'
    assert_includes settled, 'STANDBY'
  end

  def test_form_never_writes_escapes_from_prefilled_values
    hostile = "https://x.com/\e]52;c;ZXZpbA==\a\e]0;owned\a\e[2J"
    prefill = { target: hostile, headers: true, export: true, cd: "/tmp/\e[2J" }
    frames = [[100, 32], [60, 20]].map { |cols, rows| app(prefill: prefill, cols: cols, rows: rows, opening: false) }
    editing = app(prefill: prefill, opening: false)
    key(editing, 'i') # INSERT splits the value at the caret
    frames << editing

    frames.each { |model| refute_match(/\e\]|\e\[2J/, model.view.join, "#{model.cols}x#{model.rows}") }
  end

  def test_compact_form_shows_the_command_from_its_start
    prefill = { target: 'https://a-very-long-hostname.example.com/path', full: true, w: 'large', e: 'php,txt,html',
                p: '1-65535', export: true, o: 'txt,json', cd: '/tmp/exports/long/dir', of: 'basename' }
    text = plain(app(prefill: prefill, cols: 60, rows: 24, opening: false)).join("\n")

    assert_includes text, '› nokizaru --full'
    assert_includes text, '-of basename'
  end

  def test_identity_rail_is_bracketed_like_the_borrowed_wordmark
    row = plain(form_model(100, 32)).find { |line| line.include?('NOKIZARU') }

    assert_includes row, '┣━┤ NOKIZARU // v'
    assert_includes row, '├━'
  end

  def test_form_splits_the_mode_and_light_onto_their_own_branch_rows
    rows = plain(form_model(100, 32))
    mode = rows.index { |row| row.include?('NORMAL') }
    light = rows.index { |row| row.include?('READY') }

    refute_nil mode
    refute_nil light
    refute_equal mode, light, 'the vim mode and the readiness light are not on the same row'
    refute_includes rows[mode], '//', 'the // divider is gone'
    assert rows[mode].rstrip.end_with?('◈─┨'), 'the mode hangs off a branch node'
    assert rows[light].rstrip.end_with?('◈─┨'), 'the light hangs off a branch node'
  end

  def test_cheatsheet_uses_the_bracketed_middle_dot_style
    row = plain(form_model(100, 32)).find { |line| line.include?('enter run') }

    refute_nil row
    assert_includes row, '┤ '
    assert_includes row, ' · '
    refute_includes row, '⟦enter⟧', 'keys are no longer wrapped in corner brackets'
  end

  def test_the_hud_cluster_rails_are_a_symmetric_diagonal_like_the_borrowed_design
    [100, 120, 160, 240].each do |cols|
      rows = plain(form_model(cols, 32))
      outer_top = rows.first.index('▰▰▱') + 2 # the ▱ ending the top outer rail
      inner_top = rows.find { |row| row.include?('NOKIZARU') }.index('▰▰▱') + 2
      inner_bottom = rows.find { |row| row.include?('enter run') }.index('▱▰▰')
      outer_bottom = rows.last.index('▱▰▰')

      assert_equal cols - 1, outer_top + outer_bottom, "cols=#{cols}: outer rails mirror"
      assert_equal cols - 1, inner_top + inner_bottom, "cols=#{cols}: inner rails mirror"
      assert_equal inner_top - outer_top, outer_bottom - inner_bottom, "cols=#{cols}: the diagonal is symmetric"
    end
  end

  def test_opening_wordmark_has_no_gradient_only_chrome_red
    model = app
    model.update(M::Tick.new(now: 2.0, snapshot: nil, statuses: {}))
    codes = model.view.join.scan(/\e\[([0-9;]*)m/).flatten.uniq

    assert_empty codes - ALLOWED_SGR
    refute_match(/\e\[38;2;/, model.view.join, 'no truecolor gradient')
  end

  def test_form_lists_fields_and_the_live_command
    text = plain(form_model(100, 32)).join("\n")

    %w[Target Modules Wordlist].each { |label| assert_includes text, label }
    assert_includes text, '⟦+⟧ Full'
    assert_includes text, '› nokizaru --full --target https://example.com'
  end

  def test_form_scrolls_to_reveal_later_fields
    model = form_model(100, 32)
    13.times { key(model, 'j') } # to Filename

    assert_includes plain(model).join("\n"), 'Filename'
  end

  def test_top_cluster_reflects_the_form_selection
    text = plain(form_model(120, 32)).first(6).join("\n")

    assert_includes text, '├─◈ Target.......⟦ https://example.com ⟧'
    assert_includes text, '├─◈ Modules......⟦ full ⟧'
  end

  def test_dashboard_streams_results_on_a_vertical_scaffold
    rows = plain(dash_frame(100, 32))
    head = rows.index { |row| row.include?('◈ DNS') }

    refute_nil head
    refute(rows.any? { |row| row.include?('────────') && row.include?('DNS Enumeration') }, 'no module header bar')
    assert(rows[head + 1].include?('│') && rows[head + 1].include?('93.184.216.34'))
    assert(rows.any? { |row| row.strip.start_with?('╎') }, 'faint scaffold below the results')
  end

  def test_long_lines_wrap_inside_the_pane
    dash = dash_frame(100, 32)
    wrapped = plain(dash).select { |row| row.include?('xxxx') }

    assert_operator wrapped.length, :>=, 3
    wrapped.each { |row| assert_operator Nokizaru::TerminalText.width(row), :<=, 100 }
  end

  def test_clusters_mirror_at_every_width
    (80..300).step(11).each do |cols|
      rows = plain(dash_frame(cols, 32))
      top = rows.first
      bottom = rows.last.lstrip

      assert_equal top.length, bottom.length, "cols=#{cols}"
      assert top.start_with?('┌') && top.end_with?('▰▰▱'), "cols=#{cols}"
      assert bottom.start_with?('▱▰▰') && bottom.end_with?('┘'), "cols=#{cols}"
    end
  end

  def test_rail_caps_use_the_signal_glyph
    assert_includes plain(form_model(100, 32)).first, '▰▰▱'
  end

  def test_frames_use_only_the_classic_palette
    [form_model(100, 32).view, dash_frame(100, 32).view].each do |frame|
      codes = frame.join.scan(/\e\[([0-9;]*)m/).flatten.uniq

      assert_empty codes - ALLOWED_SGR
    end
  end

  def test_no_borrowed_glyphs_from_another_design_language
    frame = dash_frame(160, 48).view.join

    BORROWED.each { |glyph| refute_includes frame, glyph }
  end

  def test_scaffold_scrolls_within_bounds_while_the_hud_frame_stays
    dash = dashboard(modules: %i[dir], cols: 100, rows: 32)
    tick(dash, current: :dir, phases: { dir: 'running' }, modules: %i[dir])
    lines(dash, :dir, (1..400).map { |index| "finding #{index}" })
    before = plain(dash)
    key(dash, 'g')
    top = plain(dash)
    key(dash, 'ctrl+d')
    after = plain(dash)

    assert_equal before.length, after.length
    assert_equal before.first, after.first, 'top HUD rail unchanged'
    assert_equal before[-3..], after[-3..], 'bottom HUD cluster unchanged'
    refute_equal top[5..15], after[5..15], 'pane content scrolled'
    assert_includes top.join("\n"), 'finding 1'
    assert_includes plain(dash).join("\n"), 'finding'
  end

  def test_frame_cost_stays_flat_even_past_the_line_cap
    small = frame_allocations(1_000)
    dropped = frame_allocations(Nokizaru::TUI::Tab::MAX_LINES + 5_000)

    assert_operator dropped, :<=, small * 2, 'a frame must not copy the tab history once lines start dropping'
  end

  def frame_allocations(count)
    dash = dashboard(modules: %i[dir], cols: 120, rows: 40)
    tick(dash, current: :dir, phases: { dir: 'running' }, modules: %i[dir])
    lines(dash, :dir, Array.new(count) { |index| "finding #{index}" })
    2.times { dash.view }
    before = GC.stat(:total_allocated_objects)
    dash.view
    GC.stat(:total_allocated_objects) - before
  end

  def test_compact_layout_below_the_full_minimum
    rows = plain(dash_frame(70, 20))

    assert_includes rows.first, 'NOKIZARU'
    assert_includes rows.last, 'Module'
    refute(rows.any? { |row| row.include?('┌') || row.include?('┘') })
  end

  def test_too_small_notice
    assert(plain(dash_frame(40, 10)).any? { |row| row.include?('Terminal too small') })
  end

  def test_tab_overflow_keeps_focus_visible
    dash = dashboard(cols: 80, rows: 24)
    first = plain(dash)[dash.geometry.tab_row]

    assert first.rstrip.end_with?('›')

    key(dash, '0')
    last = plain(dash)[dash.geometry.tab_row]

    assert_includes last, '‹'
    assert_includes last, 'Wayback'
  end
end
