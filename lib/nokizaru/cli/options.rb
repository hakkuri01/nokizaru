# frozen_string_literal: true

module Nokizaru
  # Thor option definitions for scan command
  module CLIOptions
    OPTION_DEFS = {
      url: { type: :string, desc: 'Target URL' },
      headers: { type: :boolean, default: false, desc: 'Header Information' },
      sslinfo: { type: :boolean, default: false, desc: 'SSL Certificate Information' },
      whois: { type: :boolean, default: false, desc: 'Whois Lookup' },
      crawl: { type: :boolean, default: false, desc: 'Crawl Target' },
      dns: { type: :boolean, default: false, desc: 'DNS Enumeration' },
      sub: { type: :boolean, default: false, desc: 'Sub-Domain Enumeration' },
      arch: { type: :boolean, default: false, desc: 'Architecture Fingerprinting' },
      dir: { type: :boolean, default: false, desc: 'Directory Search' },
      wayback: { type: :boolean, default: false, desc: 'Wayback URLs' },
      wb_raw: { type: :boolean, default: false, desc: 'Wayback raw URL output (no quality filtering)' },
      ps: { type: :boolean, default: false, desc: 'Fast Port Scan' },
      full: { type: :boolean, default: false, desc: 'Full Recon' },
      export: { type: :boolean, default: false, desc: 'Export results to files (txt,json,html)' },
      project: { type: :string, default: nil, desc: 'Enable a persistent workspace (profiles, caching, diffing)' },
      cache: { type: :boolean, default: nil, desc: 'Enable caching even without a project' },
      no_cache: { type: :boolean, default: false, desc: 'Disable caching (even in a project)' },
      diff: { type: :string, default: nil, desc: 'Diff this run against another run id in the workspace (or "last")' },
      nb: { type: :boolean, default: false, desc: 'Hide Banner' },
      dt: { type: :numeric, default: nil, desc: 'Number of threads for directory enum [ Default : 30 ]' },
      pt: { type: :numeric, default: nil, desc: 'Number of threads for port scan [ Default : 50 ]' },
      T: { type: :numeric, default: nil, aliases: '-T', desc: 'Request Timeout [ Default : 30.0 ]' },
      w: { type: :string, default: nil, aliases: '-w',
           desc: 'Path to Wordlist [ Default : wordlists/dirb_common.txt ]' },
      r: { type: :boolean, default: nil, aliases: '-r', desc: 'Allow Redirect [ Default : False ]' },
      s: { type: :boolean, default: nil, aliases: '-s', desc: 'Toggle SSL Verification [ Default : True ]' },
      sp: { type: :numeric, default: nil, desc: 'Specify SSL Port [ Default : 443 ]' },
      d: { type: :string, default: nil, aliases: '-d', desc: 'Custom DNS Servers [ Default : 1.1.1.1 ]' },
      e: { type: :string, default: nil, aliases: '-e', desc: 'File Extensions [ Example : txt, xml, php ]' },
      o: { type: :string, default: nil, aliases: '-o',
           desc: 'Export Formats (comma-separated) [ Default : txt,json,html ]' },
      cd: { type: :string, default: nil,
            desc: 'Change export directory [ Default : ~/.local/share/nokizaru/dumps/nk_<domain> ]' },
      of: { type: :string, default: nil, desc: 'Change export folder name [ Default : YYYY-MM-DD_HH-MM-SS ]' },
      k: { type: :string, default: nil, aliases: '-k', desc: 'Add API key [ Example : shodan@key ]' }
    }.freeze

    def apply_scan_options(klass)
      OPTION_DEFS.each { |name, options| klass.option(name, **options) }
    end
  end
end
