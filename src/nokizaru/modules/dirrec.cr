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
require "../ui"

module Nokizaru
  module Modules
    # Directory/file enumeration (the Ruby DirectoryEnum). Route B: the faithful
    # deterministic core (lazy queue, soft-404, confidence, WAF context, results)
    # driven by a fixed bounded-fiber worker pool; the adaptive engine (preflight
    # hostility, mode budgets, pressure/concurrency tuning) is left at neutral
    # stat defaults, to be rebuilt from benchmark data. Ports modules/dirrec.rb's
    # `call`. UI rendering and ctx/progress wiring are assembled with the runner.
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
          @profile : TargetIntel::Profile? = nil,
        )
        end
      end

      # Renders the enumeration for the classic output and the dashboard capture:
      # each prioritized finding colored by its status code, then a compact
      # summary (requests/second, counts). Header bar dropped in TUI mode.
      #
      # ponytail: the Ruby tool also printed a "3xx Signals" block built from
      # runtime redirect telemetry that the parity Result does not carry, and the
      # route-B stats leave stop_reason/stop_status_code_shape null, so those rows
      # are omitted here; everything rendered is Result-derived.
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

        plan = DirRec::Plan.build(normalized, Nokizaru::Wordlist.load(config.wordlist), config.extensions, crawler_seed_paths(config.crawler, normalized))
        runtime = DirRec::Runtime.new(scan_target, normalized, build_initial_baseline(normalized, config), DirRec::ConfidenceContext.new(config.headers, config.crawler))
        concurrency = Math.max(config.threads, 1)
        extension_enabled = !plan.extensions.empty?

        runtime.run(DirRec::LazyQueue.new(plan, normalized, extension_enabled), concurrency, worker_options(config), progress, plan.estimated_total)
        info = DirRec::Target.new(original: target, effective: scan_target, reanchored: anchor.reanchor?, reason: anchor.reason)
        DirRec::Results.assemble(runtime, info, plan, normalized, concurrency, extension_enabled)
      end

      private def worker_options(config : Config) : Http::Options
        headers = ::HTTP::Headers.new
        config.request_headers.each { |name, values| headers[name] = values }
        headers["User-Agent"] = DirRec::DEFAULT_UA
        follow = config.allow_redirects? && config.request_headers.empty?
        Http::Options.new(headers: headers, timeout_s: config.timeout_s, verify_ssl: config.verify_ssl?, follow_redirects: follow)
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
          result = pool.get("#{base}/#{Random::Secure.hex(10)}", worker_options(config))
          next if result.error?

          sample = DirRec::Sampler.sample(result, base)
          samples << sample if sample
        end
        pool.shutdown
        DirRec::Soft404.build_from_samples(samples)
      rescue
        nil
      end

      private def crawler_seed_paths(crawler : Modules::Crawler::Result?, base_target : String) : Array(String)
        return [] of String if crawler.nil?

        base_uri = URI.parse(base_target)
        paths = crawler_seed_urls(crawler).compact_map { |url| crawler_seed_path(url, base_uri) }
        paths.uniq!
        paths
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

      private def crawler_seed_path(url : String, base_uri : URI) : String?
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
