require "../module_outcome"
require "../secrets"

module Nokizaru::CLI
  class Workflow
    private def record_module_failure(plan : Plan, key : String, error : Exception) : Nil
      detail = error.is_a?(File::Error) ? "Module failed; check local file access" : error.message.to_s
      message = "#{error.class}: #{safe_failure_text(detail, plan.info)}"
      outcome = ModuleOutcome.new("failed", message, timed_out: error.is_a?(ModuleTimeout), module_name: key, label: LABELS[key]? || key)
      plan.state.modules.outcomes[ModuleResults::STORAGE_KEYS[key]? || key] = outcome
      Log.write("[#{key}] Module failed = #{message}")
    end

    private def skip_portscan_without_ip(plan : Plan) : Nil
      message = safe_failure_text(port_scan_skip_reason(plan.info), plan.info)
      plan.state.modules.outcomes["portscan"] = ModuleOutcome.new("skipped", message, open_ports: [] of String, ports: [] of String)
      skip(plan, "ps", "Skipping Port Scan : #{message}")
    end

    private def safe_failure_text(message : String, info : TargetInfo) : String
      # ponytail: errors are capped at 1024 bytes, so checks are O(credential bytes); use a multi-pattern scanner if the cap grows
      text = message.bytesize > 1024 ? "Module failed; error detail exceeded safety limit" : message
      safe = TerminalText.plain(text)
      secrets = Secrets.from_key_store.concat(Secrets.from_headers(info.request_headers))
      if Secrets.includes_any?(text, secrets) || Secrets.includes_any?(safe, secrets)
        return "Module failed; credential-bearing error detail withheld"
      end
      safe
    end
  end
end
