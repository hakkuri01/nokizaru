# frozen_string_literal: true

require_relative 'test_helper'

# Builders shared by the interactive TUI tests: forms, the app router, and dashboards driven by messages
module TUISupport
  TUI = Nokizaru::TUI
  M = Nokizaru::TUI::Messages
  FULL = %i[headers sslinfo whois dns sub arch ps crawl dir wayback].freeze

  def form(prefill: {}, cols: 100, rows: 32)
    form = TUI::Form.new(prefill: prefill)
    form.resize(cols, rows)
    form
  end

  def app(prefill: {}, cols: 100, rows: 32, opening: true)
    model = TUI::App.new(form: form(prefill: prefill, cols: cols, rows: rows), banner: %w[BANNER ART], now: 0.0,
                         opening: opening)
    model.update(M::Resize.new(cols: cols, rows: rows))
    model
  end

  def profile(modules: FULL, notice: nil, target: 'https://example.com', ip: '93.184.216.34')
    { target: target, ip: ip, modules: 'full', switches: '-w large', notice: notice, modules_enabled: modules }
  end

  def dashboard(modules: FULL, cols: 100, rows: 32, **)
    dash = TUI::Dashboard.new(profile: profile(modules: modules, **), now: 0.0, cols: cols, rows: rows)
    dash.update(M::Resize.new(cols: cols, rows: rows))
    dash
  end

  def snapshot(modules, current, phases = {})
    { enabled_modules: modules, current_module: current,
      modules: modules.to_h { |key| [key, { phase: phases.fetch(key, 'pending'), label: key.to_s }] } }
  end

  def tick(dash, now: 0.5, current: nil, phases: {}, statuses: {}, modules: FULL)
    dash.update(M::Tick.new(now: now, snapshot: snapshot(modules, current || modules.first, phases),
                            statuses: statuses))
  end

  def lines(dash, tag, texts)
    dash.update(M::Lines.new(items: Array(texts).map { |text| [tag, text] }))
  end

  def key(model, name)
    return model.key(name) if model.is_a?(TUI::Form)

    model.update(M::Key.new(name: name))
  end

  def plain(model)
    model.view.map { |row| Nokizaru::TerminalText.strip_sgr(row) }
  end

  def done(dash, status: 0, export_dir: nil)
    dash.update(M::ScanDone.new(elapsed: 12.5, export_dir: export_dir, status: status))
  end
end
