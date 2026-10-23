# frozen_string_literal: true

require_relative 'test_helper'

class DirectoryEnumStatusCodeShapeTest < Minitest::Test
  DirectoryEnum = Nokizaru::Modules::DirectoryEnum

  def test_status_code_shape_summary_formats_status_percentages
    responses = Array.new(318) { |idx| ["https://example.com/redirect#{idx}", 302] } +
                Array.new(2) { |idx| ["https://example.com/root#{idx}", 301] }

    shape = DirectoryEnum.__send__(:status_code_shape_summary, responses)

    assert_equal '302=318/320 (99.4%), 301=2/320 (0.6%)', shape
  end

  def test_status_code_shape_summary_returns_empty_without_statuses
    assert_equal '', DirectoryEnum.__send__(:status_code_shape_summary, [])
  end

  def test_status_code_shape_colors_only_formatting_commas
    raw = '429=8/10 (80.0%), 200=2/10 (20.0%)'

    colored = DirectoryEnum.__send__(:colored_status_shape, raw)

    assert_equal "429=8/10 (80.0%)#{Nokizaru::UI::W},#{Nokizaru::UI::C} 200=2/10 (20.0%)", colored
    refute_match(/\e\[/, raw)
  end

  def test_redirect_examples_color_formatting_delimiters
    example = { status: 302, request: 'https://example.com/dashboard', location: 'https://example.com/login' }

    text = DirectoryEnum.__send__(:redirect_signal_example_text, example)

    assert_equal "302 #{Nokizaru::UI::W}|#{Nokizaru::UI::C} https://example.com/dashboard " \
                 "#{Nokizaru::UI::W}->#{Nokizaru::UI::C} https://example.com/login", text
  end

  def test_directory_finding_preserves_status_color_and_colors_url_as_data
    runtime = { stdout_found: [], output_lock: nil, found: [], count: 1,
                start_time: Time.now, stats: { success: 1, errors: 0 } }
    scan = { scan_target: 'https://example.com', total_urls: 1,
             options: { ctx: Struct.new(:progress).new(nil) } }

    output, = capture_io do
      DirectoryEnum.__send__(:print_finding, scan, runtime, 'https://example.com/graphql', 200)
    end

    assert_includes output, "#{Nokizaru::UI::G}200#{Nokizaru::UI::W} #{Nokizaru::UI::W}//" \
                            "#{Nokizaru::UI::C} https://example.com/graphql"
  end

  def test_status_code_shape_summary_ignores_invalid_statuses_and_sorts_ties
    responses = [
      ['https://example.com/a', 500],
      ['https://example.com/b', nil],
      ['https://example.com/c', 404],
      ['https://example.com/d', 'invalid'],
      ['https://example.com/e', 500],
      ['https://example.com/f', 404],
      ['https://example.com/g', 0]
    ]

    shape = DirectoryEnum.__send__(:status_code_shape_summary, responses)

    assert_equal '404=2/4 (50.0%), 500=2/4 (50.0%)', shape
  end

  def test_capture_stop_status_code_shape_records_shape_once
    runtime = {
      responses: [
        ['https://example.com/a', 404],
        ['https://example.com/b', 404],
        ['https://example.com/c', 403]
      ],
      stop_status_code_shape: nil
    }

    DirectoryEnum.__send__(:capture_stop_status_code_shape!, runtime)

    assert_equal '404=2/3 (66.7%), 403=1/3 (33.3%)', runtime[:stop_status_code_shape]

    runtime[:responses] << ['https://example.com/d', 500]
    DirectoryEnum.__send__(:capture_stop_status_code_shape!, runtime)

    assert_equal '404=2/3 (66.7%), 403=1/3 (33.3%)', runtime[:stop_status_code_shape]
  end

  def test_marginal_value_stop_captures_status_code_shape
    runtime = {
      count: 400,
      stop_state: { stop: false, reason: nil },
      target_shape: { wildcard: true, redirect_cluster: false },
      all_found: Array.new(20) { |idx| "https://example.com/noise#{idx}" },
      low_confidence_found: Array.new(18) { |idx| "https://example.com/noise#{idx}" },
      adaptation_state: { last_window: { prioritized_gain: 0 } },
      responses: Array.new(20) { |idx| ["https://example.com/noise#{idx}", 404] },
      stop_status_code_shape: nil
    }

    DirectoryEnum.__send__(:apply_marginal_value_stop!, runtime)

    assert runtime[:stop_state][:stop]
    assert_match(/marginal directory value collapsed/, runtime[:stop_state][:reason])
    assert_equal '404=20/20 (100.0%)', runtime[:stop_status_code_shape]
  end

  def test_budget_stop_captures_status_code_shape
    runtime = {
      responses: [
        ['https://example.com/a', 301],
        ['https://example.com/b', 302],
        ['https://example.com/c', 302]
      ],
      stop_status_code_shape: nil
    }
    stop_state = { stop: false, reason: nil, budgets: { max_requests: 3 } }

    DirectoryEnum.__send__(:stop!, stop_state, 3, Time.now, nil, runtime: runtime)

    assert stop_state[:stop]
    assert_equal '302=2/3 (66.7%), 301=1/3 (33.3%)', runtime[:stop_status_code_shape]
  end
end
