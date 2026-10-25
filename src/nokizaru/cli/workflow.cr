require "uri"
require "../run_state"
require "../target_info"
require "../settings"
require "../progress_rail"
require "../export_manager"
require "../keystore"
require "../http/pool"
require "../dns/resolver"
require "../findings/engine"
require "../ui"
require "../log"
require "./options"
require "./runtime"
require "./workflow_artifacts"
require "./workflow_failures"

module Nokizaru::CLI
  # The scan runner: resolves the target, plans the module set and export
  # destination, runs each enabled module in order, then finalizes (timing,
  # findings, export, completion). Ports the Ruby Runner::Workflow. The Crystal
  # modules are pure `collect→Result`, so this stores each typed Result on the
  # run and drives each module's `present`; guarded failures and port skips are
  # recorded as typed outcome envelopes under the same exported module keys.
  # The interactive Session drives plan!/execute!/
  # finalize! directly; classic mode calls `run`.
  class Workflow
    # A fatal condition the runner cannot proceed past (no target, no modules, a
    # bad export option). CLI.start renders the message and exits non-zero.
    class Error < Exception
    end

    # Raised internally when a module overruns its budget; caught per module.
    class ModuleTimeout < Exception
    end

    # The resolved scan plan: the target, the typed run state, the live progress
    # rail, the start stamp, and the enabled module keys. plan! returns it so the
    # Session and the classic driver share one setup.
    struct Plan
      getter info : TargetInfo
      getter state : RunState
      getter rail : ProgressRail
      getter started_at : Time
      getter enabled : Array(String)

      def initialize(@info, @state, @rail, @started_at, @enabled)
      end
    end

    # The human label per module key, for the progress rail and skip lines.
    LABELS = {
      "headers" => "Headers", "sslinfo" => "SSL Certificate Information", "whois" => "Whois Lookup",
      "dns" => "DNS Enumeration", "sub" => "Sub-Domain Enumeration", "arch" => "Architecture Fingerprinting",
      "ps" => "Port Scan", "crawl" => "Crawler", "dir" => "Directory Enum", "wayback" => "WayBack Machine",
    }

    # The Wayback module is given an inner time budget; the outer per-module
    # timeout adds this margin so the module can finish its own cleanup first.
    WAYBACK_OUTER_MARGIN = 5.0

    def initialize(
      @options : Options,
      @settings : Settings = Settings.new,
      @resolve_ip : Proc(String, String?) = ->(host : String) { Dns::Resolver.new.resolve(host) },
    )
    end

    # Classic end-to-end run: banner, plan, execute, finalize. Returns the
    # elapsed seconds and the export directory (nil when export is off).
    def run : {Float64, String?}
      boot!
      plan = plan!
      execute!(plan)
      finalize!(plan)
    end

    # Settings and keys are handled by CLI.start before any scan; here boot! only
    # prints the banner, which the caller suppresses with -nb.
    def boot! : Nil
      Runtime.banner unless @options.nb?
    end

    # Resolves the target (and prints its context), checks that at least one
    # module is enabled, validates the export destination up front, and builds
    # the run state and progress rail. Raises Error on a fatal condition.
    def plan! : Plan
      enabled = @options.enabled_modules
      raise Error.new("No Modules Specified! Use --full or a module flag") if enabled.empty?

      info = resolve_target
      Runtime.present_target(info)
      prepare_export(info)

      started = Time.utc
      Plan.new(info, Runtime.initial_run_state(info, started), ProgressRail.new(enabled), started, enabled)
    end

    # Runs each enabled module in MODULE_ORDER against a shared HTTP pool,
    # storing each typed result on the run and rendering it. Skips honor the
    # Ruby rules (port scan needs an IP, subdomains need a non-IP host).
    def execute!(plan : Plan) : Nil
      pool = Http::Pool.new
      begin
        run_headers(plan, pool)
        run_sslinfo(plan)
        run_whois(plan)
        run_dns(plan)
        run_subdomains(plan)
        run_arch(plan, pool)
        run_portscan(plan)
        run_crawler(plan, pool)
        run_directory(plan)
        run_wayback(plan, pool)
      ensure
        pool.shutdown
      end
    end

    # Stamps the timing, computes and prints findings, exports when requested,
    # and prints the completion line. Returns the elapsed seconds and export dir.
    def finalize!(plan : Plan) : {Float64, String?}
      elapsed = Runtime.finalize_timing(plan.state, plan.started_at)
      compute_findings(plan.state)
      export_dir = export_if_enabled(plan.state, plan.info)
      print_completion(elapsed, export_dir)
      {elapsed, export_dir}
    end

    # The outer per-module time budget (seconds); 0 means unbounded, as the Ruby
    # tool left the crawler and directory scans (both self-bound internally).
    def module_timeout_s(info : TargetInfo, key : String) : Float64
      base = info.timeout
      return 0.0 if base <= 0

      case key
      when "headers", "sslinfo", "whois" then {base * 3.0, 25.0}.max
      when "dns"                         then {base * 4.0, 40.0}.max
      when "sub", "arch"                 then {base * 5.0, 60.0}.max
      when "ps"                          then port_scan_timeout_s(info, base)
      when "wayback"                     then {base * 2.0, 24.0}.max
      else                                    0.0
      end
    end

    # The count of ports a custom spec requests, or nil for the default/empty
    # spec (which uses the flat default budget). Used to widen the scan budget
    # for a large custom range.
    def requested_port_count(spec : String?) : Int32?
      value = spec.to_s.strip.downcase
      return nil if value.empty? || Modules::PortScan::DEFAULT_PORT_SPECS.includes?(value)

      Modules::PortScan.port_entries(spec).size
    rescue ArgumentError
      nil
    end

    private def port_scan_timeout_s(info : TargetInfo, base : Float64) : Float64
      default_timeout = {base * 6.0, 90.0}.max
      requested = requested_port_count(info.pscan_ports)
      return default_timeout if requested.nil?

      {default_timeout, (requested / 150.0) + base}.max
    end

    private def resolve_target : TargetInfo
      TargetInfo.resolve(@options, @settings, @resolve_ip)
    end

    private def run_headers(plan : Plan, pool : Http::Pool) : Nil
      info = plan.info
      result = run_module(plan, "headers", module_timeout_s(info, "headers")) do
        Modules::Headers.collect(info.target, pool, info.request_headers)
      end
      return if result.nil?

      Modules::Headers.present(result)
    end

    private def run_sslinfo(plan : Plan) : Nil
      info = plan.info
      result = run_module(plan, "sslinfo", module_timeout_s(info, "sslinfo")) do
        Modules::SSLInfo.collect(info.hostname, info.ssl_port)
      end
      return if result.nil?

      Modules::SSLInfo.present(result)
    end

    private def run_whois(plan : Plan) : Nil
      info = plan.info
      result = run_module(plan, "whois", module_timeout_s(info, "whois")) do
        Modules::WhoisLookup.collect(info.domain, info.suffix)
      end
      return if result.nil?

      Modules::WhoisLookup.present(result)
    end

    private def run_dns(plan : Plan) : Nil
      info = plan.info
      result = run_module(plan, "dns", module_timeout_s(info, "dns")) do
        Modules::DnsEnumeration.collect(info.hostname, dns_servers_list(info))
      end
      return if result.nil?

      Modules::DnsEnumeration.present(result)
    end

    private def run_subdomains(plan : Plan) : Nil
      return unless plan.enabled.includes?("sub")

      info = plan.info
      if info.type_ip?
        skip(plan, "sub", "Skipping Sub-Domain Enumeration : Not Supported for IP Addresses")
        return
      end
      return skip(plan, "sub", "Skipping Sub-Domain Enumeration : Not Supported for private addresses") if info.private_ip?

      result = run_guarded(plan, "sub", module_timeout_s(info, "sub")) do
        Modules::Subdomains.collect(info.hostname, info.timeout, progress: plan.rail.reporter("sub"))
      end
      return if result.nil?

      Modules::Subdomains.present(result)
    end

    private def run_arch(plan : Plan, pool : Http::Pool) : Nil
      info = plan.info
      result = run_module(plan, "arch", module_timeout_s(info, "arch")) do
        Modules::Arch.collect(third_party_target(info.target), pool, KeyStore.fetch("wappalyzer", "NK_WAPPALYZER_KEY"), info.timeout)
      end
      return if result.nil?

      Modules::Arch.present(result)
    end

    private def run_portscan(plan : Plan) : Nil
      return unless plan.enabled.includes?("ps")

      info = plan.info
      ip = info.ip
      if ip.nil? || ip.empty?
        skip_portscan_without_ip(plan)
        return
      end

      result = run_guarded(plan, "ps", module_timeout_s(info, "ps")) do
        Modules::PortScan.collect(ip, info.pscan_threads, spec: info.pscan_ports, progress: plan.rail.reporter("ps"))
      end
      return if result.nil?

      Modules::PortScan.present(result)
    end

    private def run_crawler(plan : Plan, pool : Http::Pool) : Nil
      info = plan.info
      result = run_module(plan, "crawl", module_timeout_s(info, "crawl")) do
        Modules::Crawler.collect(info.target, pool, info.request_headers, header_profile(plan.state))
      end
      return if result.nil?

      Modules::Crawler.present(result)
    end

    private def run_directory(plan : Plan) : Nil
      info = plan.info
      result = run_module(plan, "dir", module_timeout_s(info, "dir")) do
        Modules::DirectoryEnum.collect(info.target, directory_config(info, plan.state), plan.rail.reporter("dir"))
      end
      return if result.nil?

      Modules::DirectoryEnum.present(result)
    end

    private def run_wayback(plan : Plan, pool : Http::Pool) : Nil
      info = plan.info
      inner = module_timeout_s(info, "wayback")
      outer = inner > 0 ? inner + WAYBACK_OUTER_MARGIN : 0.0
      result = run_module(plan, "wayback", outer) do
        Modules::Wayback.collect(third_party_target(info.target), pool, timeout_s: inner)
      end
      return if result.nil?

      Modules::Wayback.present(result)
    end

    # Runs a module unconditionally subject to its enabled flag, bounded by its
    # timeout; a raise or timeout marks the module failed and returns nil.
    private def run_module(plan : Plan, key : String, timeout_s : Float64, &block : -> T) : T? forall T
      return nil unless plan.enabled.includes?(key)

      run_guarded(plan, key, timeout_s, &block)
    end

    # The started→(collect with timeout)→finished lifecycle around one module,
    # without the enabled check (the caller already decided to run it). The
    # collect runs on its own fiber so the timeout can preempt an overrun; its
    # result is returned to the caller to store only on success, so a timed-out
    # fiber's late result is dropped rather than recorded.
    private def run_guarded(plan : Plan, key : String, timeout_s : Float64, &block : -> T) : T? forall T
      plan.rail.module_started(key, LABELS[key]? || key)
      result = with_timeout(timeout_s, &block)
      store_result(plan.state, result)
      plan.state.modules.outcomes.delete(ModuleResults::STORAGE_KEYS[key]? || key)
      plan.rail.module_finished(key)
      result
    rescue error
      plan.rail.module_failed(key)
      record_module_failure(plan, key, error)
      nil
    end

    private def skip(plan : Plan, key : String, message : String) : Nil
      plan.rail.module_skipped(key, LABELS[key]? || key)
      UI.line(:error, message)
      Log.write("[#{key}] Skipped: #{message}")
    end

    private def port_scan_skip_reason(info : TargetInfo) : String
      reason = info.ip_resolution_error
      reason.nil? || reason.empty? ? "Target IP address could not be resolved" : "Target IP address could not be resolved: #{reason}"
    end

    # Runs the given collect on a fresh fiber and races it against the budget. A
    # zero or negative budget runs it inline (no fiber). The result channel is
    # buffered so a timed-out fiber's send never blocks it, letting it exit.
    # ponytail: a timed-out collect's fiber keeps running to completion in the
    # background (Crystal has no fiber cancellation); its result is dropped. The
    # process is short-lived and the modules bound their own IO, so the abandoned
    # fiber is harmless. Upgrade path: a cancellation token threaded through the
    # HTTP pool, deferred.
    private def with_timeout(seconds : Float64, &block : -> T) : T forall T
      return block.call if seconds <= 0.0

      done = Channel(T).new(1)
      failed = Channel(Exception).new(1)
      spawn do
        done.send(block.call)
      rescue error
        failed.send(error)
      end

      select
      when value = done.receive
        value
      when error = failed.receive
        raise error
      when timeout(seconds.seconds)
        raise ModuleTimeout.new("module exceeded #{seconds}s")
      end
    end

    private def compute_findings(state : RunState) : Nil
      state.findings = Findings::Engine.run(state)
      print_findings(state.findings)
    rescue error
      Log.write("[findings] Exception = #{error.class}: #{error.message}")
      state.findings = [] of Finding
    end

    private def print_findings(findings : Array(Finding)) : Nil
      return if findings.empty?

      UI.module_header("Findings")
      findings.each do |finding|
        severity = finding.severity.upcase
        suffix = finding.source_module ? " (#{finding.source_module})" : ""
        UI.line(:info, "#{colorize_severity(severity)} #{finding.title}#{suffix}")
        evidence = finding.evidence
        UI.tree_rows([{"Evidence", evidence.as(String?)}]) unless evidence.nil?
      end
    end

    private def colorize_severity(severity : String) : String
      color = case severity
              when "CRITICAL", "HIGH" then UI::R
              when "MEDIUM"           then UI::Y
              else                         UI::G
              end
      "#{UI::W}⟦ #{color}#{severity}#{UI::W} ⟧"
    end

    private def export_if_enabled(state : RunState, info : TargetInfo) : String?
      return nil unless @options.export?

      paths = ExportManager.new.export(
        state, domain: info.hostname, formats: export_formats,
        custom_directory: custom_directory, custom_basename: custom_basename,
      )
      paths.empty? ? nil : File.dirname(paths.first_value)
    rescue error : ArgumentError | File::Error
      Log.write("[export] #{error.class}: #{error.message}")
      raise Error.new("Export failed : #{error.message}")
    end

    private def prepare_export(info : TargetInfo) : Nil
      return unless @options.export?

      ExportManager.new.prepare(
        domain: info.hostname, formats: export_formats,
        custom_directory: custom_directory, custom_basename: custom_basename,
      )
    rescue error : ArgumentError | File::Error
      raise Error.new("Export failed : #{error.message}")
    end

    private def print_completion(elapsed : Float64, export_dir : String?) : Nil
      UI.row(:info, "Completed in", "#{"%.2f" % elapsed}s")
      UI.row(:info, "Exported", export_dir) unless export_dir.nil?
    end

    # The export formats: the -o list, or all three when none was given (the Ruby
    # runner default, wider than the ExportManager's own txt-only fallback).
    private def export_formats : Array(String)
      raw = @options.formats.to_s.strip
      return %w[txt json html] if raw.empty?

      formats = raw.split(',').map(&.strip.downcase).reject(&.empty?)
      formats.uniq!
      formats
    end

    private def custom_directory : String?
      value = @options.export_dir.to_s.strip
      value.empty? ? nil : value
    end

    private def custom_basename : String?
      value = @options.export_basename.to_s.strip
      value.empty? ? nil : value
    end

    private def dns_servers_list(info : TargetInfo) : Array(String)
      info.dns_servers.split(',').map(&.strip).reject(&.empty?)
    end

    private def header_profile(state : RunState) : TargetIntel::Profile?
      state.modules.headers.try(&.target_profile)
    end

    private def directory_config(info : TargetInfo, state : RunState) : Modules::DirectoryEnum::Config
      Modules::DirectoryEnum::Config.new(
        wordlist: info.wordlist,
        extensions: info.extensions,
        threads: info.dir_threads,
        verify_ssl: info.verify_ssl?,
        allow_redirects: info.allow_redirects?,
        request_headers: info.request_headers,
        timeout_s: info.timeout,
        crawler: state.modules.crawler,
        headers: state.modules.headers,
        profile: header_profile(state),
      )
    end

    # Security: a query string can carry tokens, so third-party lookups
    # (Wappalyzer, archive.org) receive the URL without the query or fragment.
    private def third_party_target(target : String) : String
      uri = URI.parse(target)
      uri.query = nil
      uri.fragment = nil
      uri.to_s
    rescue
      target
    end
  end
end
