require "../version"

module Nokizaru::CLI
  # The hand-rendered --help and --version output, matching the Ruby tool's text
  # (the version number differs: this is the 1.0.0 Crystal rewrite).
  module Help
    extend self

    USAGE = "usage: nokizaru [-h] [-v] [--target TARGET] [--headers] [--sslinfo] [--whois] [--crawl] [--dns] [--sub] [--arch] [--dir] [--wayback] [--ps]\n                [--full] [--no-MODULE] [--export] [--tui] [-nb] [-dt DT] [-pt PT] [-p PORTS] [-T T] [-w W] [-H HEADER] [-r] [--insecure] [-sp SP] [-d D] [-e E] [-o O] [-cd CD] [-of OF] [-k K]"

    ARGUMENT_ROWS = [
      {"-h, --help", "Show this help message and exit"}, {"-v, --version", "Show version number and exit"},
      {"--target TARGET", "Target (http[s]://host[:port])"}, {"--headers", "Header Information"},
      {"--sslinfo", "SSL Certificate Information"}, {"--whois", "Whois Lookup"}, {"--crawl", "Crawl Target"},
      {"--dns", "DNS Enumeration"}, {"--sub", "Sub-Domain Enumeration"}, {"--arch", "Architecture Fingerprinting"},
      {"--dir", "Directory Search"}, {"--wayback", "Wayback Snapshots"},
      {"--ps", "Fast Port Scan"}, {"--full", "Full Recon"},
      {"--no-[MODULE]", "Skip specified modules above during full scan (eg. --no-dir)"},
      {"--export", "Write results to export directory [ Default : False ]"},
      {"--tui", "Force the command form instead of the running dashboard"},
    ]

    EXTRA_ROWS = [
      {"-nb", "Hide Banner"}, {"-dt DT", "Number of threads for directory enum [ Default : 50 ]"},
      {"-pt PT", "Port scan concurrency [ Default : 50 ]"},
      {"-p PORTS", "Port scan ports [ Example : 80,443,1000-65535 ]"},
      {"-T T", "Base timeout / module budget [ Default : 30.0 ]"},
      {"-w W", "Wordlist size (small, medium, large) or custom path [ Default : medium ]"},
      {"-H, --header HEADER", "Add custom request header (repeatable)"},
      {"-r", "Follow redirects during directory enum [ Default : False ]"},
      {"--insecure", "Skip TLS certificate verification for the target [ Default : False ]"},
      {"-sp SP", "Specify SSL Port [ Default : 443 ]"},
      {"-d D", "Custom DNS Servers [ Default : 8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1 ]"},
      {"-e E", "File Extensions [ Example : txt, xml, php, etc. ]"},
      {"-o O", "Export Formats (comma-separated) [ Default : txt,json,html ]"},
      {"-cd CD", "Export directory for this run (requires --export) [ Default : XDG data dir/nokizaru/exports/<hostname> ]"},
      {"-of OF", "Export filename base for this run (requires --export) [ Default : YYYY-MM-DD_HH-MM-SS ]"},
      {"-k K", "Add API key, prompted without echo [ Example : shodan ]"},
    ]

    def version : String
      "nokizaru #{Nokizaru::VERSION}"
    end

    def render(io : IO = STDOUT) : Nil
      io.puts(USAGE)
      io.puts
      io.puts("Nokizaru - Recon Refined | v#{Nokizaru::VERSION}")
      io.puts
      io.puts("Arguments:")
      print_rows(io, ARGUMENT_ROWS)
      io.puts
      io.puts("Extra Options:")
      print_rows(io, EXTRA_ROWS)
      io.puts
    end

    private def print_rows(io : IO, rows : Array(Tuple(String, String))) : Nil
      left_width = {rows.max_of(&.[0].size), 18}.max
      rows.each { |left, right| io.puts("  %-#{left_width}s %s" % {left, right}) }
    end
  end
end
