# frozen_string_literal: true

require_relative 'tui_support'

class TUIFormTest < Minitest::Test
  include TUISupport

  def test_navigation_moves_between_fields_and_wraps
    f = form

    assert_equal :target, f.field.key

    key(f, 'j')

    assert_equal :modules, f.field.key

    key(f, 'k')

    assert_equal :target, f.field.key

    key(f, 'k')

    assert_equal :of, f.field.key
  end

  def test_insert_types_into_a_text_field_at_the_caret
    f = form
    key(f, 'i')

    assert f.insert

    'ab'.each_char { |char| key(f, char) }
    key(f, 'left')
    key(f, 'X')

    assert_equal 'aXb', f.value(:target)

    key(f, 'esc')

    refute f.insert
  end

  def test_number_field_rejects_non_digits
    f = form(prefill: {})
    4.times { key(f, 'j') }

    assert_equal :dt, f.field.key

    key(f, 'i')
    key(f, '8')
    key(f, 'x')
    key(f, '0')

    assert_equal '80', f.value(:dt)
  end

  def test_space_toggles_a_boolean_field
    f = form
    8.times { key(f, 'j') }

    assert_equal :r, f.field.key
    refute f.value(:r)

    key(f, ' ')

    assert f.value(:r)
  end

  def test_module_chips_move_and_toggle
    f = form
    key(f, 'j')

    assert_equal :modules, f.field.key

    key(f, 'right')
    key(f, ' ')

    assert f.module_on?(:headers)

    key(f, 'left')
    key(f, ' ')

    assert f.module_on?(:full)
  end

  def test_h_opens_help_from_the_form
    f = form

    assert_equal :help, key(f, 'h')
  end

  def test_ready_needs_a_target_and_a_module
    f = form

    refute_predicate f, :ready?
    assert_nil key(f, 'enter')

    key(f, 'i')
    'https://example.com'.each_char { |char| key(f, char) }
    key(f, 'esc')

    refute_predicate f, :ready?, 'a target alone is not enough'

    key(f, 'j')
    key(f, ' ')

    assert_predicate f, :ready?
    assert_equal :run, key(f, 'enter')
  end

  def test_q_quits_in_normal_and_esc_only_exits_insert
    f = form

    assert_nil key(f, 'esc'), 'esc does nothing in NORMAL'
    assert_equal :quit, key(f, 'q')

    f2 = form
    key(f2, 'i')

    assert f2.insert
    assert_nil key(f2, 'esc')
    refute f2.insert, 'esc exits INSERT'

    key(f2, 'i')
    key(f2, 'q')

    assert_equal 'q', f2.value(:target), 'q in INSERT is a literal character'
  end

  def test_to_request_builds_options_from_set_fields_only
    f = form(prefill: { target: 'https://example.com' })
    key(f, 'j')
    key(f, ' ') # Full
    5.times { key(f, 'j') } # to Ports

    assert_equal :p, f.field.key
    key(f, 'i')
    '8000-8010'.each_char { |char| key(f, char) }
    key(f, 'esc')

    options = f.to_request[:options]

    assert_equal 'https://example.com', options[:target]
    assert options[:full]
    assert_equal '8000-8010', options[:p]
    assert_equal 'medium', options[:w]
    refute options.key?(:dt), 'blank number fields are omitted so defaults apply'
    refute options.key?(:r)
  end

  def test_export_switches_only_apply_when_export_is_on
    f = form(prefill: { target: 'https://x.com', headers: true })
    options = f.to_request[:options]

    refute options.key?(:export)
    refute options.key?(:o)

    10.times { key(f, 'j') } # Export toggle

    assert_equal :export, f.field.key
    key(f, ' ')
    with_export = f.to_request[:options]

    assert with_export[:export]
    assert_equal 'txt,json,html', with_export[:o]
  end

  def test_prefill_maps_cli_options
    f = form(prefill: { target: 'https://x.com', full: true, w: 'large', r: true, export: true })

    assert_equal 'https://x.com', f.value(:target)
    assert f.module_on?(:full)
    assert_equal %i[headers sslinfo whois dns sub arch ps crawl dir wayback], f.enabled_modules
    assert_equal 'large', f.value(:w)
    assert f.value(:r)
  end

  def test_command_and_profile_never_show_a_header_value
    f = form(prefill: { target: 'https://x.com', headers: true })
    text = f.command_segments.to_s + f.profile.to_s

    refute_match(/-H|hunter2|Cookie/, text)
  end

  def test_command_preview_omits_export_switches_until_export_is_on
    f = form(prefill: { target: 'https://x.com', headers: true })

    refute_includes f.command_segments.map(&:first).join(' '), '-o'
    refute_includes f.profile[:switches], '-o'

    10.times { key(f, 'j') } # Export toggle
    key(f, ' ')

    assert_includes f.command_segments.map(&:first).join(' '), '-o'
  end

  def test_launching_freezes_input
    f = form(prefill: { target: 'https://x.com', headers: true })
    f.launching = true

    assert_nil key(f, 'j')
    assert_equal :target, f.field.key
  end

  def test_invocation_flags_without_a_field_ride_along_and_headers_show_only_a_count
    argv = ['--full', '--no-dir', '--target', 'https://x.com', '-H', 'Cookie: hunter2', '--sp', '8443']
    f = TUI::Form.new(prefill: { target: 'https://x.com', full: true, sp: 8443, d: '1.1.1.1' }, argv: argv)
    request = f.to_request
    shown = f.command_segments.map(&:first).join(' ') + f.profile.to_s

    assert_equal argv, request[:argv], 'the Runner reads -H and --no-MODULE from argv'
    assert_equal 8443, request[:options][:sp]
    assert_equal '1.1.1.1', request[:options][:d]
    assert_includes shown, '--no-dir'
    assert_includes shown, '-sp 8443'
    assert_includes shown, '-H ×1'
    refute_match(/hunter2|Cookie/, shown)
  end

  def test_number_fields_parse_like_the_cli_and_paths_expand_home
    f = form(prefill: { target: 'https://x.com', headers: true, T: 7.5, w: '~/words.txt', export: true,
                        cd: '~/scans' })
    options = f.to_request[:options]

    assert_in_delta 7.5, options[:T]
    assert_equal File.expand_path('~/words.txt'), options[:w]
    assert_equal File.expand_path('~/scans'), options[:cd]
    assert_equal 'medium', form.to_request[:options][:w], 'size names are not paths'

    7.times { key(f, 'j') } # Timeout
    key(f, 'i')
    2.times { key(f, 'backspace') }
    key(f, '.')
    key(f, '5')

    assert_equal '7.5', f.value(:T), 'a decimal point can be typed'
  end
end
