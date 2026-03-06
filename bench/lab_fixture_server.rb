#!/usr/bin/env ruby
# frozen_string_literal: true

require 'socket'
require 'uri'

# Local deterministic benchmark target server used by Track A
class LabFixtureServer
  HOST = '127.0.0.1'
  PORT = 7777

  def initialize(host: HOST, port: PORT)
    @host = host
    @port = port
    @server = TCPServer.new(@host, @port)
  end

  def run
    puts "[lab] fixture server listening on http://#{@host}:#{@port}"
    loop do
      client = @server.accept
      Thread.new(client) { |socket| handle_client(socket) }
    end
  rescue Interrupt
    puts "\n[lab] shutting down"
  ensure
    begin
      @server.close
    rescue StandardError
      nil
    end
  end

  private

  def handle_client(socket)
    request_line = socket.gets
    return if request_line.nil?

    method, raw_path, = request_line.split(' ', 3)
    consume_headers(socket)

    path = safe_path(raw_path)
    response = route(method.to_s.upcase, path)
    write_response(socket, response)
  rescue StandardError
    write_response(socket, status: 500, headers: { 'Content-Type' => 'text/plain' }, body: 'internal error')
  ensure
    begin
      socket.close
    rescue StandardError
      nil
    end
  end

  def consume_headers(socket)
    loop do
      line = socket.gets
      break if line.nil? || line == "\r\n"
    end
  end

  def safe_path(raw_path)
    return '/' if raw_path.to_s.empty?

    parsed = URI.parse(raw_path)
    path = parsed.path.to_s
    path.empty? ? '/' : path
  rescue StandardError
    '/'
  end

  def route(method, path)
    return text(405, 'method not allowed') unless %w[GET HEAD].include?(method)

    case path
    when '/health'
      text(200, 'ok')
    when '/robots.txt'
      text(200, "User-agent: *\nDisallow: /private\nAllow: /static/login\nSitemap: http://127.0.0.1:7777/sitemap.xml\n")
    when '/sitemap.xml'
      xml(200, sitemap)
    when '/static'
      html(200,
           html_page('Static',
                     %w[/static/login /static/dashboard /static/admin/config /static/api/docs /static/account/profile
                        /assets/app.js]))
    when '/static/login'
      html(200, html_page('Login', %w[/static/account/profile]))
    when '/static/dashboard'
      html(200, html_page('Dashboard', %w[/static/admin/config /static/api/docs]))
    when '/static/admin/config'
      html(200, html_page('Admin', %w[/static/login]))
    when '/static/api/docs'
      html(200, html_page('API Docs', ['/static/api/v1/users?role=admin']))
    when '/redirect-root'
      { status: 302, headers: { 'Location' => 'http://127.0.0.1:7777/redirect-target', 'Content-Type' => 'text/plain' }, body: '' }
    when '/redirect-target'
      html(200, html_page('Redirect Target', %w[/redirect-target/login /redirect-target/admin]))
    when '/redirect-target/login'
      html(200, html_page('Redirect Login', %w[/redirect-target/session]))
    when '/redirect-target/admin'
      text(403, 'forbidden')
    when '/hostile'
      html(200, html_page('Hostile', %w[/hostile/challenge /hostile/slow]), 'Server' => 'cloudflare-sim')
    when '/hostile/challenge'
      text(429, 'rate limited')
    when '/hostile/slow'
      sleep(0.35)
      html(200, html_page('Slow', %w[/hostile/private]))
    when '/hostile/private'
      text(401, 'unauthorized')
    when '/'
      html(200, html_page('Index', %w[/static /redirect-root /hostile]))
    else
      text(404, 'not found')
    end
  end

  def text(status, body, extra_headers = {})
    { status: status, headers: { 'Content-Type' => 'text/plain' }.merge(extra_headers), body: body.to_s }
  end

  def html(status, body, extra_headers = {})
    { status: status, headers: { 'Content-Type' => 'text/html' }.merge(extra_headers), body: body.to_s }
  end

  def xml(status, body)
    { status: status, headers: { 'Content-Type' => 'application/xml' }, body: body.to_s }
  end

  def write_response(socket, response)
    status = response.fetch(:status)
    body = response.fetch(:body)
    headers = {
      'Content-Length' => body.bytesize.to_s,
      'Connection' => 'close'
    }.merge(response.fetch(:headers))

    socket.write("HTTP/1.1 #{status} #{reason(status)}\r\n")
    headers.each { |key, value| socket.write("#{key}: #{value}\r\n") }
    socket.write("\r\n")
    socket.write(body)
  end

  def reason(status)
    {
      200 => 'OK',
      302 => 'Found',
      401 => 'Unauthorized',
      403 => 'Forbidden',
      404 => 'Not Found',
      405 => 'Method Not Allowed',
      429 => 'Too Many Requests',
      500 => 'Internal Server Error'
    }.fetch(status.to_i, 'OK')
  end

  def sitemap
    <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
        <url><loc>http://127.0.0.1:7777/static/dashboard</loc></url>
        <url><loc>http://127.0.0.1:7777/static/api/docs</loc></url>
        <url><loc>http://127.0.0.1:7777/static/admin/config</loc></url>
      </urlset>
    XML
  end

  def html_page(title, links)
    rows = links.map { |path| "<li><a href=\"#{path}\">#{path}</a></li>" }.join
    <<~HTML
      <!DOCTYPE html>
      <html>
      <head><title>#{title}</title></head>
      <body>
        <h1>#{title}</h1>
        <ul>#{rows}</ul>
      </body>
      </html>
    HTML
  end
end

LabFixtureServer.new.run if $PROGRAM_NAME == __FILE__
