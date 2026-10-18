# frozen_string_literal: true

require 'prism'
require_relative 'test_helper'

# Most patterns in lib run on text from the target or a provider, so every regex literal there must match in linear
# time (AGENTS.md, Algorithmic Complexity rule 5). Parsing the source pins new and inline patterns as well as
# constants, with no list to keep in sync
class RegexLinearTimeTest < Minitest::Test
  LIB = File.expand_path('../lib', __dir__)

  def test_every_regex_literal_in_lib_matches_in_linear_time
    literals = Dir[File.join(LIB, '**', '*.rb')].flat_map { |file| regex_literals(file) }
    slow = literals.reject { |_where, pattern| Regexp.linear_time?(pattern) }

    assert_operator literals.length, :>, 50, 'the source walk found the patterns'
    assert_empty slow.map(&:first), 'patterns that can backtrack on hostile input'
  end

  def test_the_set_cookie_split_keeps_expires_dates_whole
    value = 'a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT, b=2; Path=/,c=3'

    assert_equal ['a=1; Expires=Wed, 21 Oct 2026 07:28:00 GMT', 'b=2; Path=/', 'c=3'],
                 Nokizaru::HTTPClient.split_set_cookie(value)
    assert_equal %w[a=1 b=2], Nokizaru::HTTPClient.split_set_cookie("a=1\nb=2")
  end

  private

  def regex_literals(file)
    found = []
    queue = [Prism.parse_file(file).value]
    until queue.empty?
      node = queue.shift
      queue.concat(node.compact_child_nodes)
      next unless node.is_a?(Prism::RegularExpressionNode)

      found << ["#{file.delete_prefix("#{LIB}/")}:#{node.location.start_line}", Regexp.new(node.unescaped, flags(node))]
    end
    found
  end

  def flags(node)
    (node.ignore_case? ? Regexp::IGNORECASE : 0) | (node.extended? ? Regexp::EXTENDED : 0) |
      (node.multi_line? ? Regexp::MULTILINE : 0)
  end
end
