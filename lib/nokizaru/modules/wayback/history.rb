# frozen_string_literal: true

require 'time'

module Nokizaru
  module Modules
    module Wayback
      # Selects a small, diverse set of useful replay snapshots from CDX history
      module History
        module_function

        ANCHORS = {
          'three_months' => [90, 60],
          'six_months' => [180, 90],
          'one_year' => [365, 180]
        }.freeze
        SIGNAL_WEIGHTS = {
          'sensitive_file' => 5,
          'api' => 4,
          'interesting_parameter' => 3,
          'interesting_path' => 3,
          'javascript' => 2
        }.freeze

        def select(records, historical_records: [], now: Time.now.utc)
          groups = Array(records).group_by { |record| canonical_key(record['url']) }.values
          historical = select_historical(historical_records, now)
          changed = select_changed(groups, historical, Wayback::SNAPSHOT_LIMIT - historical.length)
          { historical: historical, changed: changed }
        end

        def select_historical(records, now)
          selected = []
          seen = {}
          ANCHORS.each do |reason, (days, tolerance)|
            groups = Array(records).select { |record| record['anchor_reason'] == reason }
                                   .group_by { |record| canonical_key(record['url']) }.values
            candidates = groups.filter_map do |captures|
              historical_candidate(captures, now, reason, days, tolerance)
            end
            ranked = candidates.sort_by { |candidate| candidate_rank(candidate, reason) }
            ranked.each do |candidate|
              next if seen[candidate_key(candidate)]

              seen[candidate_key(candidate)] = true
              selected << candidate
              break if selected.count { |snapshot| snapshot['reasons'] == [reason] } >= Wayback::INTERVAL_LIMIT
            end
          end
          selected
        end

        def historical_candidate(captures, now, reason, days, tolerance)
          timed = timed_records(captures)
          return nil if timed.empty?

          url = captures.last['url']
          return nil if Normalize.noise_url?(url)

          labels = Normalize.signal_labels(url)
          return nil if labels.empty? && !root_url?(url)

          anchor = now - (days * 86_400)
          nearest = nearest_anchor(timed, anchor, tolerance)
          return nil unless nearest

          snapshot_record(nearest[:record], labels).tap do |snapshot|
            snapshot['reasons'] << reason
            snapshot['anchor_distance_days'][reason] = ((nearest[:time] - anchor).abs / 86_400).round
          end
        end

        def nearest_anchor(timed, anchor, tolerance)
          nearest = timed.min_by { |record| (record[:time] - anchor).abs }
          (nearest[:time] - anchor).abs <= tolerance * 86_400 ? nearest : nil
        end

        def select_changed(groups, historical, limit)
          return [] unless limit.positive?

          historical_keys = historical.to_h { |snapshot| [candidate_key(snapshot), true] }
          groups.filter_map { |captures| changed_candidate(captures, historical_keys) }
                .sort_by { |candidate| candidate_rank(candidate, 'changed') }
                .first(limit)
        end

        def changed_candidate(captures, historical_keys)
          timed = timed_records(captures)
          return nil if timed.empty?

          url = captures.last['url']
          return nil if Normalize.noise_url?(url)

          labels = Normalize.signal_labels(url)
          transitions = qualifying_transitions(url, labels, transition_records(timed))
          transitions.reverse_each do |transition|
            candidate = snapshot_record(transition[:record], labels)
            next if historical_keys[candidate_key(candidate)]

            candidate['reasons'] << 'changed'
            candidate['changes'] = transition[:changes]
            candidate['previous_timestamp'] = transition[:previous_timestamp]
            return candidate
          end
          nil
        end

        def timed_records(captures)
          captures.filter_map { |record| timed_record(record) }.sort_by { |record| record[:time] }
        end

        def timed_record(record)
          timestamp = record['timestamp'].to_s
          return nil unless timestamp.match?(/\A\d{14}\z/)

          { record: record, time: Time.strptime(timestamp, '%Y%m%d%H%M%S').utc }
        rescue ArgumentError
          nil
        end

        def transition_records(captures)
          captures.each_cons(2).filter_map do |previous, current|
            changes = changed_fields(previous[:record], current[:record])
            next if changes.empty?

            current.merge(changes: changes, previous_timestamp: previous[:record]['timestamp'])
          end
        end

        def qualifying_transitions(url, labels, transitions)
          return transitions if labels.any? || root_url?(url)

          transitions.select { |transition| (Array(transition[:changes]) - ['content']).any? }
        end

        def changed_fields(previous, current)
          { 'digest' => 'content', 'statuscode' => 'status', 'mimetype' => 'mime_type' }.filter_map do |field, label|
            before = previous[field].to_s
            after = current[field].to_s
            label if !before.empty? && !after.empty? && before != after
          end
        end

        def snapshot_record(record, labels)
          {
            'url' => record['url'],
            'snapshot_url' => record['snapshot_url'] || replay_url(record['timestamp'], record['url']),
            'timestamp' => record['timestamp'],
            'statuscode' => record['statuscode'],
            'mimetype' => record['mimetype'],
            'digest' => record['digest'],
            'signal' => labels,
            'reasons' => [],
            'changes' => [],
            'anchor_distance_days' => {}
          }
        end

        def replay_url(timestamp, url) = "https://web.archive.org/web/#{timestamp}/#{url}"

        def candidate_rank(candidate, reason)
          score = Array(candidate['signal']).sum { |label| SIGNAL_WEIGHTS.fetch(label, 0) }
          distance = candidate.dig('anchor_distance_days', reason).to_i
          if reason == 'changed'
            return [-score, -Array(candidate['changes']).length, candidate['url'], candidate['timestamp']]
          end

          [distance, -score, candidate['url'], candidate['timestamp']]
        end

        def candidate_key(candidate) = [canonical_key(candidate['url']), candidate['timestamp']]

        def canonical_key(url)
          uri = URI.parse(url.to_s)
          path = uri.path.to_s
          path = '/' if path.empty?
          default_port = (uri.scheme == 'http' && uri.port == 80) || (uri.scheme == 'https' && uri.port == 443)
          [uri.host.to_s.downcase, default_port ? nil : uri.port, path, uri.query.to_s]
        rescue StandardError
          [url.to_s]
        end

        def root_url?(url)
          path = URI.parse(url).path.to_s
          path.empty? || path == '/'
        rescue StandardError
          false
        end
      end
    end
  end
end
