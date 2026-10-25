require "../spec_helper"
require "../support/subdom_transport"

describe Nokizaru::Subdom::Censys do
  it "retains completed pages and reports a later rate limit truthfully" do
    calls = 0
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
      calls += 1
      calls == 1 ? subdom_response(200, censys_page) : subdom_response(429)
    })
    result = Nokizaru::Subdom::Censys.new.run("example.com", pool, censys_keys, 12.0)

    result.names.should eq(["a.example.com"])
    result.result_count.should eq(1)
    result.status.should eq("rate_limited")
    result.reason.should eq("HTTP 429")
    pool.requests.size.should eq(2)
    JSON.parse(pool.requests.last.body.not_nil!)["cursor"].as_s.should eq("next")
  end

  it "shrinks page budgets against one provider deadline" do
    clock = SubdomClock.new
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
      clock.advance(4.0)
      subdom_response(200, censys_page)
    })
    result = Nokizaru::Subdom::Censys.new.run("example.com", pool, censys_keys, 8.0, clock: -> { clock.now })

    pool.budgets.should eq([8.0, 4.0])
    result.names.should eq(["a.example.com"])
    result.result_count.should eq(1)
    result.status.should eq("timeout")
    result.elapsed_s.should eq(8.0)
  end

  it "does not dispatch the next page once the shared scan deadline expires" do
    clock = SubdomClock.new
    deadline = clock.now + 3.seconds
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
      clock.advance(3.0)
      subdom_response(200, censys_page)
    })
    result = Nokizaru::Subdom::Censys.new.run("example.com", pool, censys_keys, 12.0, clock: -> { clock.now }, deadline: deadline)

    pool.budgets.should eq([3.0])
    result.names.should eq(["a.example.com"])
    result.status.should eq("timeout")
  end

  it "retains names after malformed later pages or transport timeouts" do
    [subdom_response(200, "{"), Nokizaru::Http::Result.failure(Nokizaru::Http::ErrorKind::Timeout, "budget spent")].each do |failure|
      calls = 0
      pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) {
        calls += 1
        calls == 1 ? subdom_response(200, censys_page) : failure
      })
      result = Nokizaru::Subdom::Censys.new.run("example.com", pool, censys_keys, 12.0)
      result.names.should eq(["a.example.com"])
      result.result_count.should eq(1)
      result.status.should eq(failure.error? ? "timeout" : "error")
      pool.requests.size.should eq(2)
    end
  end

  it "finishes normally at the last cursor and respects the page cap" do
    ["", "next"].each do |cursor|
      pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) { subdom_response(200, censys_page(cursor: cursor)) })
      result = Nokizaru::Subdom::Censys.new.run("example.com", pool, censys_keys, 12.0)
      result.status.should eq("healthy")
      result.names.should eq(["a.example.com"])
      pool.requests.size.should eq(cursor.empty? ? 1 : Nokizaru::Subdom::Censys::MAX_PAGES)
    end
  end
end

describe Nokizaru::Subdom::Provider do
  it "makes no request when its operation deadline has already expired" do
    clock = SubdomClock.new
    pool = SubdomPool.new(->(_request : Nokizaru::Subdom::Request) { subdom_response })
    result = Nokizaru::Subdom::AnubisDB.new.run("example.com", pool, {} of String => String, 5.0,
      clock: -> { clock.now }, deadline: clock.now)

    pool.requests.should be_empty
    result.status.should eq("timeout")
  end
end
