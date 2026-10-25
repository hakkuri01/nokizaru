require "../run_state"

module Nokizaru::CLI
  class Workflow
    private def store_result(state : RunState, result : Modules::Headers::Result) : Nil
      state.modules.headers = result
    end

    private def store_result(state : RunState, result : Modules::SSLInfo::Result) : Nil
      state.modules.sslinfo = result
    end

    private def store_result(state : RunState, result : Modules::WhoisLookup::Result) : Nil
      state.modules.whois = result
    end

    private def store_result(state : RunState, result : Modules::DnsEnumeration::Result) : Nil
      state.modules.dns = result
      state.add_artifact("dns_txt", result.records["TXT"]? || [] of String) unless result.error
    end

    private def store_result(state : RunState, result : Modules::Subdomains::Result) : Nil
      state.modules.subdomains = result
      state.add_artifact("subdomains", result.subdomains)
    end

    private def store_result(state : RunState, result : Modules::Arch::Result) : Nil
      state.modules.arch = result
      state.add_artifact("technologies", result.technologies.map(&.name)) if result.status == "ok"
    end

    private def store_result(state : RunState, result : Modules::PortScan::Result) : Nil
      state.modules.portscan = result
      state.add_artifact("open_ports", result.artifact_ports)
    end

    private def store_result(state : RunState, result : Modules::Crawler::Result) : Nil
      state.modules.crawler = result
      if urls = result.stats.total_urls
        state.add_artifact("urls", urls)
      end
      if urls = result.high_signal_urls
        add_nonempty_artifact(state, "high_signal_urls", urls)
      end
    end

    private def store_result(state : RunState, result : Modules::DirectoryEnum::Result) : Nil
      state.modules.directory_enum = result
      state.add_artifact("paths", result.prioritized_found)
      add_nonempty_artifact(state, "prioritized_paths", result.prioritized_found)
      add_nonempty_artifact(state, "high_signal_paths", result.high_signal_found)
    end

    private def store_result(state : RunState, result : Modules::Wayback::Result) : Nil
      state.modules.wayback = result
      add_nonempty_artifact(state, "urls", result.urls)
      add_nonempty_artifact(state, "wayback_urls", result.urls)
      add_nonempty_artifact(state, "wayback_high_signal_urls", result.high_signal_urls)
      snapshots = result.historical_snapshots.map(&.snapshot_url)
      result.changed_snapshots.each { |snapshot| snapshots << snapshot.snapshot_url }
      add_nonempty_artifact(state, "wayback_snapshot_urls", snapshots)
      add_nonempty_artifact(state, "wayback_javascript_urls", result.javascript_urls)
      add_nonempty_artifact(state, "wayback_api_urls", result.api_urls)
      add_nonempty_artifact(state, "wayback_interesting_path_urls", result.interesting_path_urls)
      add_nonempty_artifact(state, "wayback_interesting_parameter_urls", result.interesting_parameter_urls)
      add_nonempty_artifact(state, "wayback_sensitive_file_urls", result.sensitive_file_urls)
      add_nonempty_artifact(state, "wayback_review_urls", result.review_urls)
    end

    private def add_nonempty_artifact(state : RunState, key : String, values : Array(String)) : Nil
      state.add_artifact(key, values) unless values.empty?
    end
  end
end
