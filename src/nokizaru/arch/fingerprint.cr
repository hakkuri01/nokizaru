require "../http/result"

module Nokizaru
  module Modules
    module Arch
      # Passive, keyless technology fingerprinting from a single page response:
      # the Server / X-Powered-By / Set-Cookie headers plus the HTML generator
      # meta tag and well-known body markers. This is what lets arch report a tech
      # stack with no Wappalyzer key (the common case), which the directory
      # scanner then uses to inject a curated, tech-specific wordlist. One O(n)
      # pass over the already-capped body; header lookups are O(1).
      module Fingerprint
        extend self

        GENERATOR_TAG  = /name\s*=\s*["']?generator["']?/i
        GENERATOR_BODY = /content\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/i
        VERSION_TOKEN  = /([0-9]+(?:\.[0-9]+)+)/
        # A generator tag sits in the document head, and a single tag is short.
        # Both bounds matter: one pattern over the whole body backtracks
        # quadratically on repeated unterminated <meta tags (a 736 KB body took
        # 10.6 s), so each tag is located by index and matched on its own.
        HEAD_BYTES    = 64 * 1024
        MAX_TAG_BYTES = 1024
        SERVERS       = {"nginx" => "Nginx", "apache" => "Apache", "microsoft-iis" => "IIS", "litespeed" => "LiteSpeed", "openresty" => "OpenResty", "caddy" => "Caddy"}
        GENERATORS    = {"wordpress" => "WordPress", "drupal" => "Drupal", "joomla" => "Joomla"}

        def detect(result : Http::Result) : Array(Technology)
          headers = result.headers
          body = result.body || ""
          techs = [] of Technology
          server(headers, techs)
          powered_by(headers, techs)
          cookies(headers, techs)
          generator(headers, body, techs)
          body_markers(body, techs)
          Parser.dedupe(techs)
        end

        private def server(headers : ::HTTP::Headers, techs : Array(Technology)) : Nil
          value = headers["Server"]?.to_s.downcase
          return if value.empty?

          SERVERS.each do |needle, name|
            next unless value.includes?(needle)

            techs << Technology.new(name, version_in(value), ["Web servers"])
            break
          end
        end

        private def powered_by(headers : ::HTTP::Headers, techs : Array(Technology)) : Nil
          value = headers["X-Powered-By"]?.to_s.downcase
          return if value.empty?

          techs << Technology.new("PHP", version_in(value), ["Programming languages"]) if value.includes?("php")
          techs << Technology.new("ASP.NET", "", ["Web frameworks"]) if value.includes?("asp.net")
          techs << Technology.new("Express", "", ["Web frameworks"]) if value.includes?("express")
        end

        private def cookies(headers : ::HTTP::Headers, techs : Array(Technology)) : Nil
          names = (headers.get?("Set-Cookie") || [] of String).map(&.split('=', 2).first.strip.downcase)
          return if names.empty?

          techs << Technology.new("WordPress", "", ["CMS"]) if names.any? { |name| name.starts_with?("wordpress_") || name.starts_with?("wp-settings") || name.starts_with?("wp_") }
          techs << Technology.new("PHP", "", ["Programming languages"]) if names.includes?("phpsessid")
          techs << Technology.new("Java", "", ["Programming languages"]) if names.includes?("jsessionid")
          techs << Technology.new("Laravel", "", ["Web frameworks"]) if names.includes?("laravel_session")
          techs << Technology.new("Django", "", ["Web frameworks"]) if names.includes?("csrftoken")
          techs << Technology.new("Ruby on Rails", "", ["Web frameworks"]) if names.any? { |name| name.starts_with?('_') && name.ends_with?("_session") }
        end

        private def generator(headers : ::HTTP::Headers, body : String, techs : Array(Technology)) : Nil
          raw = generator_meta(body) || headers["X-Generator"]?.to_s
          return if raw.empty?

          down = raw.downcase
          GENERATORS.each do |needle, name|
            next unless down.includes?(needle)

            techs << Technology.new(name, version_in(raw), ["CMS"])
            break
          end
        end

        # The content of the first generator meta tag in the document head, found
        # by walking <meta ... > tags and testing each one alone. One pass over
        # the head, each tag test bounded by MAX_TAG_BYTES.
        private def generator_meta(body : String) : String?
          head = body.bytesize > HEAD_BYTES ? body.byte_slice(0, HEAD_BYTES) : body
          offset = 0
          while start = head.byte_index("<meta", offset)
            stop = head.byte_index(">", start) || head.bytesize
            tag = head.byte_slice(start, {stop - start, MAX_TAG_BYTES}.min)
            if tag.matches?(GENERATOR_TAG) && (match = tag.match(GENERATOR_BODY))
              value = match[1]? || match[2]? || match[3]?
              return value if value && !value.empty?
            end
            offset = stop + 1
          end
          nil
        end

        private def body_markers(body : String, techs : Array(Technology)) : Nil
          return if body.empty?

          techs << Technology.new("WordPress", "", ["CMS"]) if body.includes?("/wp-content/") || body.includes?("/wp-includes/")
          techs << Technology.new("Drupal", "", ["CMS"]) if body.includes?("Drupal.settings") || body.includes?("/sites/default/files")
          techs << Technology.new("Joomla", "", ["CMS"]) if body.includes?("/media/jui/") || body.includes?("com_content")
        end

        private def version_in(value : String) : String
          VERSION_TOKEN.match(value).try(&.[1]) || ""
        end
      end
    end
  end
end
