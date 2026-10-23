# Maintainer-only. Refreshes the embedded Public Suffix List.
#
# Run by the maintainer, never by the build or a scan, and never on CI:
#
#     crystal run tools/refresh_psl.cr
#
# It fetches the canonical list over TLS, and accepts the result only if it is
# still the structured Mozilla list and its delta against the committed baseline
# is purely rule and comment data (Nokizaru::PSL::Validate). On success it
# rewrites data/public_suffix_list.dat and prints the new SHA-256 to paste into
# Nokizaru::PSL::SHA256 (src/nokizaru/psl.cr); then review the diff and commit.
# On any failure it writes nothing and exits non-zero. There is no LLM in the
# loop: the one-time legitimacy judgment is already captured as the pinned
# baseline, and this tool only proves an update stays within that envelope.

require "http/client"
require "uri"
require "digest/sha256"
require "../src/nokizaru/psl/validate"

module RefreshPSL
  URL       = "https://publicsuffix.org/list/public_suffix_list.dat"
  DEST      = "#{__DIR__}/../data/public_suffix_list.dat"
  MIN_BYTES =   200_000
  MAX_BYTES = 2_000_000

  def self.run : Int32
    body = fetch
    return 1 unless body

    structure_ok, structure_reason = Nokizaru::PSL::Validate.structural_ok?(body)
    unless structure_ok
      STDERR.puts "refuse: structure check failed (#{structure_reason})"
      return 1
    end

    delta_ok, delta_reason = Nokizaru::PSL::Validate.delta_is_data_only?(File.read(DEST), body)
    unless delta_ok
      STDERR.puts "refuse: #{delta_reason}"
      return 1
    end

    File.write(DEST, body)
    puts "accepted: #{delta_reason}"
    puts "new SHA-256: #{Digest::SHA256.hexdigest(body)}"
    puts "paste into Nokizaru::PSL::SHA256 (src/nokizaru/psl.cr), review the diff, then commit."
    0
  end

  # Fetches the canonical list with timeouts. Refuses a non-200 (so an off-host
  # redirect, which stdlib HTTP::Client does not follow, is rejected), a wrong
  # content type, or an out-of-bounds body, and never raises past here.
  def self.fetch : String?
    uri = URI.parse(URL)
    client = HTTP::Client.new(uri)
    client.connect_timeout = 10.seconds
    client.read_timeout = 30.seconds
    begin
      response = client.get(uri.request_target)
    ensure
      client.close
    end

    unless response.status.success?
      STDERR.puts "refuse: HTTP #{response.status_code} from #{URL}"
      return nil
    end

    content_type = response.headers["Content-Type"]?
    unless content_type && content_type.includes?("text/plain")
      STDERR.puts "refuse: unexpected content-type #{content_type.inspect}"
      return nil
    end

    body = response.body
    unless (MIN_BYTES..MAX_BYTES).includes?(body.bytesize)
      STDERR.puts "refuse: body size #{body.bytesize} out of bounds"
      return nil
    end

    body
  rescue ex
    STDERR.puts "refuse: fetch failed (#{ex.class}: #{ex.message})"
    nil
  end
end

exit RefreshPSL.run
