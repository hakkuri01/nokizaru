<p align="center">
  <img src="assets/nokizaru.png" alt="Nokizaru" width="100%">
</p>

<p align="center">
<img src="https://img.shields.io/badge/Ruby-black.svg?style=plastic&logo=ruby&logoColor=red">
<img src="https://img.shields.io/badge/v2.7.12-black.svg?style=plastic&logo=git&logoColor=red">
<img src="https://img.shields.io/badge/Bug%20Bounty-black.svg?style=plastic&logo=owasp&logoColor=red">
</p>

Nokizaru is a CLI tool purpose-built for enumerating the core web recon surface. Its goal is to provide a sufficiently expansive, high-signal overview of a target quickly, subverting the need to reach for heavier OSINT suites. Instead of running several tools in sequence, Nokizaru aims to produce comparable recon results with a single full-scan command. The ideal use case is collecting relevant information on a web target during the recon phase of a bug bounty/web app pentest engagement. As such, the primary audience is security researchers (not CTI analysts who may still prefer larger, more comprehensive OSINT suites).

> [!CAUTION]
> 
> *Nokizaru is intended for authorized security testing and research. Always ensure you have explicit permission to scan targets you do not own.*

---

## Architecture

Nokizaru runs a full web recon pass with shared target context, bounded or adaptive module execution, and graceful degradation when targets are slow, hostile, or heavily canonicalized. Healthy full directory scans complete their finite plan without a fixed total budget.

### Context-Aware Scanning Pipeline

- **Headers -> Target Profile:** response headers shape later scan behavior, including redirect and canonical host hints
- **Custom Headers:** repeatable `-H/--header` values are reused across in-scope web requests without printing secrets back to stdout
- **Re-Anchoring:** crawler and directory scans can automatically move to the effective in-scope URL, such as HTTP -> HTTPS or canonical same-scope hosts
- **Crawler -> Dir Enum:** crawler discoveries seed directory checks so high-signal paths are tested before lower-value wordlist noise
- **Dir Enum Noise Control:** WAF/soft-404-heavy responses are kept inspectable in exports, but stdout favors actionable paths over bulk false positives
- **Port Scan Context:** port checks are native TCP probes with lightweight service/category/TLS/HTTP/exposure hints
- **Wayback Snapshots:** host-scoped archive history selects up to five snapshots each near 3 months, 6 months, and 1 year, then fills a 50-result cap with high-signal changes

---

## Installation

### Nix (Primary)

The Nix flake is the maintained package-manager release target and includes Ruby and native dependencies. Unqualified installs resolve the latest `main` revision, which Nix locks to an exact commit; immutable version tags remain available for explicit release pinning.

```bash
nix profile install github:hakkuri01/nokizaru
```

Run without installing:

```bash
nix run github:hakkuri01/nokizaru
```

NixOS flake configurations can install the package directly from the input:

```nix
inputs.nokizaru.url = "github:hakkuri01/nokizaru";

environment.systemPackages = [
  nokizaru.packages.${pkgs.stdenv.hostPlatform.system}.default
];
```

`aarch64-linux` is release-tested. An `x86_64-linux` output is provided on a best-effort basis for community validation.

Source builds require Ruby 4.x (`>= 4.0`, `< 5.0`).

### Build From Source (Git Clone)

```bash
git clone https://github.com/hakkuri01/nokizaru.git
cd nokizaru
gem build nokizaru.gemspec
gem install nokizaru-*.gem
nokizaru --help
```

### Tarball (Latest `main`)

```bash
curl -L -o nokizaru.tar.gz https://github.com/hakkuri01/nokizaru/archive/refs/heads/main.tar.gz
tar -xzf nokizaru.tar.gz
cd nokizaru-main
gem build nokizaru.gemspec
gem install nokizaru-*.gem
nokizaru --help
```

---

## Configuration

### Provider Availability

- **crt.sh:** Quarantined from default scans due to its documented backend/database rebuild and expected degraded service until the upstream rebuild stabilizes. Nokizaru retains the adapter, tracks recovery, and will re-enable it only after a reliability and unique-value canary passes.
- **ThreatMiner:** Quarantined after a chronic API outage with no successor endpoint. Its deletion deadline is December 21, 2026, or the next minor release if the recovery gate fails.

### API Keys

Some providers use optional API keys. Missing credentials skip only that provider; architecture fingerprinting is skipped entirely without a Wappalyzer key.

#### Environment Variables

Keys are read from environment variables if they are set; otherwise they are loaded from `${XDG_DATA_HOME:-$HOME/.local/share}/nokizaru/keys.json`.

```bash
NK_ALIENVAULT_KEY, NK_BEVIGIL_KEY, NK_BINEDGE_KEY, NK_CENSYS_API_ID, NK_CENSYS_API_SECRET,
NK_CHAOS_KEY, NK_FB_KEY, NK_HUNTER_KEY, NK_NETLAS_KEY,
NK_SHODAN_KEY, NK_VT_KEY, NK_WAPPALYZER_KEY, NK_ZOOMEYE_KEY

# Example :
export NK_SHODAN_KEY="kl32lcdqwcdfv"
```

#### Saved Keys

You can use **`-k`** to add keys which will be saved automatically in the user data directory. With only the key name, Nokizaru prompts for the key without echoing it (or reads it from piped stdin), so it stays out of your shell history.

```bash
# Usage
nokizaru -k '<API NAME>'

Valid Keys : 'alienvault', 'bevigil', 'binedge', 'censys_api_id', 'censys_api_secret', 'chaos', 'facebook', 'hunter', 'netlas', 'shodan', 'virustotal', 'wappalyzer', 'zoomeye'

# Example :
nokizaru -k shodan

# The inline form still works, but the key lands in shell history
nokizaru -k 'shodan@kl32lcdqwcdfv'
```

