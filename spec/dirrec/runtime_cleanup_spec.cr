require "../spec_helper"
require "socket"
require "../../src/nokizaru/dirrec/runtime"

private class DirectoryConnections
  getter requests = [] of String
  getter sockets = [] of TCPSocket
  getter base : String

  def initialize(@body : Proc(String, String))
    @server = TCPServer.new("127.0.0.1", 0)
    @base = "http://127.0.0.1:#{@server.local_address.port}"
    @closed = Channel(Nil).new(8)
    spawn do
      while socket = @server.accept?
        @sockets << socket
        spawn serve(socket)
      end
    end
  end

  def await_closed(count : Int32) : Nil
    count.times { @closed.receive }
  end

  def close : Nil
    @server.close
    @sockets.each(&.close)
  end

  private def serve(socket : TCPSocket) : Nil
    while line = socket.gets
      path = line.split(' ', 3)[1]
      while header = socket.gets
        break if header.strip.empty?
      end
      @requests << path
      body = @body.call(path)
      socket << "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n\r\n" << body
      socket.flush
    end
  rescue IO::Error
    # Fixture teardown may interrupt a read
  ensure
    socket.close
    @closed.send(nil)
  end
end

private def cleanup_scan(server : DirectoryConnections, concurrency : Int32, paths : Array(String))
  urls = paths.map { |path| "#{server.base}/#{path}" }
  plan = Nokizaru::DirRec::UrlPlan.new(urls, [] of String, [] of String, [] of String, urls.size)
  policy = Nokizaru::DirRec::AdaptivePolicy.new(concurrency, 3.0, nil)
  runtime = Nokizaru::DirRec::Runtime.new(server.base, server.base, nil, Nokizaru::DirRec::ConfidenceContext.new(nil, nil), policy: policy)
  {runtime, Nokizaru::DirRec::LazyQueue.new(plan, server.base)}
end

describe "Directory worker cleanup" do
  it "continues after binary content with consistent accounting and closes every connection" do
    binary = "<title>binary</title>" + String.new(Bytes[0xff])
    server = DirectoryConnections.new(->(path : String) { path == "/binary" ? binary : "<title>valid</title>" })
    begin
      runtime, queue = cleanup_scan(server, 1, %w[binary valid])
      runtime.run(queue, 1, Nokizaru::Http::Options.new(timeout_s: 3.0))
      server.await_closed(1)
      server.sockets.size.should eq(1)
      server.requests.should eq(%w[/binary /valid])
      runtime.count.should eq(2)
      runtime.success.should eq(2)
      runtime.errors.should eq(0)
      runtime.observations.map(&.sample.title).should eq(%w[binary valid])
      runtime.observations.map(&.observed_count).should eq([1, 2])
      runtime.observations.first.sample.body_length.should eq(binary.bytesize)
    ensure
      server.close
    end
  end

  it "closes jobs and joins all workers before propagating a progress exception" do
    server = DirectoryConnections.new(->(_path : String) { "<title>valid</title>" })
    begin
      runtime, queue = cleanup_scan(server, 2, %w[first second never])
      progress = Nokizaru::ProgressReporter.new(Proc(String, String, Nil).new { |_stage, _detail| raise "progress failed" })
      expect_raises(Exception, "progress failed") do
        runtime.run(queue, 2, Nokizaru::Http::Options.new(timeout_s: 3.0), progress)
      end
      server.await_closed(2)
      server.sockets.size.should eq(2)
      server.requests.to_set.should eq(%w[/first /second].to_set)
      runtime.count.should eq(1)
      runtime.errors.should eq(0)
    ensure
      server.close
    end
  end
end
