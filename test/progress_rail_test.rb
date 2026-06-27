# frozen_string_literal: true

require_relative 'test_helper'

class ProgressRailTest < Minitest::Test
  class TTYStringIO < StringIO
    def tty? = true
  end

  def test_run_status_line_formats_directory_snapshot
    snapshot = {
      enabled_modules: %i[headers dir],
      current_module: :dir,
      modules: {
        headers: { phase: 'done', label: 'Headers' },
        dir: {
          phase: 'running', label: 'Directory Enum', current: 25, total: 100,
          elapsed_s: 2.0, success: 24, errors: 1, found: 3
        }
      }
    }

    line = Nokizaru::UI.run_status_line(snapshot, frame_index: 0, tty: false)

    assert_match(/\A⟦[·■]{7}⟧ /, line)
    assert_includes line, 'Module 2/2'
    assert_includes line, '┃ Directory Enum ┃'
    assert_includes line, 'Directory Enum'
    assert_includes line, '25/100'
    assert_includes line, 'avg 12.5r/s'
    assert_includes line, 'found 3'
  end

  def test_pulse_frame_advances_independently_of_status_text
    snapshot = { enabled_modules: [:headers], current_module: :headers, modules: { headers: { phase: 'running' } } }

    first = Nokizaru::UI.run_status_line(snapshot, frame_index: 0, tty: false)
    second = Nokizaru::UI.run_status_line(snapshot, frame_index: 3, tty: false)

    refute_equal first, second
    assert_includes second, 'headers ┃ running'
  end

  def test_with_output_clears_and_redraws_transient_line
    io = TTYStringIO.new
    rail = Nokizaru::ProgressRail.new(enabled_modules: [:dir], io: io, interval_s: 0.01)

    rail.start
    rail.module_started(:dir, label: 'Directory Enum')
    sleep 0.03
    rail.with_output { io.puts('live finding') }
    rail.stop

    output = io.string
    assert_includes output, "\r\e[K"
    assert_includes output, 'live finding'
    assert_includes output, 'Directory Enum'
  ensure
    rail&.stop
  end

  def test_single_module_progress_rail_renders_isolated_module_status
    io = TTYStringIO.new
    rail = Nokizaru::ProgressRail.new(enabled_modules: [:ps], io: io, interval_s: 0.01)

    rail.start
    rail.module_started(:ps, label: 'Port Scan')
    rail.update(:ps, current: 80, total: 100, open: 3)
    sleep 0.03
    rail.stop

    output = io.string
    assert_includes output, 'Module'
    assert_includes output, '/1'
    assert_includes output, 'Port Scan'
    assert_includes output, '80'
    assert_includes output, '100'
    assert_includes output, 'open'
    assert_includes output, '3'
  ensure
    rail&.stop
  end

  def test_run_status_line_colorizes_active_tty_numbers
    snapshot = {
      enabled_modules: %i[headers dir],
      current_module: :dir,
      modules: {
        headers: { phase: 'done', label: 'Headers' },
        dir: { phase: 'running', label: 'Directory Enum', current: 25, total: 100, elapsed_s: 2.0, found: 3 }
      }
    }

    line = Nokizaru::UI.run_status_line(snapshot, frame_index: 0, tty: true)

    assert_includes line, "#{Nokizaru::UI::C}⟦#{Nokizaru::UI::W}"
    assert_includes line, "#{Nokizaru::UI::C}⟧#{Nokizaru::UI::W}"
    assert_includes line, "Module #{Nokizaru::UI::Y}2#{Nokizaru::UI::W}/2"
    assert_includes line, "#{Nokizaru::UI::C}┃#{Nokizaru::UI::W}"
    assert_includes line, "#{Nokizaru::UI::Y}25#{Nokizaru::UI::W}/100"
    assert_includes line, "found #{Nokizaru::UI::Y}3#{Nokizaru::UI::W}"
    refute_includes line, '⟦!⟧'
  end

  def test_single_directory_module_status_line
    snapshot = {
      enabled_modules: [:dir],
      current_module: :dir,
      modules: {
        dir: { phase: 'running', label: 'Directory Enum', current: 12, total: 40, elapsed_s: 3.0, found: 2 }
      }
    }

    line = Nokizaru::UI.run_status_line(snapshot, frame_index: 2, tty: false)

    assert_includes line, 'Module 1/1'
    assert_includes line, '┃ Directory Enum ┃'
    assert_includes line, '12/40'
    assert_includes line, 'avg 4.0r/s'
    assert_includes line, 'found 2'
  end

  def test_single_portscan_module_status_line
    snapshot = {
      enabled_modules: [:ps],
      current_module: :ps,
      modules: { ps: { phase: 'running', label: 'Port Scan', current: 80, total: 100, open: 3 } }
    }

    line = Nokizaru::UI.run_status_line(snapshot, frame_index: 2, tty: false)

    assert_includes line, 'Module 1/1'
    assert_includes line, '┃ Port Scan ┃'
    assert_includes line, '80/100'
    assert_includes line, 'open 3'
  end

  def test_single_generic_module_status_line
    snapshot = {
      enabled_modules: [:headers],
      current_module: :headers,
      modules: { headers: { phase: 'running', label: 'Headers', stage: 'complete', detail: '14 headers' } }
    }

    line = Nokizaru::UI.run_status_line(snapshot, frame_index: 2, tty: false)

    assert_includes line, 'Module 1/1'
    assert_includes line, '┃ Headers ┃'
    assert_includes line, 'complete 14 headers'
    refute_includes line, 'running complete'
  end
end
