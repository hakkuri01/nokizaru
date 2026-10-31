require "../spec_helper"
require "../support/http_test_server"
require "../../src/nokizaru/portscan/scanner"

describe Nokizaru::Portscan::Scanner do
  describe "#scan" do
    it "starts no probe once the scan is stopped" do
      listener = TCPServer.new("127.0.0.1", 0)
      open_port = listener.local_address.port
      begin
        stop = Nokizaru::ScanStop.new
        stop.stop!
        options = Nokizaru::Portscan::Options.new(concurrency: 4, connect_timeout: 0.5, verify: false, stop: stop)
        probes = Atomic(Int32).new(0)

        opens = Nokizaru::Portscan::Scanner.new.scan("127.0.0.1", Array.new(50) { {open_port, "svc"} }, options,
          ->(_scanned : Int32, _open : Int32) { probes.add(1); nil })

        opens.should be_empty
        probes.get.should eq(0)
      ensure
        listener.close
      end
    end

    it "reports an open port and skips a closed one" do
      listener = TCPServer.new("127.0.0.1", 0)
      open_port = listener.local_address.port
      closed_port = HttpTestServer.closed_port
      begin
        entries = [{open_port, "open-svc"}, {closed_port, "closed-svc"}]
        progress = Atomic(Int32).new(0)
        options = Nokizaru::Portscan::Options.new(concurrency: 8, connect_timeout: 0.5, verify: false)

        opens = Nokizaru::Portscan::Scanner.new.scan("127.0.0.1", entries, options, ->(_scanned : Int32, _open : Int32) { progress.add(1); nil })

        opens.size.should eq(1)
        opens.first.port.should eq(open_port)
        opens.first.name.should eq("open-svc")
        opens.first.latency_ms.should be >= 0.0
        progress.get.should eq(2) # one callback per probe, open or closed
      ensure
        listener.close
      end
    end

    it "honors the rate throttle without dropping results" do
      listener = TCPServer.new("127.0.0.1", 0)
      open_port = listener.local_address.port
      begin
        options = Nokizaru::Portscan::Options.new(concurrency: 4, connect_timeout: 0.5, verify: false, rate_per_second: 1000.0)
        opens = Nokizaru::Portscan::Scanner.new.scan("127.0.0.1", [{open_port, "svc"}], options)
        opens.map(&.port).should eq([open_port])
      ensure
        listener.close
      end
    end

    it "returns nothing for an empty entry list" do
      options = Nokizaru::Portscan::Options.new(concurrency: 4)
      Nokizaru::Portscan::Scanner.new.scan("127.0.0.1", [] of {Int32, String}, options).should be_empty
    end
  end

  describe ".large_scan_concurrency" do
    it "scales with threads and is bounded by the max and the fd limit" do
      fd = Nokizaru::Portscan::Scanner.fd_safe_limit
      Nokizaru::Portscan::Scanner.large_scan_concurrency(4).should eq({80, fd}.min) # 4 * 20, under the caps
      Nokizaru::Portscan::Scanner.large_scan_concurrency(1000).should eq({Nokizaru::Portscan::LARGE_SCAN_MAX_CONCURRENCY, fd}.min)
    end

    it "treats a non-positive thread count as one" do
      fd = Nokizaru::Portscan::Scanner.fd_safe_limit
      Nokizaru::Portscan::Scanner.large_scan_concurrency(0).should eq({20, fd}.min)
    end
  end

  describe ".fd_safe_limit" do
    it "stays within the clamp bounds" do
      limit = Nokizaru::Portscan::Scanner.fd_safe_limit
      limit.should be >= Nokizaru::Portscan::MIN_CONCURRENCY
      limit.should be <= Nokizaru::Portscan::LARGE_SCAN_MAX_CONCURRENCY
    end
  end
end
