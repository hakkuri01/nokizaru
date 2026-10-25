require "./spec_helper"
require "../src/nokizaru/http/client"
require "../src/nokizaru/crawler/limits"
require "../src/nokizaru/dirrec/limits"

# Seam invariant: Nokizaru never announces itself. A tool-branded user-agent gets
# WAF/Cloudflare 403s (it broke keyless subdomain enumeration against real
# targets), so every default agent string is a real browser. Guards against
# reintroducing a self-identifying UA anywhere requests originate.
describe "default user agents" do
  agents = {
    "http default"     => Nokizaru::Http::USER_AGENT,
    "http header"      => Nokizaru::Http::DEFAULT_HEADERS["User-Agent"],
    "crawler primary"  => Nokizaru::Crawler::USER_AGENT,
    "crawler fallback" => Nokizaru::Crawler::FALLBACK_USER_AGENT,
    "dirrec default"   => Nokizaru::DirRec::DEFAULT_UA,
  }

  agents.each do |label, ua|
    it "#{label} is a browser string, not tool-branded" do
      ua.should start_with("Mozilla/5.0")
      ua.downcase.should_not contain("nokizaru")
    end
  end
end
