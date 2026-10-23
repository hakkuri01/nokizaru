require "./limits"
require "./sample"
require "./fields"
require "../http/result"

module Nokizaru
  module DirRec
    # Turns a fetched response into a compact Sample. Ports response_sample from
    # dirrec/soft_404.rb: only statuses the module reasons about are sampled, and
    # the body is read once for its length, title, and fingerprint, then dropped.
    module Sampler
      extend self

      def sample(result : Http::Result, url : String) : Sample?
        status = result.status
        return nil if status.nil?
        return nil unless SOFT_404_SAMPLE_STATUSES.includes?(status)

        body = result.body || ""
        location_header = result.headers["Location"]?
        Sample.new(
          status: status,
          content_type: Fields.normalize_content_type(result.headers["Content-Type"]?),
          body_length: body.bytesize,
          title: Fields.extract_title(body),
          fingerprint: Fields.body_fingerprint(body, url),
          location: Fields.normalized_location_from_request(url, location_header),
          redirect_pattern: Fields.redirect_pattern(url, location_header),
        )
      end
    end
  end
end
