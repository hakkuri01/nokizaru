<p align="center">
<img src="https://i.imgur.com/OLPIy8N.png">
</p>

<p align="center">
<img src="https://img.shields.io/badge/Ruby-black.svg?style=plastic&logo=ruby&logoColor=red">
<img src="https://img.shields.io/badge/v1.5.2-black.svg?style=plastic&logo=git&logoColor=red">
<img src="https://img.shields.io/badge/Bug%20Bounty-black.svg?style=plastic&logo=owasp&logoColor=red">
</p>

Nokizaru is a CLI tool purpose-built for enumerating the core web recon surface. Its goal is to provide a sufficiently expansive, high-signal overview of a target quickly, subverting the need to reach for heavier OSINT suites. Instead of running several tools in sequence, Nokizaru aims to produce comparable recon results with a single full-scan command. The ideal use case is collecting relevant information on a web target during the recon phase of a bug bounty/web app pentest engagement. As such, the primary audience is security researchers (not CTI analysts who may still prefer larger, more comprehensive OSINT suites).

## Inspiration & Background

Nokizaru started as a Ruby reimplementation of [FinalRecon](https://github.com/thewhiteh4t/FinalRecon) by [thewhiteh4t](https://github.com/thewhiteh4t). The original goal was straightforward: keep the familiar reconnaissance workflow while rebuilding it with Ruby-first design choices.

Over time, the project expanded beyond a direct rewrite. Nokizaru now includes structured findings output, broader provider coverage (with additional integrations planned), Ronin-powered workspaces for persistent target profiling, and targeted performance improvements oriented around stable runtime behavior.

## Architecture

FinalRecon’s Python implementation achieves speed through an async-first approach (concurrent HTTP calls, fast fan-out, and clear module boundaries). Nokizaru keeps the same high-level modules and “single command” workflow, but adapts the implementation to Ruby idioms and performance constraints:

- **Concurrency model:** Nokizaru favors bounded concurrency (worker pools / thread queues) with strict per-task timeouts. This prevents a single flaky provider or endpoint from stalling the entire scan.
- **Reusable networking:** A shared HTTP client (keep-alive / connection reuse) is used where possible to reduce handshake overhead across modules.
- **Error UX:** Provider failures are reported cleanly and consistently, but Nokizaru also aims to make errors more actionable and less noisy.
- **Performance consistency:** Timeouts and budgets are designed to produce consistent runtimes between executions, rather than “sometimes fast, sometimes stuck.”

## Configuration

### API Keys

Some modules use API keys to fetch data from different resources. These are optional—if you do not provide an API key, the module will be skipped.

#### Environment Variables

Keys are read from environment variables if they are set; otherwise they are loaded from the user data directory (`~/.local/share/nokizaru/keys.json`).

```bash
NK_BEVIGIL_KEY, NK_BINEDGE_KEY, NK_CENSYS_API_ID, NK_CENSYS_API_SECRET,
NK_CHAOS_KEY, NK_FB_KEY, NK_HUNTER_KEY, NK_NETLAS_KEY,
NK_SHODAN_KEY, NK_VT_KEY, NK_WAPPALYZER_KEY, NK_ZOOMEYE_KEY

# Example :
export NK_SHODAN_KEY="kl32lcdqwcdfv"
```

#### Saved Keys

You can use **`-k`** to add keys which will be saved automatically in the config directory.

```bash
# Usage
nokizaru -k '<API NAME>@<API KEY>'

Valid Keys : 'bevigil', 'binedge', 'censys_api_id', 'censys_api_secret', 'chaos', 'facebook', 'hunter', 'netlas', 'shodan', 'virustotal', 'wappalyzer', 'zoomeye'

# Example :
nokizaru -k 'shodan@kl32lcdqwcdfv'
```

`Path = $HOME/.local/share/nokizaru/keys.json`

| Source     | Module          | Link                                                                                                                                   |
| ---------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Facebook   | Sub Domain Enum | [https://developers.facebook.com/docs/facebook-login/access-tokens](https://developers.facebook.com/docs/facebook-login/access-tokens) |
| VirusTotal | Sub Domain Enum | [https://www.virustotal.com/gui/my-apikey](https://www.virustotal.com/gui/my-apikey)                                                   |
| Shodan     | Sub Domain Enum | [https://developer.shodan.io/api/requirements](https://developer.shodan.io/api/requirements)                                           |
| BeVigil    | Sub Domain Enum | [https://bevigil.com/osint-api](https://bevigil.com/osint-api)                                                                         |
| BinaryEdge | Sub Domain Enum | [https://app.binaryedge.io/](https://app.binaryedge.io/)                                                                               |
| Netlas     | Sub Domain Enum | [https://docs.netlas.io/getting_started/](https://docs.netlas.io/getting_started/)                                                     |
| ZoomEye    | Sub Domain Enum | [https://www.zoomeye.hk/](https://www.zoomeye.hk/)                                                                                     |
| Hunter     | Sub Domain Enum | [https://hunter.how/search-api](https://hunter.how/search-api)                                                                         |
| Chaos      | Sub Domain Enum | [https://docs.projectdiscovery.io/tools/chaos](https://docs.projectdiscovery.io/tools/chaos)                                           |
| Censys     | Sub Domain Enum | [https://search.censys.io/api](https://search.censys.io/api)                                                                           |
| Wappalyzer | Architecture Fingerprinting | [https://www.wappalyzer.com/api/](https://www.wappalyzer.com/api/)                                                         |

### JSON Config File

Default config file is available at `~/.config/nokizaru/config.json`

```json
{
  "common": {
    "timeout": 30,
    "dns_servers": "8.8.8.8, 8.8.4.4, 1.1.1.1, 1.0.0.1"
  },
  "ssl_cert": {
    "ssl_port": 443
  },
  "port_scan": {
    "threads": 50
  },
  "dir_enum": {
    "threads": 50,
    "redirect": false,
    "verify_ssl": true,
    "extension": ""
  },
  "export": {
    "format": "txt"
  }
}
```

## Installation

### Linux / macOS (Homebrew)

* Homebrew is planned as the primary install method for future releases, as it can be used on both Linux or macOS comfortably, and will be pulled down as such:

```bash
brew install hakkuri01/tap/nokizaru
nokizaru --help
```
* However, before implementing this install method officially, I would like to know if people would prefer a single executable, bundled runtime folder, or simply making use of `depends_on "ruby"` to let the tap rely on Homebrew Ruby.

### Build From Source (Git Clone)

```bash
git clone https://github.com/hakkuri01/nokizaru.git
cd nokizaru
gem build nokizaru.gemspec
gem install nokizaru-*.gem
nokizaru --help
```

### Tarball

```bash
curl -L -o nokizaru.tar.gz https://github.com/hakkuri01/nokizaru/archive/refs/heads/main.tar.gz
tar -xzf nokizaru.tar.gz
cd nokizaru
gem build nokizaru.gemspec
gem install nokizaru-*.gem
nokizaru --help
```

## Usage

```bash
Nokizaru - Recon Refined

Arguments:
  -h, --help       Show this help message and exit
  -v, --version    Show version number and exit
  --url URL        Target URL
  --headers        Header Information
  --sslinfo        SSL Certificate Information
  --whois          Whois Lookup
  --crawl          Crawl Target
  --dns            DNS Enumeration
  --sub            Sub-Domain Enumeration
  --arch           Architecture Fingerprinting
  --dir            Directory Search
  --wayback        Wayback URLs
  --wb-raw         Wayback raw URL output (no quality filtering)
  --ps             Fast Port Scan
  --full           Full Recon
  --no-[MODULE]    Skip specified modules above during full scan (eg. --no-dir)
  --export         Write results to export directory

Persistence / Enrichment:
  --project [NAME]    Enable a persistent workspace (profiles, caching, diffing)
  --cache             Enable caching even without a project
  --no-cache          Disable caching (even in a project)
  --diff last / [ID]  Diff this run against the last (or another run ID in the workspace)

Extra Options:
  -nb         Hide Banner
  -dt DT      Number of threads for directory enum [ Default : 30 ]
  -pt PT      Number of threads for port scan [ Default : 50 ]
  -T T        Request Timeout [ Default : 30.0 ]
  -w W        Path to Wordlist [ Default : wordlists/dirb_common.txt ]
  -r          Allow Redirect [ Default : False ]
  -s          Toggle SSL Verification [ Default : True ]
  -sp SP      Specify SSL Port [ Default : 443 ]
  -d D        Custom DNS Servers [ Default : 1.1.1.1 ]
  -e E        File Extension(s) (comma separated) [ Example : txt,xml,php,etc. ]
  -o O        Export Format(s) (comma-separated) [ Default : txt,json,html ]
  -cd CD      Change export directory [ Default : ~/.local/share/nokizaru/dumps/nk_<domain> ]
  -of OF      Change export folder name [ Default : YYYY-MM-DD_HH-MM-SS ]
  -k K        Add API key [ Example : shodan@key ]
```

### Examples

```bash
# Full scan
nokizaru --full --url https://example.com

# Check headers
nokizaru --headers --url https://example.com

# Crawl target
nokizaru --crawl --url https://example.com

# Directory enumeration
nokizaru --dir --url https://example.com -e txt,php -w /path/to/wordlist
```

## Output / Exports

Nokizaru is **ephemeral by default** (stdout). If you specify `--export`, it will write **TXT**, **JSON**, and **HTML** reports (unless you narrow formats with `-o`).

By default, exports are written to:

```bash
~/.local/share/nokizaru/dumps/nk_<domain>/
├── YYYY-MM-DD_HH-MM-SS.txt
├── YYYY-MM-DD_HH-MM-SS.json
└── YYYY-MM-DD_HH-MM-SS.html
```

Each target gets its own directory, and each run is timestamped for easy organization and sorting. You can override the directory with `-cd` or the basename with `-of.`

## Workspaces / Caching / Diffing

If you specify `--project <name>`, Nokizaru can create a persistent workspace for a target using the Ronin Framework:

- stores run metadata and results internally (so you can build a target profile over time) 
- enables caching (speeding up repeated runs)
- enables diffing between runs: `--diff last` (or `--diff <Run ID>`)

## Roadmap

### Distribution / Installation

**Homebrew Formula:** Finalize the Homebrew tap installation method for seamless deployment on Linux and macOS. This will involve deciding between a single executable, bundled runtime folder, or leveraging Homebrew's Ruby dependency management, based on user feedback.

Currently there are no other install methods planned officially, however depending on popularity I would consider various Linux distro package managers down the road. If this materializes, I would most likely start with Debian's apt for Security distros (ParrotOS, Kali etc.) followed by Fedora's RPM because I personally use Fedora.

### Provider Expansion

The following providers are planned for integration to enhance recon coverage and signal quality:

- **GreyNoise:** Internet noise classification to filter out mass-scanning activity and focus on targeted reconnaissance

All providers will follow Nokizaru's existing integration pattern: optional API keys, graceful degradation on failure, and consistent error reporting. These additions prioritize breadth of coverage and actionable intelligence to support the bug bounty/pentest recon workflow.

### Integrate Man Pages

Currently Man Pages are prepared/included and can be called with `man man/nokizaru.1`, but they are not integrated to run natively yet. This will serve as the in-depth CLI documentation for end users long-term once they are integrated.

## Responsible Use / Disclaimers

* **Nokizaru is intended for authorized security testing and research. Always ensure you have explicit permission to scan targets you do not own.**
* Nokizaru is licensed under the MIT License. If you reuse Nokizaru or redistribute derived work, ensure you preserve applicable license notices.
