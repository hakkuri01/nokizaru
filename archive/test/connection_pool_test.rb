# frozen_string_literal: true

require_relative 'test_helper'

class ConnectionPoolTest < Minitest::Test
  def test_ssl_options_allow_httpx_default_alpn_protocols
    options = Nokizaru::ConnectionPool.new.send(:ssl_options, true)

    refute_includes options.keys, :alpn_protocols
  end

  def test_ssl_options_preserve_explicit_verification_disable
    options = Nokizaru::ConnectionPool.new.send(:ssl_options, false)

    assert_equal OpenSSL::SSL::VERIFY_NONE, options[:verify_mode]
    refute_includes options.keys, :alpn_protocols
  end

  def test_default_headers_do_not_send_http1_connection_header_over_http2
    keys = Nokizaru::ConnectionPool::DEFAULT_HEADERS.keys.map(&:downcase)

    refute_includes keys, 'connection'
  end

  CAP = Nokizaru::BodyCap::MAX_BYTES

  def test_a_gzip_bomb_inflates_no_further_than_the_body_cap
    bomb = gzip("\0" * (CAP * 3))
    pool = Nokizaru::ConnectionPool.new

    [pool.client, pool.send(:fallback_client, {}, 5, true)].each do |client|
      assert_equal CAP, feed(client, { 'content-encoding' => 'gzip' }, bomb).bytesize
    end
  end

  def test_an_endless_identity_body_stops_buffering_at_the_cap
    body = feed(Nokizaru::ConnectionPool.new.client, {}, 'a' * (CAP + (64 * 1024)))

    assert_operator body.bytesize, :<=, CAP + 16_384, 'at most one read past the cap'
  end

  def test_ordinary_gzip_bodies_still_decode
    page = '<html>hello</html>'

    assert_equal page, feed(Nokizaru::ConnectionPool.new.client, { 'content-encoding' => 'gzip' }, gzip(page)).to_s
  end

  private

  def gzip(text)
    io = StringIO.new
    Zlib::GzipWriter.wrap(io) { |writer| writer.write(text) }
    io.string
  end

  # Delivers the wire bytes in httpx's own 16 KB reads to a response built by the client under test
  def feed(client, headers, wire)
    response = HTTPX::Response.new(client.build_request('GET', 'http://example.invalid/'), 200, '1.1', headers)
    0.step(wire.bytesize - 1, 16_384) { |offset| response << wire.byteslice(offset, 16_384) }
    response.body
  end
end
