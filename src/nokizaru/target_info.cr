require "socket"
require "http/headers"
require "./cli/options"
require "./destination"
require "./settings"
require "./target_intel"
require "./psl/list"
require "./dns/resolver"
require "./request_headers"

module Nokizaru
  # The resolved target for one scan plus the runtime options every module reads,
  # derived from the parsed CLI options and the loaded settings. A pure value: the
  # runner presents the target context and the modules consume these fields. Fatal
  # input (no target, a missing protocol, credentials in the URL, a non-positive
  # number) raises `TargetInfo::Error`; an unresolvable host is not fatal (ip is
  # nil, the port scan is skipped). Not to be confused with TargetIntel, which is
  # the PSL/scope intelligence helper; this is the per-run target and options.
  struct TargetInfo
    class Error < Exception
    end

    getter target : String
    getter protocol : String
    getter hostname : String
    getter netloc : String
    getter domain : String
    getter suffix : String
    getter ip : String?
    getter? type_ip : Bool
    getter? private_ip : Bool
    getter ip_resolution_error : String?
    getter notice : String?
    getter timeout : Float64
    getter dns_servers : String
    getter ssl_port : Int32
    getter pscan_threads : Int32
    getter pscan_ports : String?
    getter dir_threads : Int32
    getter wordlist : String
    getter request_headers : ::HTTP::Headers
    getter? allow_redirects : Bool
    getter? verify_ssl : Bool
    getter extensions : String

    def initialize(
      @target, @protocol, @hostname, @netloc, @domain, @suffix, @ip, @type_ip, @private_ip,
      @ip_resolution_error, @notice, @timeout, @dns_servers, @ssl_port, @pscan_threads,
      @pscan_ports, @dir_threads, @wordlist, @request_headers, @allow_redirects, @verify_ssl, @extensions,
    )
    end

    def self.resolve(
      options : CLI::Options,
      settings : Settings = Settings.new,
      resolve_ip : Proc(String, String?) = ->(host : String) { Dns::Resolver.new.resolve(host) },
    ) : TargetInfo
      target = validated_target(options.target)
      uri = URI.parse(target)
      reject_credentials(uri)
      hostname = parse_hostname(uri)
      protocol = uri.scheme.to_s
      ip, type_ip, error = resolve_target_ip(hostname, resolve_ip)
      domain, suffix = domain_parts(hostname)

      new(
        target: target, protocol: protocol, hostname: hostname,
        netloc: netloc(uri, protocol, hostname), domain: domain, suffix: suffix,
        ip: ip, type_ip: type_ip, private_ip: private_ip?(ip), ip_resolution_error: error,
        notice: notice(uri), timeout: positive_float(options.timeout || settings.common.timeout, "T"),
        dns_servers: options.dns_servers || settings.common.dns_servers,
        ssl_port: positive_int(options.ssl_port || settings.ssl_cert.ssl_port, "sp"),
        pscan_threads: positive_int(options.port_threads || settings.port_scan.threads, "pt"),
        pscan_ports: options.ports,
        dir_threads: positive_int(options.dir_threads || settings.dir_enum.threads, "dt"),
        wordlist: wordlist_for(options),
        request_headers: request_headers_for(options),
        allow_redirects: bool_option(options.redirects, settings.dir_enum.redirect?),
        verify_ssl: !options.insecure?,
        extensions: options.extensions || settings.dir_enum.extension,
      )
    end

    private def self.validated_target(raw : String?) : String
      target = raw.to_s
      raise Error.new("No Target Specified!") if target.empty?
      unless target.starts_with?("http://") || target.starts_with?("https://")
        raise Error.new("Protocol Missing, Include http:// or https://")
      end

      target.rchop('/')
    end

    # Security: credentials in the target URL would reach the terminal, the log,
    # exports, and third-party lookups, so they are refused in favor of -H.
    private def self.reject_credentials(uri : URI) : Nil
      return if uri.user.nil? && uri.password.nil?

      raise Error.new("Credentials in the target URL are not supported, pass them with -H 'Authorization: ...'")
    end

    private def self.parse_hostname(uri : URI) : String
      host = uri.host.to_s
      raise Error.new("Unable to parse hostname from target") if host.empty?

      host
    end

    private def self.resolve_target_ip(hostname : String, resolve_ip : Proc(String, String?)) : Tuple(String?, Bool, String?)
      return {hostname, true, nil} if TargetIntel.ip_address?(hostname)

      ip = resolve_ip.call(hostname)
      ip ? {ip, false, nil} : {nil, false, "could not resolve #{hostname}"}
    end

    private def self.netloc(uri : URI, protocol : String, hostname : String) : String
      port = uri.port
      default = protocol == "https" ? 443 : 80
      port && port != default ? "#{hostname}:#{port}" : hostname
    end

    private def self.notice(uri : URI) : String?
      port = uri.port
      return nil if port.nil?

      scheme = uri.scheme.to_s
      unusual = (scheme == "http" && port == 443) || (scheme == "https" && port == 80)
      unusual ? "Using #{scheme} with port #{port}" : nil
    end

    # The Ruby sld/tld split: the label before the public suffix and the suffix.
    private def self.domain_parts(hostname : String) : Tuple(String, String)
      return {"", ""} if TargetIntel.ip_address?(hostname)

      psl = PSL::List.default
      suffix = psl.public_suffix(hostname)
      registrable = psl.registrable_domain(hostname)
      if suffix && registrable && registrable.ends_with?(".#{suffix}")
        return {registrable[0, registrable.size - suffix.size - 1], suffix}
      end

      fallback_domain_parts(hostname)
    end

    private def self.fallback_domain_parts(hostname : String) : Tuple(String, String)
      labels = hostname.downcase.split('.').reject(&.empty?)
      return {hostname, ""} if labels.size < 2

      {labels[0..-2].join("."), labels[-1]}
    end

    # Loopback, private, link-local, or unspecified: the target the operator
    # chose is itself internal, which also decides whether a scan may follow
    # server data to an internal address (see Destination).
    private def self.private_ip?(ip : String?) : Bool
      return false if ip.nil? || ip.empty?

      Destination.internal_address?(ip)
    end

    # The -w value: a curated size name stays a size name, and any other value is
    # a custom path, which must exist and be readable before a scan starts.
    # Validating here keeps every operator input refused at one boundary.
    private def self.wordlist_for(options : CLI::Options) : String
      chosen = options.wordlist
      return Settings::DEFAULT_WORDLIST if chosen.nil?

      resolved = Settings.wordlist(chosen)
      return resolved if Settings::WORDLISTS.has_key?(resolved)
      raise Error.new("Wordlist not found: #{resolved}") unless File.file?(resolved)

      resolved
    end

    private def self.request_headers_for(options : CLI::Options) : ::HTTP::Headers
      RequestHeaders.parse(options.request_headers)
    rescue error : ArgumentError
      raise Error.new(error.message)
    end

    private def self.bool_option(value : Bool?, default : Bool) : Bool
      value.nil? ? default : value
    end

    private def self.positive_float(value : Float64, label : String) : Float64
      raise Error.new("-#{label} must be a positive number") unless value > 0

      value
    end

    private def self.positive_int(value : Int32, label : String) : Int32
      raise Error.new("-#{label} must be a positive number") unless value > 0

      value
    end
  end
end
