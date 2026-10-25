require "option_parser"
require "./argv"

module Nokizaru::CLI
  # The parsed command line. Mirrors the Ruby option set flag-for-flag; module
  # selection (which modules a scan runs) is computed here from the module flags,
  # --full, and the --no-<module> skips.
  class Options
    MODULE_ORDER = %w[headers sslinfo whois dns sub arch ps crawl dir wayback]
    SKIPPABLE    = %w[headers sslinfo whois crawl dns sub arch dir wayback ps]

    property target : String?
    getter modules : Set(String) = Set(String).new
    getter skips : Set(String) = Set(String).new
    property? full : Bool = false
    property? export : Bool = false
    property? nb : Bool = false
    property? tui : Bool = false
    property dir_threads : Int32?
    property port_threads : Int32?
    property ssl_port : Int32?
    property ports : String?
    property timeout : Float64?
    property wordlist : String?
    getter request_headers : Array(String) = [] of String
    property redirects : Bool?
    property verify_ssl : Bool?
    property dns_servers : String?
    property extensions : String?
    property formats : String?
    property export_dir : String?
    property export_basename : String?
    property key : String?

    def initialize
    end

    def self.parse(argv : Array(String)) : Options
      opts = Options.new
      parser = OptionParser.new do |o|
        o.on("--target TARGET", "Target") { |v| opts.target = v }
        SKIPPABLE.each do |mod|
          o.on("--#{mod}", "Enable #{mod}") { opts.modules << mod }
          o.on("--no-#{mod}", "Skip #{mod}") { opts.skips << mod }
        end
        o.on("--full", "Full recon") { opts.full = true }
        o.on("--export", "Export results") { opts.export = true }
        o.on("--tui", "Interactive dashboard") { opts.tui = true }
        o.on("--nb", "Hide banner") { opts.nb = true }
        o.on("--dt THREADS", "Directory enum threads") { |v| opts.dir_threads = integer(v, "dt") }
        o.on("--pt THREADS", "Port scan concurrency") { |v| opts.port_threads = integer(v, "pt") }
        o.on("--sp PORT", "SSL port") { |v| opts.ssl_port = integer(v, "sp") }
        o.on("-p PORTS", "Port scan ports") { |v| opts.ports = v }
        o.on("-T TIMEOUT", "Base timeout") { |v| opts.timeout = timeout(v) }
        o.on("-w WORDLIST", "Wordlist size or path") { |v| opts.wordlist = v }
        o.on("-H HEADER", "--header HEADER", "Custom request header") { |v| opts.request_headers << v }
        o.on("-r", "Follow redirects") { opts.redirects = true }
        o.on("-s", "Verify SSL") { opts.verify_ssl = true }
        o.on("-d DNS", "Custom DNS servers") { |v| opts.dns_servers = v }
        o.on("-e EXT", "File extensions") { |v| opts.extensions = v }
        o.on("-o FORMATS", "Export formats") { |v| opts.formats = v }
        o.on("--cd DIR", "Export directory") { |v| opts.export_dir = v }
        o.on("--of NAME", "Export basename") { |v| opts.export_basename = v }
        o.on("-k KEY", "Save an API key") { |v| opts.key = v }
      end
      parser.parse(Argv.normalize(argv))
      opts
    end

    private def self.integer(value : String, label : String) : Int32
      value.to_i? || raise OptionParser::InvalidOption.new("-#{label} must be a 32-bit integer")
    end

    private def self.timeout(value : String) : Float64
      number = value.to_f
      raise ArgumentError.new unless number.finite?
      # Workflow's largest module budget is six times the base timeout
      (number * 6.0).seconds
      number
    rescue ArgumentError | OverflowError
      raise OptionParser::InvalidOption.new("-T must be a finite timeout within the runtime range")
    end

    # The modules this invocation runs, in execution order: a module is on when
    # --full or its own flag is set, and off when its --no-<module> skip is set.
    def enabled_modules : Array(String)
      MODULE_ORDER.select do |mod|
        (full? || modules.includes?(mod)) && !skips.includes?(mod)
      end
    end
  end
end
