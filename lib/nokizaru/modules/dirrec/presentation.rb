# frozen_string_literal: true

module Nokizaru
  module Modules
    module DirectoryEnum
      module Presentation
        private

        def print_finding(scan, runtime, url, status)
          target = scan[:scan_target]
          return if url == "#{target}/"

          runtime[:stdout_found] << url
          with_output_lock(runtime) do
            UI.line(:info, "#{colorize_status(status)} | #{url}")
          end
          print_progress(runtime, scan, force: true)
        end

        def colorize_status(status)
          code = status.to_i
          color = case code
                  when 200...300
                    UI::G
                  when 300...400
                    UI::Y
                  when 400...500
                    UI::R
                  when 500...600
                    UI::M
                  else
                    UI::W
                  end
          "#{color}#{code}#{UI::W}"
        end

        def log_error(http_result, error_count)
          return if error_count > 5

          if error_count == 5
            Log.write('[dirrec] Suppressing further error logs')
          else
            Log.write("[dirrec] Error: #{http_result.error_message}")
          end
        end

        def print_banner(scan)
          UI.module_header('Directory Enum')
          rows = banner_rows(scan)
          rows.insert(3, ['Effective Timeout', scan[:timeout]]) if effective_timeout_changed?(scan)
          UI.rows(:plus, rows)
          UI.blank_line
        end

        def banner_rows(scan)
          [
            ['Re-Anchor', scan[:reanchor_display]],
            ['Mode', scan[:mode]],
            ['Threads', scan[:options][:threads]],
            ['Timeout', scan[:options][:timeout_s]],
            ['Wordlist', scan[:options][:wdlist]],
            ['Custom Headers', Nokizaru::RequestHeaders.summary(scan[:options][:request_headers])],
            ['Allow Redirects', scan[:options][:allow_redirects]],
            ['SSL Verification', scan[:options][:verify_ssl]],
            ['Wordlist Lines', scan[:word_data][:total_lines]],
            ['Usable Entries', scan[:word_data][:unique_lines]],
            ['File Extensions', scan[:options][:filext]],
            ['Total URLs', scan[:total_urls]]
          ]
        end

        def effective_timeout_changed?(scan)
          (scan[:timeout].to_f - scan[:options][:timeout_s].to_f).abs > Float::EPSILON
        end

        def print_progress(runtime, scan, force: false)
          return unless force || progress_output_tty?

          ctx = scan[:options][:ctx]
          ctx.progress&.update(
            :dir,
            current: runtime[:count],
            total: scan[:total_urls],
            elapsed_s: Time.now - runtime[:start_time],
            success: runtime[:stats][:success],
            errors: runtime[:stats][:errors],
            found: runtime[:found].length
          )
        end

        def with_output_lock(runtime, &)
          lock = runtime[:output_lock]
          return yield unless lock

          lock.synchronize(&)
        rescue Errno::EPIPE
          nil
        end

        def progress_output_tty?
          $stdout.tty?
        end

        def print_dir_summary(rps, runtime, stop_reason, redirect_signals)
          UI.blank_line
          count_rows = redirect_signal_count_rows(redirect_signals)
          counts = dir_summary_counts(runtime)
          status_shape = runtime[:stop_status_code_shape].to_s
          label_width = dir_summary_label_width(count_rows, stop_reason, status_shape, counts)

          UI.row(:info, 'Requests/second', rps, label_width: label_width)
          UI.row(:info, 'Directories found', counts[:found], label_width: label_width)
          UI.row(:info, 'Low confidence', counts[:low], label_width: label_width) if counts[:low].positive?
          print_redirect_signals(redirect_signals, count_rows, label_width)
          UI.row(:info, 'Stop Reason', stop_reason, label_width: label_width) unless stop_reason.to_s.strip.empty?
          UI.row(:info, 'Status Code Shape', status_shape, label_width: label_width) unless status_shape.empty?
          UI.blank_line
        end

        def dir_summary_counts(runtime)
          {
            found: runtime[:found].uniq.length,
            low: runtime[:low_confidence_found].uniq.length
          }
        end

        def dir_summary_label_width(count_rows, stop_reason, status_shape, counts)
          labels = ['Requests/second', 'Directories found']
          labels << '3xx Signals' unless count_rows.empty?
          labels << 'Low confidence' if counts[:low].positive?
          labels << 'Stop Reason' unless stop_reason.to_s.strip.empty?
          labels << 'Status Code Shape' unless status_shape.to_s.empty?
          labels.map(&:length).max
        end

        def print_redirect_signals(redirect_signals, count_rows, label_width)
          return if count_rows.empty?

          UI.row(:info, '3xx Signals', 'interesting redirects detected', label_width: label_width)
          UI.tree_rows(count_rows)

          example_rows = redirect_signal_example_rows(redirect_signals)
          return if example_rows.empty?

          UI.tree_header('3xx Examples')
          UI.tree_rows(example_rows)
        end

        def redirect_signal_count_rows(redirect_signals)
          counts = redirect_signal_counts(redirect_signals)
          rows = []
          rows << ['callback-like', counts[:callback_like]] if counts[:callback_like].positive?
          rows << ['auth-flow', counts[:auth_flow]] if counts[:auth_flow].positive?
          rows << ['cross-scope', counts[:cross_scope]] if counts[:cross_scope].positive?
          rows
        end

        def redirect_signal_example_rows(redirect_signals)
          examples = Array(redirect_signals[:examples])
          grouped = examples.group_by { |example| example[:type].to_sym }

          %i[callback_like auth_flow cross_scope].flat_map do |type|
            Array(grouped[type]).first(3).map do |example|
              [redirect_signal_label(type), redirect_signal_example_text(example)]
            end
          end
        end

        def redirect_signal_example_text(example)
          "#{example[:status]} | #{example[:request]} -> #{example[:location]}"
        end

        def redirect_signal_label(signal_type)
          case signal_type.to_sym
          when :cross_scope then 'cross-scope'
          when :callback_like then 'callback-like'
          when :auth_flow then 'auth-flow'
          else signal_type.to_s
          end
        end

        def redirect_signal_counts(redirect_signals)
          raw = redirect_signals.is_a?(Hash) ? redirect_signals[:counts] : nil
          values = raw.is_a?(Hash) ? raw : {}
          {
            cross_scope: values.fetch(:cross_scope, 0).to_i,
            callback_like: values.fetch(:callback_like, 0).to_i,
            auth_flow: values.fetch(:auth_flow, 0).to_i
          }
        end

        def store_dir_result(scan, result)
          ctx = scan[:options][:ctx]
          ctx.run['modules']['directory_enum'] = result
          artifact_paths = Array(result['prioritized_found'])
          artifact_paths = Array(result['found']) if artifact_paths.empty?
          ctx.add_artifact('paths', artifact_paths)
          ctx.add_artifact('prioritized_paths', result['prioritized_found']) if Array(result['prioritized_found']).any?
          ctx.add_artifact('high_signal_paths', result['high_signal_found']) if Array(result['high_signal_found']).any?
        end
      end
    end
  end
end
