require "../../src/nokizaru/wayback/query"

class WaybackClock
  property instant : Time::Instant = Time.instant
  getter sleeps = [] of Float64

  def advance(seconds : Float64) : Nil
    @instant += seconds.seconds
  end

  def sleep(delay : Time::Span) : Nil
    @sleeps << delay.total_seconds
    @instant += delay
  end
end

record WaybackRequest, worker : Int32, url : String, budget : Float64, started : Time::Instant

class WaybackTransport
  getter requests = [] of WaybackRequest
  getter closed = [] of Int32
  getter peak = 0
  @active = 0
  @workers = 0

  def initialize(@clock : WaybackClock, @handler : Proc(WaybackRequest, Nokizaru::Http::Result))
  end

  def pool : Nokizaru::Http::Pool
    @workers += 1
    WaybackPool.new(self, @workers)
  end

  def request(worker : Int32, url : String, options : Nokizaru::Http::Options) : Nokizaru::Http::Result
    request = WaybackRequest.new(worker, url, options.timeout_s, @clock.instant)
    @requests << request
    @active += 1
    @peak = {@peak, @active}.max
    @handler.call(request)
  ensure
    @active -= 1
  end

  def fetcher : Nokizaru::Wayback::Fetcher
    Nokizaru::Wayback::Fetcher.new(pool,
      clock: -> { @clock.instant }, sleeper: ->(delay : Time::Span) { @clock.sleep(delay) },
      wall_clock: -> { Time.utc(2026, 1, 1) }, pool_factory: -> : Nokizaru::Http::Pool { pool })
  end
end

class WaybackPool < Nokizaru::Http::Pool
  def initialize(@transport : WaybackTransport, @id : Int32)
    super()
  end

  def get(url : String, options : Nokizaru::Http::Options = Nokizaru::Http::Options.new) : Nokizaru::Http::Result
    @transport.request(@id, url, options)
  end

  def shutdown : Nil
    @transport.closed << @id
  end
end

def wayback_response(status = 200, body = "", retry_after : String? = nil) : Nokizaru::Http::Result
  headers = HTTP::Headers.new
  headers["Retry-After"] = retry_after if retry_after
  Nokizaru::Http::Result.ok(status, headers, body, false)
end

def wayback_page(path = "/admin", resume : String? = nil) : String
  rows = [Nokizaru::Wayback::Cdx::FIELDS, ["20230101000000", "http://example.com#{path}", "text/html", "200", "AAA"]]
  if resume
    rows << [] of String
    rows << [resume]
  end
  rows.to_json
end

def wayback_query(transport : WaybackTransport, budget = 60.0) : Nokizaru::Wayback::Query
  Nokizaru::Wayback::Query.new(transport.fetcher, Nokizaru::Wayback::CDX_URL, Nokizaru::Wayback::AVAIL_URL, budget)
end
