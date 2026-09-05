# frozen_string_literal: true

require 'uri'
require_relative 'test_helper'

class HeadersModuleTest < Minitest::Test
  Headers = Nokizaru::Modules::Headers

  FakeNetResponse = Struct.new(:code, :body, keyword_init: true) do
    def each_header
      return enum_for(:each_header) unless block_given?

      yield 'location', 'https://www.google.com/'
      yield 'content-type', 'text/html; charset=UTF-8'
    end
  end

  def test_fetch_falls_back_to_net_http_when_httpx_returns_nil
    uri = URI.parse('https://google.com')
    fake_response = FakeNetResponse.new(code: '301', body: '')

    response = Headers.stub(:httpx_fetch, nil) do
      Headers.stub(:net_http_response, fake_response) { Headers.fetch(uri) }
    end

    assert_equal 301, response.status
    assert_equal 'https://www.google.com/', response.headers['location']
    assert_equal 'text/html; charset=UTF-8', response.headers['content-type']
  end
end