`Path = ${XDG_DATA_HOME:-$HOME/.local/share}/nokizaru/keys.json`

| Source     | Module          | Link                                                                                                                                   |
| ---------- | --------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| AlienVault OTX | Sub Domain Enum | [https://otx.alienvault.com/api](https://otx.alienvault.com/api)                                                                    |
| Facebook   | Sub Domain Enum | [https://developers.facebook.com/docs/facebook-login/access-tokens](https://developers.facebook.com/docs/facebook-login/access-tokens) |
| VirusTotal | Sub Domain Enum | [https://www.virustotal.com/gui/my-apikey](https://www.virustotal.com/gui/my-apikey)                                                       |
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

The default config file is `${XDG_CONFIG_HOME:-$HOME/.config}/nokizaru/config.json`.

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
  --wayback        Wayback Snapshots
  --ps             Fast Port Scan
  --full           Full Recon
  --no-[MODULE]    Skip specified modules above during full scan (eg. --no-dir)
  --export         Write results to export directory
  --tui            Interactive dashboard (default on a terminal)

Extra Options:
  -nb          Hide Banner
  -dt DT       Number of threads for directory enum [ Default : 50 ]
  -pt PT       Port scan concurrency [ Default : 50 ]
  -p PORTS     Port scan ports [ Example : 80,443,1000-65535 ]
  -T T         Base timeout / module budget [ Default : 30.0 ]
  -w W         Wordlist size (small, medium, large) or custom path [ Default : medium ]
  -H, --header HEADER  Add custom request header (repeatable)
  -r           Follow redirects during directory enum [ Default : False ]
  -s           Enable SSL verification for directory enum [ Default : False ]
  -sp SP       Specify SSL Port [ Default : 443 ]
  -d D         Custom DNS Servers [ Default : 8.8.8.8,8.8.4.4,1.1.1.1,1.0.0.1 ]
  -e E         File Extension(s) (comma separated) [ Example : txt,xml,php,etc. ]
  -o O         Export Format(s) (comma-separated) [ Default : txt,json,html ]
  -cd CD       Export directory for this run (requires --export) [ Default : XDG data dir/nokizaru/exports/<hostname> ]
  -of OF       Export filename base for this run (requires --export) [ Default : YYYY-MM-DD_HH-MM-SS ]
  -k K         Add API key, prompted without echo [ Example : shodan ]
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

# Directory enumeration with a curated wordlist size
nokizaru --dir --target https://example.com -w large

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

Directory enumeration ships curated `small` (2K), `medium` (5K), and `large` (10K) wordlists. `medium` is the default; `-w` also accepts any custom wordlist path.

### Interactive Dashboard

On a terminal, `nokizaru` (or `nokizaru --tui`) launches a full-screen app; any scan flags you pass prefill the form.

1. An opening screen reveals the banner and wordmark. Press any key.
2. A command form (vim-style) collects the target, the modules, and the option and export switches, building a live `nokizaru …` command at the foot. Flags the form has no field for (`-H`, `-sp`, `-d`, `--no-MODULE`) carry over from the command line unchanged; request header values are never shown, only their count.
3. Enter runs the scan. Results stream into one tab per module, plus a Summary tab, each on its own scaffold.
4. When it finishes, browse the tabs. `q` goes back one screen: from the dashboard to the form (stopping a running scan) to adjust and re-run, and from the form it quits. Ctrl+C quits from anywhere.

Results are not printed to the terminal on exit; use `--export` (set in the form or on the command line) to save them.

| Mode | Key | Action |
| --- | --- | --- |
| Form (NORMAL) | `j`/`k`, `↑`/`↓` | Move between fields |
| Form (NORMAL) | `←`/`→` | Move across the module chips |
| Form (NORMAL) | `space` | Toggle the field or focused module |
| Form (NORMAL) | `i` | Edit a text or number field |
| Form (NORMAL) | `h` | Open the flag and key reference (`q` or `h` closes it) |
| Form (NORMAL) | `enter` | Run the scan |
| Form (NORMAL) | `q` | Quit |
| Form (INSERT) | type, `←`/`→`, `home`/`end` | Edit; `enter` runs, `esc` returns to NORMAL |
| Dashboard | `tab`/`shift+tab`, `h`/`l`, `←`/`→`, `1`-`9`/`0` | Switch module tab |
| Dashboard | `j`/`k`, `ctrl+d`/`ctrl+u`, `pgdn`/`pgup`, `g`/`G` | Scroll the results within the pane |
| Dashboard | `f` | Follow the running module |
| Dashboard | `q` | Back to the form (stops a running scan) |
| Anywhere | `ctrl+c` | Quit |

The app does not capture the mouse, so a plain drag selects and copies text, and the wheel scrolls the results. Piped or redirected runs (for example `nokizaru --full --target https://example.com --export | tee scan.txt`) skip the app and print the classic line output.

---

## Output / Exports

Scan results are not persistent by default, although Nokizaru maintains its configuration, key store, and runtime log. If you specify `--export`, it writes **TXT**, **JSON**, and **HTML** reports unless you narrow formats with `-o`.

By default, exports are written to:

```bash
${XDG_DATA_HOME:-$HOME/.local/share}/nokizaru/exports/<hostname>/
├── YYYY-MM-DD_HH-MM-SS.txt
├── YYYY-MM-DD_HH-MM-SS.json
└── YYYY-MM-DD_HH-MM-SS.html
```

By default, exports are grouped by hostname and use timestamped filenames. You can override the directory with `-cd` or the filename base with `-of`.
