require "uri"
require "random/secure"
require "../dirrec/limits"
require "../dirrec/fields"
require "../dirrec/plan"
require "../dirrec/queue"
require "../dirrec/sampler"
require "../dirrec/soft404"
require "../dirrec/context"
require "../dirrec/runtime"
require "../dirrec/results"
require "../dirrec/result"
require "../http/pool"
require "../target_intel"
require "../wordlist"
require "../progress_reporter"
require "./crawler"
require "./headers"
require "./wayback"
require "./arch"
require "./portscan"
require "../ui"

module Nokizaru
  module Modules
    # Directory/file enumeration with a lazy queue and bounded adaptive workers
    module DirectoryEnum
      extend self

      alias Result = Nokizaru::DirRec::Result

      # The scan configuration and the context results it reuses (the crawler and
      # headers results, and an optional pre-computed target profile).
      struct Config
        getter wordlist : String
        getter extensions : String
        getter threads : Int32
        getter? verify_ssl : Bool
        getter? allow_redirects : Bool
        getter request_headers : ::HTTP::Headers
        getter timeout_s : Float64
        getter crawler : Modules::Crawler::Result?
        getter headers : Modules::Headers::Result?
        getter wayback : Modules::Wayback::Result?
        getter arch : Modules::Arch::Result?
        getter portscan : Modules::PortScan::Result?
        getter profile : TargetIntel::Profile?

        def initialize(
          @wordlist : String,
          @extensions : String = "",
          @threads : Int32 = 10,
          @verify_ssl : Bool = true,
          @allow_redirects : Bool = false,
          @request_headers : ::HTTP::Headers = ::HTTP::Headers.new,
          @timeout_s : Float64 = Nokizaru::DirRec::DEFAULT_TIMEOUT,
          @crawler : Modules::Crawler::Result? = nil,
          @headers : Modules::Headers::Result? = nil,
          @wayback : Modules::Wayback::Result? = nil,
          @arch : Modules::Arch::Result? = nil,
          @portscan : Modules::PortScan::Result? = nil,
          @profile : TargetIntel::Profile? = nil,
        )
        end
      end

      # Renders the enumeration for the classic output and the dashboard capture:
      # each prioritized finding colored by its status code, then a compact
      # summary (requests/second, counts). Header bar dropped in TUI mode.
      def present(result : Result) : Nil
        UI.module_header("Directory Enum")
        present_findings(result)
        present_summary(result)
      end

      private def present_findings(result : Result) : Nil
        status_by_url = {} of String => Int32
        result.by_status.each do |status, urls|
          code = status.to_i
          urls.each { |url| status_by_url[url] = code }
        end
        result.stdout_found.each do |url|
          UI.line(:info, "#{colorize_status(status_by_url[url]? || 0)} #{UI::W}//#{UI::C} #{url}")
        end
      end

      private def present_summary(result : Result) : Nil
        UI.blank_line
        found = result.found.uniq.size
        low = result.low_confidence_found.uniq.size
        labels = ["Requests/second", "Directories found"]
        labels << "Low confidence" if low > 0
        width = labels.max_of(&.size)

        UI.row(:info, "Requests/second", result.stats.requests_per_second.to_s, label_width: width)
        UI.row(:info, "Directories found", found.to_s, label_width: width)
        UI.row(:info, "Low confidence", low.to_s, label_width: width) if low > 0
        if reason = result.stats.stop_reason_display
          UI.row(:info, "Stopped early", reason, label_width: width)
          if shape = result.stats.stop_status_code_shape
            UI.row(:info, "Response shape", shape, label_width: width)
          end
        end
        UI.blank_line
      end

      # The Ruby status palette: 2xx green, 3xx yellow, 4xx red, 5xx magenta.
      private def colorize_status(code : Int32) : String
        color = case code
                when 200..299 then UI::G
                when 300..399 then UI::Y
                when 400..499 then UI::R
                when 500..599 then UI::M
                else               UI::W
                end
        "#{color}#{code}#{UI::W}"
      end

      def collect(target : String, config : Config, progress : ProgressReporter = ProgressReporter::NULL) : Result
        profile = config.profile || compute_profile(target, config)
        anchor = TargetIntel.reanchor_decision(target, profile)
        scan_target = anchor.effective_target
        normalized = DirRec::Fields.normalize_target_base(scan_target)

        context = wayback_seed_paths(config.wayback, normalized)
        context.concat(tech_seed_paths(config.arch))
        context.uniq!
        plan = DirRec::Plan.build(normalized, Nokizaru::Wordlist.load(config.wordlist), config.extensions, crawler_seed_paths(config.crawler, normalized), context, alt_origin_seeds(config.portscan, scan_target))
        concurrency = Math.max(config.threads, 1)
        extension_enabled = !plan.extensions.empty?
        baseline = build_initial_baseline(normalized, config)
        policy = DirRec::AdaptivePolicy.new(concurrency, config.timeout_s, baseline, extensions: extension_enabled)
        runtime = DirRec::Runtime.new(scan_target, normalized, baseline, DirRec::ConfidenceContext.new(config.headers, config.crawler), policy: policy)

        runtime.run(DirRec::LazyQueue.new(plan, normalized, extension_enabled), concurrency, worker_options(config), progress, plan.estimated_total)
        info = DirRec::Target.new(original: target, effective: scan_target, reanchored: anchor.reanchor?, reason: anchor.reason)
        DirRec::Results.assemble(runtime, info, plan, normalized, concurrency, extension_enabled)
      end

      private def worker_options(config : Config) : Http::Options
        headers = ::HTTP::Headers.new
        config.request_headers.each { |name, values| headers[name] = values }
        headers["User-Agent"] = DirRec::DEFAULT_UA
        Http::Options.new(headers: headers, timeout_s: config.timeout_s, verify_ssl: config.verify_ssl?,
          follow_redirects: config.allow_redirects?, scope_check: TargetIntel.scope_check)
      end

      private def compute_profile(target : String, config : Config) : TargetIntel::Profile
        pool = Http::Pool.new
        options = Http::Options.new(timeout_s: {config.timeout_s, 10.0}.min, verify_ssl: config.verify_ssl?, follow_redirects: false)
        profile = TargetIntel.profile(target, pool.get(target, options))
        pool.shutdown
        profile
      end

      private def build_initial_baseline(normalized : String, config : Config) : DirRec::Baseline?
        pool = Http::Pool.new
        base = DirRec::Fields.normalize_target_base(normalized)
        samples = [] of DirRec::Sample
        DirRec::SOFT_404_PROBES.times do
          probe_url = "#{base}/#{Random::Secure.hex(10)}"
          result = pool.get(probe_url, worker_options(config))
          next if result.error?

          sample = DirRec::Sampler.sample(result, probe_url)
          samples << sample if sample
        end
        DirRec::Soft404.build_from_samples(samples)
      rescue
        nil
      ensure
        pool.try(&.shutdown)
      end

      private def crawler_seed_paths(crawler : Modules::Crawler::Result?, base_target : String) : Array(String)
        return [] of String if crawler.nil?

        base_uri = URI.parse(base_target)
        paths = crawler_seed_urls(crawler).compact_map { |url| seed_path_in_scope(url, base_uri) }
        paths.uniq!
        paths
      end

      # Historic URLs from the Wayback module become directory-scan seeds: a path
      # the site served before but that is no longer linked, in the sitemap, or in
      # the wordlist is reachable only because wayback remembered it. Same-scope
      # and relativized exactly like the crawler feed.
      private def wayback_seed_paths(wayback : Modules::Wayback::Result?, base_target : String) : Array(String)
        return [] of String if wayback.nil?

        base_uri = URI.parse(base_target)
        paths = wayback.urls.compact_map { |url| seed_path_in_scope(url, base_uri) }
        paths.uniq!
        paths
      end

      # Curated, tech-specific paths injected when architecture fingerprinting
      # identified the stack: a WordPress target gets its wp-* surface probed even
      # when those paths are absent from the generic wordlist. This is the
      # directory scanner using the arch module's conclusion rather than brute
      # force, the "well-informed" half of an all-in-one snapshot.
      TECH_PATHS = {
        "wordpress" => %w[/wp-admin/ /wp-login.php /wp-content/ /wp-includes/ /wp-json/ /wp-json/wp/v2/users /xmlrpc.php /wp-config.php /wp-content/debug.log /wp-content/uploads/],
        "drupal"    => %w[/user/login /admin /core/CHANGELOG.txt /CHANGELOG.txt /sites/default/files/ /sites/default/settings.php],
        "joomla"    => %w[/administrator/ /configuration.php /administrator/manifests/files/joomla.xml],
        "php"       => %w[/phpinfo.php /info.php],
      }

      private def tech_seed_paths(arch : Modules::Arch::Result?) : Array(String)
        return [] of String if arch.nil?

        paths = [] of String
        arch.technologies.each do |tech|
          name = tech.name.downcase
          TECH_PATHS.each { |needle, list| paths.concat(list) if name.includes?(needle) }
        end
        paths.uniq!
        paths
      end

      # When the port scan found a web service on a non-standard port (8080, 8443,
      # ...), probe that origin too: an app on an alternate port is a common
      # recon pivot that a target-root-only scan misses. The scanner's own
      # http/tls hints pick the ports and scheme; each origin contributes its
      # root and the high-signal paths as absolute seeds, same-host so in scope.
      private def alt_origin_seeds(portscan : Modules::PortScan::Result?, scan_target : String) : Array(String)
        return [] of String if portscan.nil?

        uri = URI.parse(scan_target)
        host = uri.host
        return [] of String if host.nil? || host.empty?

        seeds = [] of String
        portscan.ports.each do |record|
          next unless alt_web_port?(record)

          base = "#{record.tls_likely? ? "https" : "http"}://#{host}:#{record.port}"
          seeds << "#{base}/"
          DirRec::HIGH_SIGNAL_PATHS.each { |path| seeds << "#{base}#{path}" }
        end
        seeds.uniq!
        seeds
      end

      private def alt_web_port?(record : Nokizaru::Portscan::PortRecord) : Bool
        record.state == "open" && record.port != 80 && record.port != 443 &&
          (record.http_likely? || record.tls_likely?)
      end

      private def crawler_seed_urls(crawler : Modules::Crawler::Result) : Array(String)
        urls = [] of String
        urls.concat(crawler.high_signal_urls || [] of String)
        urls.concat(crawler.internal_links)
        urls.concat(crawler.robots_links)
        urls.concat(crawler.urls_inside_js)
        urls.concat(crawler.urls_inside_sitemap)
        urls
      end

      private def seed_path_in_scope(url : String, base_uri : URI) : String?
        uri = URI.parse(url)
        return nil unless TargetIntel.same_scope_host?(base_uri.host || "", uri.host || "")

        path = uri.path.empty? ? "/" : uri.path
        path = relative_seed_path(path, base_uri.path)
        path == "/" ? nil : path
      rescue
        nil
      end

      private def relative_seed_path(path : String, base_path : String) : String
        cleaned = base_path.rchop("/")
        return path if cleaned.empty? || cleaned == "/"
        return "/" if path == cleaned
        return path unless path.starts_with?("#{cleaned}/")

        path.lchop(cleaned)
      end
    end
  end
end
