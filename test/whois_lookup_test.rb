# frozen_string_literal: true

require_relative 'test_helper'

class WhoisLookupTest < Minitest::Test
  FakeContext = Struct.new(:cache) do
    def cache_fetch(*)
      yield
    end
  end

  def test_whois_result_normalizes_binary_output_for_safe_printing
    ctx = FakeContext.new(nil)
    db = { 'jp' => 'whois.example.test' }
    raw = "Domain Name: example.jp\nRegistrant: \xFF\xFE".b
    lookup = Nokizaru::Modules::WhoisLookup
    original_cached_whois = lookup.method(:cached_whois)

    result = nil
    lookup.singleton_class.send(:define_method, :cached_whois) { |_ctx, _query, _server| raw }
    begin
      capture_io do
        result = lookup.whois_result('example', 'jp', db, ctx)
      end
    ensure
      lookup.singleton_class.send(:define_method, :cached_whois) do |*args, **kwargs, &block|
        original_cached_whois.call(*args, **kwargs, &block)
      end
    end

    text = result.fetch('whois')
    assert_equal Encoding::UTF_8, text.encoding
    assert_predicate text, :valid_encoding?
    assert_includes text, 'Domain Name: example.jp'
  end
end
