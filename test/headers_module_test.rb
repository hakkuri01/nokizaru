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

  # A response that fails if anything reads its body
  class EndlessResponse < FakeNetResponse
    def body = raise('the body was read')
    def read_body = raise('the body was read')
  end

  # Stands in for Net::HTTP and yields an EndlessResponse, as a target streaming a body without end would
  class EndlessBodyHTTP
    attr_accessor :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout

    def use_ssl? = use_ssl

    def request(_request)
      yield EndlessResponse.new(code: '200')
      raise 'the request block must return before the body'
    end
  end

  def test_net_http_fallback_keeps_the_status_and_headers_and_never_reads_the_body
    uri = URI.parse('https://example.com')

    response = Net::HTTP.stub(:new, EndlessBodyHTTP.new) { Headers.send(:net_http_fetch, uri) }

    assert_equal 200, response.status
    assert_equal 'text/html; charset=UTF-8', response.headers['content-type']
  end
end
