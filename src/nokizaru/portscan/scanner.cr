require "socket"
require "wait_group"
require "../scan_stop"

module Nokizaru
  # The low-level TCP connect scanner (Nokizaru::Portscan), distinct from the
  # scan module Nokizaru::Modules::PortScan that drives it.
  module Portscan
    LARGE_SCAN_CONCURRENCY_MULTIPLIER =   20
    LARGE_SCAN_MAX_CONCURRENCY        = 1024
    # Headroom left below the open-file soft limit so the scan never consumes
    # the process's last descriptors.
    FD_HEADROOM     = 128
    MIN_CONCURRENCY =  64

    # One open port with the latency of the connect that confirmed it.
    record OpenPort, port : Int32, name : String, latency_ms : Float64

    # Per-scan knobs. `verify` re-confirms an open port with a second connect to
    # cut false positives (the careful default-spec scan); the broad custom/all
    # scans skip it for throughput. `rate_per_second` throttles probe starts; 0
    # disables it. Grouped so `scan` stays within the parameter budget, matching
    # Http::Options.
    struct Options
      getter connect_timeout : Float64
      getter concurrency : Int32
      getter retries : Int32
      getter? verify : Bool
      getter rate_per_second : Float64
      getter stop : ScanStop

      def initialize(
        @concurrency : Int32,
        @connect_timeout : Float64 = 1.0,
        @retries : Int32 = 1,
        @verify : Bool = true,
        @rate_per_second : Float64 = 0.0,
        @stop : ScanStop = ScanStop.new,
      )
      end
    end

    # A bounded-concurrency TCP connect scanner. One fiber per probe, capped at
    # Options#concurrency by a Channel of tokens; this folds Ruby's thread pool
    # and its non-blocking IO.select loop into one model, because a blocking
    # connect inside a fiber yields to the scheduler, so N in-flight probes cost
    # N fibers, not N threads. Open ports are collected behind a Mutex and
    # returned; the progress proc fires once per completed probe.
    #
    # Complexity: O(entries) probes, at most Options#concurrency in flight at
    # once and at most Options#rate_per_second started per second. Each probe is
    # O(1) connects (1 + retries, doubled when verifying). Memory is O(open
    # ports) for the result plus O(concurrency) live sockets.
    class Scanner
      def scan(ip : String, entries : Array({Int32, String}), options : Options, on_progress : Proc(Int32, Int32, Nil)? = nil) : Array(OpenPort)
        opens = [] of OpenPort
        mutex = Mutex.new
        scanned = Atomic(Int32).new(0)
        slots = Channel(Nil).new(options.concurrency)
        options.concurrency.times { slots.send(nil) }
        throttle = Throttle.new(options.rate_per_second)
        waiter = WaitGroup.new

        entries.each do |(port, name)|
          # A stopped scan starts no further probe; the ones in flight finish
          # within their connect timeout and release their sockets.
          break if options.stop.stopped?

          slots.receive
          waiter.add(1)
          spawn do
            probe(ip, port, name, options, throttle, opens, mutex)
          ensure
            slots.send(nil)
            if callback = on_progress
              done = scanned.add(1) + 1
              callback.call(done, mutex.synchronize { opens.size })
            end
            waiter.done
          end
        end
        waiter.wait
        opens
      end

      private def probe(ip : String, port : Int32, name : String, options : Options, throttle : Throttle, opens : Array(OpenPort), mutex : Mutex) : Nil
        throttle.wait
        started = Time.instant
        return unless open?(ip, port, options)

        latency = (Time.instant - started).total_milliseconds.round(2)
        mutex.synchronize { opens << OpenPort.new(port, name, latency) }
      end

      # One port is open when a TCP connect completes; `verify` requires a second
      # connect to agree, cutting transient false positives.
      private def open?(ip : String, port : Int32, options : Options) : Bool
        (options.retries + 1).times do
          next unless connect?(ip, port, options.connect_timeout)
          return true unless options.verify?
          return true if connect?(ip, port, options.connect_timeout)
        end
        false
      end

      private def connect?(ip : String, port : Int32, timeout : Float64) : Bool
        socket = TCPSocket.new(ip, port, connect_timeout: timeout)
        socket.close
        true
      rescue IO::Error | Socket::Error
        false
      end

      # min(threads * 20, 1024, fd_safe_limit). Security: bounding socket
      # fan-out guards against local FD exhaustion and accidental traffic
      # spikes.
      def self.large_scan_concurrency(threads : Int32) : Int32
        requested = {threads, 1}.max * LARGE_SCAN_CONCURRENCY_MULTIPLIER
        {requested, LARGE_SCAN_MAX_CONCURRENCY, fd_safe_limit}.min
      end

      # The open-file soft limit less headroom, clamped to [64, 1024]. Reads the
      # limit through LibC.getrlimit; a huge or unreadable limit yields the cap.
      def self.fd_safe_limit : Int32
        rlim = uninitialized LibC::Rlimit
        return LARGE_SCAN_MAX_CONCURRENCY unless LibC.getrlimit(LibC::RLIMIT_NOFILE, pointerof(rlim)) == 0

        soft = rlim.rlim_cur
        return LARGE_SCAN_MAX_CONCURRENCY if soft > LARGE_SCAN_MAX_CONCURRENCY + FD_HEADROOM

        (soft.to_i64 - FD_HEADROOM).clamp(MIN_CONCURRENCY.to_i64, LARGE_SCAN_MAX_CONCURRENCY.to_i64).to_i32
      end
    end

    # Spaces probe starts to at most rate_per_second across all fibers. A Mutex
    # serializes the next-start time so the whole scan honors one rate; a rate
    # of zero is a no-op.
    class Throttle
      def initialize(rate_per_second : Float64)
        @interval = rate_per_second > 0 ? (1.0 / rate_per_second).seconds : Time::Span.zero
        @mutex = Mutex.new
        @next_at = Time.instant
      end

      def wait : Nil
        return if @interval.zero?

        @mutex.synchronize do
          now = Time.instant
          sleep(@next_at - now) if @next_at > now
          @next_at = Time.instant + @interval
        end
      end
    end
  end
end
