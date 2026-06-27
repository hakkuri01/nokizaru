<p align="center">
  <img src="assets/nokizaru.png" alt="Nokizaru" width="100%">
</p>

<p align="center">
<img src="https://img.shields.io/badge/Ruby-black.svg?style=plastic&logo=ruby&logoColor=red">
<img src="https://img.shields.io/badge/v2.3.11-black.svg?style=plastic&logo=git&logoColor=red">
<img src="https://img.shields.io/badge/Bug%20Bounty-black.svg?style=plastic&logo=owasp&logoColor=red">
</p>

Nokizaru is a CLI tool purpose-built for enumerating the core web recon surface. Its goal is to provide a sufficiently expansive, high-signal overview of a target quickly, subverting the need to reach for heavier OSINT suites. Instead of running several tools in sequence, Nokizaru aims to produce comparable recon results with a single full-scan command. The ideal use case is collecting relevant information on a web target during the recon phase of a bug bounty/web app pentest engagement. As such, the primary audience is security researchers (not CTI analysts who may still prefer larger, more comprehensive OSINT suites).

> [!IMPORTANT]
> 
> *Nokizaru is intended for authorized security testing and research. Always ensure you have explicit permission to scan targets you do not own.*

---

## Architecture

Nokizaru runs a full web recon pass with shared target context, bounded module budgets, and graceful degradation when targets are slow, hostile, or heavily canonicalized.

### Context-Aware Scanning Pipeline

- **Headers -> Target Profile:** response headers shape later scan behavior, including redirect and canonical host hints
- **Custom Headers:** repeatable `-H/--header` values are reused across in-scope web requests without printing secrets back to stdout
- **Re-Anchoring:** crawler and directory scans can automatically move to the effective in-scope URL, such as HTTP -> HTTPS or canonical same-scope hosts
- **Crawler -> Dir Enum:** crawler discoveries seed directory checks so high-signal paths are tested before lower-value wordlist noise
- **Dir Enum Noise Control:** WAF/soft-404-heavy responses are kept inspectable in exports, but stdout favors actionable paths over bulk false positives
- **Port Scan Context:** port checks are native TCP probes with lightweight service/category/TLS/HTTP/exposure hints
- **Wayback Fallbacks:** archive lookups use bounded source aggregation and expose manual pivots when upstream archive APIs are degraded

---

## Installation

### Linux / macOS (Homebrew)

Homebrew is the primary install method for Linux/macOS:

```bash
brew tap hakkuri01/nokizaru https://github.com/hakkuri01/nokizaru
brew install nokizaru
nokizaru --help
man nokizaru
```

For updates:

```bash
brew update
brew upgrade nokizaru
```

Nokizaru Homebrew releases are pinned to stable git tags. `brew upgrade nokizaru` will update your install whenever a newer stable formula version is published.

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

---

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
| VirusTotal | Sub Domain Enum / Wayback URLs | [https://www.virustotal.com/gui/my-apikey](https://www.virustotal.com/gui/my-apikey)                                      |
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
    "verify_ssl": false,
    "extension": ""
  },
  "export": {
    "format": "txt"
  }
}
```

---

## Usage

```bash
Nokizaru - Recon Refined

Arguments:
  -h, --help       Show this help message and exit
  -v, --version    Show version number and exit
  --target TARGET  Target (http[s]://host[:port])
  --headers        Header Information
  --sslinfo        SSL Certificate Information
  --whois          Whois Lookup
  --crawl          Crawl Target
  --dns            DNS Enumeration
  --sub            Sub-Domain Enumeration
  --arch           Architecture Fingerprinting
  --dir            Directory Search
  --wayback        Wayback URLs
  --ps             Fast Port Scan
  --full           Full Recon
  --no-[MODULE]    Skip specified modules above during full scan (eg. --no-dir)
  --export         Write results to export directory

Workspaces:
  --project [NAME]    Enable a persistent workspace (profiles, caching, diffing)
  --cache             Enable caching even without a project
  --no-cache          Disable caching (even in a project)
  --diff last / [ID]  Diff this run against the last (or another run ID in the workspace)

Extra Options:
  -nb         Hide Banner
  -dt DT      Number of threads for directory enum [ Default : 30 ]
  -pt PT      Number of threads for port scan [ Default : 50 ]
  -p PORTS    Port scan ports [ Example : 80,443,1000-65535 ]
  -T T        Request Timeout [ Default : 30.0 ]
  -w W        Path to Wordlist [ Default : wordlists/raft_med-dir_5k.txt ]
  -H HEADER   Add custom request header (repeatable)
  -r          Follow redirects during directory enum [ Default : False ]
  -s          Enable SSL verification for directory enum [ Default : False ]
  -sp SP      Specify SSL Port [ Default : 443 ]
  -d D        Custom DNS Servers [ Default : 1.1.1.1 ]
  -e E        File Extension(s) (comma separated) [ Example : txt,xml,php,etc. ]
  -o O        Export Format(s) (comma-separated) [ Default : txt,json,html ]
  -cd CD      Export directory for this run (requires --export) [ Default : ~/.local/share/nokizaru/dumps/nk_<domain> ]
  -of OF      Export filename base for this run (requires --export) [ Default : YYYY-MM-DD_HH-MM-SS ]
  -k K        Add API key [ Example : shodan@key ]
```

### Examples

```bash
# Full scan
nokizaru --full --target https://example.com

# Check headers
nokizaru --headers --target https://example.com

# Crawl target
nokizaru --crawl --target https://example.com

# Directory enumeration
nokizaru --dir --target https://example.com -e txt,php -w /path/to/wordlist

# Port scan a custom port set
nokizaru --ps --target https://example.com -p 80,443,8000-8010

# Port scan all TCP ports
nokizaru --ps --target https://example.com -p all

# Authenticated crawl + dir enum with a session cookie
nokizaru --crawl --dir --target https://example.com \
  -H 'Cookie: PHPSESSID=abc123; uid=52' \
  -H 'X-Role: admin'
```

Custom headers are applied only to in-scope target requests. Nokizaru does not echo supplied header values back in module banners.

---

## Output / Exports

Nokizaru is **ephemeral by default** (stdout). If you specify `--export`, it will write **TXT**, **JSON**, and **HTML** reports (unless you narrow formats with `-o`).

By default, exports are written to:

```bash
~/.local/share/nokizaru/dumps/nk_<domain>/
├── YYYY-MM-DD_HH-MM-SS.txt
├── YYYY-MM-DD_HH-MM-SS.json
└── YYYY-MM-DD_HH-MM-SS.html
```

Each target gets its own directory, and each run is timestamped for easy organization and sorting. You can override the directory with `-cd` or the basename with `-of`.

---

## Workspaces / Caching / Diffing

If you specify `--project <name>`, Nokizaru can create a persistent workspace for a target using the Ronin Framework:

- stores run metadata and results internally (so you can build a target profile over time) 
- enables caching (speeding up repeated runs)
- enables diffing between runs: `--diff last` (or `--diff <Run ID>`)
