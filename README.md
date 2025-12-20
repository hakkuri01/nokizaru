<p align="center">
<img src="https://img.shields.io/badge/Ruby-3-red.svg?style=plastic">
<img src="https://img.shields.io/badge/All%20In%20One-red.svg?style=plastic">
<img src="https://img.shields.io/badge/Web%20Recon-red.svg?style=plastic">
</p>

# Nokizaru

Nokizaru is an all-in-one web recon CLI tool written in Ruby. Its goal is to provide a sufficiently expansive, high-signal overview of a target quickly, subverting the need to reach for heavier OSINT suites. Instead of running several tools in sequence, Nokizaru aims to produce comparable recon results with a single full-scan command. The ideal use case is collecting relevant information on a web target during the recon phase of a bug bounty/web app pentest engagement. As such, the primary audience is security researchers (not CTI analysts who may still prefer larger, more comprehensive OSINT suites).

## Inspiration & Background

Nokizaru began as an experiment: taking a beloved tool—[FinalRecon](https://github.com/thewhiteh4t/FinalRecon) by [thewhiteh4t](https://github.com/thewhiteh4t)—and translating the concept from Python into Ruby.

The motivation was simple:
- I prefer Ruby, and I wanted the functionality of FinalRecon written in Ruby.
- I also wanted to refine a few architectural and UX choices to better match my personal preferences (while keeping the spirit and workflow of FinalRecon intact).

## Architecture

FinalRecon’s Python implementation achieves speed through an async-first approach (concurrent HTTP calls, fast fan-out, and clear module boundaries). Nokizaru keeps the same high-level modules and “single command” workflow, but adapts the implementation to Ruby idioms and performance constraints:

- **Concurrency model:** Nokizaru favors bounded concurrency (worker pools / thread queues) with strict per-task timeouts. This prevents a single flaky provider or endpoint from stalling the entire scan.
- **Reusable networking:** A shared HTTP client (keep-alive / connection reuse) is used where possible to reduce handshake overhead across modules.
- **Error UX:** Provider failures are reported cleanly and consistently (FinalRecon-style), but Nokizaru also aims to make errors more actionable and less noisy.
- **Performance consistency:** Timeouts and budgets are designed to produce consistent runtimes between executions, rather than “sometimes fast, sometimes stuck.”

## Configuration

### API Keys

Some modules use API keys to fetch data from different resources. These are optional—if you do not provide an API key, the module will be skipped.

#### Environment Variables

Keys are read from environment variables if they are set; otherwise they are loaded from the config directory.

```bash
NK_BEVIGIL_KEY, NK_BINEDGE_KEY, NK_FB_KEY, NK_HUNTER_KEY,
NK_NETLAS_KEY, NK_SHODAN_KEY, NK_VT_KEY, NK_ZOOMEYE_KEY

# Example :
export NK_SHODAN_KEY="kl32lcdqwcdfv"
```

#### Saved Keys

You can use **`-k`** to add keys which will be saved automatically in the config directory.

```bash
# Usage
nokizaru -k '<API NAME>@<API KEY>'

Valid Keys : 'bevigil', 'binedge', 'facebook', 'hunter', 'netlas', 'shodan', 'virustotal', 'zoomeye'

# Example :
nokizaru -k 'shodan@kl32lcdqwcdfv'
```

`Path = $HOME/.config/nokizaru/keys.json`

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

### Fedora / RPM-based Linux (primary)

```bash
sudo dnf install nokizaru
```

### macOS (Homebrew) (primary)

```bash
brew install YOUR_GITHUB_USERNAME/tap/nokizaru
```

### Other Linux / Build From Source (git clone)

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/nokizaru.git
cd nokizaru
bundle install
bundle exec nokizaru --help
```

### Curl / Wget (release tarball)

```bash
curl -L -o nokizaru.tar.gz https://github.com/YOUR_GITHUB_USERNAME/nokizaru/releases/latest/download/nokizaru.tar.gz
tar -xvf nokizaru.tar.gz
cd nokizaru
bundle install
bundle exec nokizaru --help
```

## Usage

```bash
Nokizaru - Recon Refined

Arguments:
  -h, --help       Show this help message and exit
  --url URL        Target URL
  --headers        Header Information
  --sslinfo        SSL Certificate Information
  --whois          Whois Lookup
  --crawl          Crawl Target
  --dns            DNS Enumeration
  --sub            Sub-Domain Enumeration
  --dir            Directory Search
  --wayback        Wayback URLs
  --ps             Fast Port Scan
  --full           Full Recon
  --no-MODULE      Skip specified modules above during full scan (eg. --no-dir)
  --export         Write results to export directory

Extra Options:
  -nb         Hide Banner
  -dt DT      Number of threads for directory enum [ Default : 50 ]
  -pt PT      Number of threads for port scan [ Default : 50 ]
  -T T        Request Timeout [ Default : 30.0 ]
  -w W        Path to Wordlist [ Default : wordlists/dirb_common.txt ]
  -r          Allow Redirect [ Default : False ]
  -s          Toggle SSL Verification [ Default : True ]
  -sp SP      Specify SSL Port [ Default : 443 ]
  -d D        Custom DNS Servers [ Default : 1.1.1.1 ]
  -e E        File Extensions [ Example : txt, xml, php, etc. ]
  -o O        Export Format [ Default : txt ]
  -cd CD      Change export directory [ Default : ~/.local/share/nokizaru ]
  -of OF      Change export folder name [ Default : nk_<host>_<DD-MM-YYYY>_<HH:MM:SS> ]
  -k K        Add API key [ Example : shodan@key ]
```

### Examples

```bash
# Check headers
nokizaru --headers --url https://example.com

# Check SSL certificate
nokizaru --sslinfo --url https://example.com

# Check whois information
nokizaru --whois --url https://example.com

# Crawl target
nokizaru --crawl --url https://example.com

# Directory searching
nokizaru --dir --url https://example.com -e txt,php -w /path/to/wordlist

# Full scan
nokizaru --full --url https://example.com
```

## Output / Exports

By default, results are exported to:

* `~/.local/share/nokizaru/dumps/`

You can change the export directory with `-cd`.

## Responsible Use / Disclaimers

* **Nokizaru is intended for authorized security testing and research. Always ensure you have explicit permission to scan targets you do not own.**
* Nokizaru is licensed under the MIT License. If you reuse Nokizaru or redistribute derived work, ensure you preserve applicable license notices.

