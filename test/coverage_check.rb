# frozen_string_literal: true

require 'coverage'

Coverage.start(lines: true)

Dir[File.expand_path('*_test.rb', __dir__)].each { |path| require path }

Minitest.after_run do
  result = Coverage.result
  root = File.expand_path('..', __dir__)
  scoped = {
    'lib/nokizaru.rb' => 90.0,
    'lib/nokizaru/cli_argv.rb' => 90.0,
    'lib/nokizaru/findings/directory_rules.rb' => 90.0,
    'lib/nokizaru/findings/dns_rules.rb' => 90.0,
    'lib/nokizaru/findings/engine.rb' => 90.0,
    'lib/nokizaru/findings/header_rules.rb' => 90.0,
    'lib/nokizaru/findings/port_rules.rb' => 90.0,
    'lib/nokizaru/findings/rules.rb' => 90.0,
    'lib/nokizaru/findings/tls_rules.rb' => 90.0,
    'lib/nokizaru/http_result_helpers.rb' => 90.0,
    'lib/nokizaru/modules/crawler/link_support.rb' => 90.0,
    'lib/nokizaru/modules/portscan/nonblocking_scanner.rb' => 90.0,
    'lib/nokizaru/modules/portscan/port_list.rb' => 90.0,
    'lib/nokizaru/modules/wayback/normalize.rb' => 90.0,
    'lib/nokizaru/request_headers.rb' => 90.0
  }
  failures = []

  puts "\nScoped deterministic coverage:"
  scoped.each do |relative_path, threshold|
    path = File.join(root, relative_path)
    data = result[path]
    if data.nil?
      failures << [relative_path, 0.0, threshold]
      warn "  #{relative_path} missing from coverage result"
      next
    end

    percent = line_coverage_percent(data.fetch(:lines))
    puts format('  %<path>s %<percent>.1f%% threshold=%<threshold>.1f%%',
                path: relative_path, percent: percent, threshold: threshold)
    failures << [relative_path, percent, threshold] if percent < threshold
  end

  total = total_line_coverage(result, root)
  puts format('Informational total lib coverage: %.1f%%', total)
  next if failures.empty?

  warn 'Scoped coverage failed:'
  failures.each do |path, percent, threshold|
    warn format('  %<path>s %<percent>.1f%% < %<threshold>.1f%%',
                path: path, percent: percent, threshold: threshold)
  end
  exit(false)
end

def line_coverage_percent(lines)
  relevant = lines.compact
  return 100.0 if relevant.empty?

  relevant.count(&:positive?).fdiv(relevant.length) * 100.0
end

def total_line_coverage(result, root)
  lib_prefix = File.join(root, 'lib')
  files = result.select { |path, _data| path.start_with?(lib_prefix) }
  relevant = files.flat_map { |_path, data| data.fetch(:lines).compact }
  return 100.0 if relevant.empty?

  relevant.count(&:positive?).fdiv(relevant.length) * 100.0
end
