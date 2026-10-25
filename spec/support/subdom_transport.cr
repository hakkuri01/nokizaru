require "../../src/nokizaru/subdom/providers"

class SubdomClock
  property now : Time::Instant = Time.instant

  def advance(seconds : Float64) : Nil
    @now += seconds.seconds
  end
end

class SubdomPool < Nokizaru::Http::Pool
  getter requests = [] of Nokizaru::Subdom::Request
  getter budgets = [] of Float64
  getter peak = 0
  getter active = 0

  def initialize(@handler : Proc(Nokizaru::Subdom::Request, Nokizaru::Http::Result))
    super()
  end

  def request(method : String, url : String, options : Nokizaru::Http::Options = Nokizaru::Http::Options.new) : Nokizaru::Http::Result
    request = Nokizaru::Subdom::Request.new(url, method, options.headers, options.body)
    @requests << request
    @budgets << options.timeout_s
    @active += 1
    @peak = {@peak, @active}.max
    @handler.call(request)
  ensure
    @active -= 1
  end
end

def subdom_response(status = 200, body = "[]") : Nokizaru::Http::Result
  Nokizaru::Http::Result.ok(status, HTTP::Headers.new, body, false)
end

def censys_keys : Hash(String, String)
  {"censys_api_id" => "id", "censys_api_secret" => "secret"}
end

def censys_page(name = "a.example.com", cursor = "next") : String
  {result: {hits: [{names: [name]}], links: {next: cursor}}}.to_json
end
