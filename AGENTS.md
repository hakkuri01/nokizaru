# Nokizaru | AI Agent Guidelines

Working rules for AI coding agents on Nokizaru, a fast, modular web
reconnaissance CLI with an interactive terminal dashboard. Nokizaru is a single
statically-distributable binary: the standard library only, zero runtime shards,
with its data (the Public Suffix List, the curated wordlists) embedded at compile
time.

Nokizaru is implemented in Crystal. Source lives at the root (`src/`, `spec/`),
and the original Ruby implementation through 2.7.12 remains available in Git
history, at commit `f07456c`.

## Mandatory Rules

### Algorithmic Complexity (Big O)

**Complexity is a builder step.** Run it on every change, right after the Ponytail
ladder settles what to build, and in every review: name what grows, name the path
the code runs on, and meet that path's target. O(1) is the gold standard,
O(log n) excellent, O(n) often optimal (the lower bound for anything that must
read every item or byte), O(n log n) optimal for general sorting, and O(n squared)
or worse needs a stated bound on n or a redesign. O(n cubed), O(2^n), and O(n!)
never ship.

The path-target table below is the standard this tool is held to. Each row is
reconfirmed against the Crystal implementation with a count-based spec as its
module lands (the per-module complexity pass); the rows are targets, not a claim
that today's code already meets them.

1. **Name what grows.** Candidate URLs in directory enumeration (W wordlist
   entries times one plus E extensions; the bundled lists hold 2,048, 5,120, and
   10,240 entries, and a custom `-w` list can hold millions), ports per scan (P,
   up to 65,535), requests in flight (C, `-dt`/`-pt`, 50 by default; a large port
   scan opens up to a bounded socket count under the open-file limit), names per
   provider across the ~17 subdomain providers, links and sitemaps per crawl, and
   Wayback CDX records. Above all, text from outside: response bodies and headers,
   robots.txt, sitemaps, JavaScript, WHOIS and RDAP replies, DNS wire responses,
   and provider JSON. The target is the system under test and may fight back
   (tarpits, WAFs, endless or oversized responses), so all of it is untrusted and
   unbounded until capped. Per run: progress redraws, dashboard frames (drawn only
   when the model changed) and the lines each tab holds (capped), and the export
   payload (the sum of every module's results).
2. **Name the path, and meet its target.**

   | Path | Runs | Target | Accepted ceiling (with a `# ponytail:` comment naming n's bound) |
   |---|---|---|---|
   | Per candidate (pick the next URL or port, send it) | Once per candidate, C at a time | O(1): one request plus a fixed retry budget; the work queue is generated lazily and walked by cursor, never materialized or rescanned; the seen check is a `Set` | None worse than O(1) amortized |
   | Per response (classify, soft-404, confidence, pressure/concurrency adaptation) | Once per response, from every worker | O(1) in responses seen so far: counters and windows update incrementally against fixed-size baselines; work under the shared lock stays O(1) | O(window) over a fixed-size window, outside the lock where it can be; never O(responses so far) |
   | Text from outside (parse, extract, normalize, fingerprint) | Over every byte of every body, header, reply | One O(n) pass over input capped first; a document is parsed once and its tree queried | None |
   | Port scan event loop | Every readiness turn | O(C) over sockets in flight | C bounded by the large-scan cap and the open-file limit |
   | Network rounds (providers, Wayback, WHOIS/RDAP, crawl fetches) | Per module, per run | O(1) rounds of waiting: independent calls run side by side on a fixed pool, each with a timeout and a bounded retry count; nothing already fetched is refetched | Cursor pagination is sequential; one round per dependency level |
   | Once per scan (wordlist load, port spec, URL plan, findings, export) | Once per run | O(n) to read and dedup through a `Hash`/`Set`, O(n log n) to sort | O(n) memory for the wordlist and seen set |
   | Per progress redraw | Every tick and progress update | O(terminal width), from a snapshot of counters | None: a redraw never walks results |
   | Dashboard frame (TUI) | Only when the model changed | O(rows x cols): the focused tab's visible window is a slice by offset; changed rows only | None: a frame never walks a tab's lines |

3. **Look up by key.** A membership test inside a loop over candidates,
   responses, ports, provider results, links, or CDX records goes through a `Hash`
   or `Set`, never a `find`/`includes?`/`index`/`select` over one collection
   inside a loop over another (a hidden O(n squared)). `uniq`, `|`, `&`, and `-`
   hash their operands and stay linear.
4. **Crystal strings and arrays hide quadratics.** On a string holding any
   non-ASCII character, `str[i]` and `str[i, n]` count characters from the start,
   so a per-character loop is O(n squared) (ASCII-only strings index in O(1), so
   the trap hides until a target serves non-ASCII text). Walk with `each_char`,
   `each_byte`, or a `Char::Reader` kept in one scope, and work in byte offsets
   (`byte_index`, `byte_slice`). Build strings with `String.build` or `<<` on a
   buffer, never `str += part` in a loop. Grow arrays with `concat`/`<<`, not
   `arr + other` in a loop. Take the best item with `min_by`/`max_by`, not
   `sort_by(...).first`. Hoist an interpolated `Regex` into a constant.
5. **Regexes on untrusted text.** PCRE2 backtracks and gives no linear-time
   guarantee, so every pattern applied to text from outside is structurally safe
   (no backreference, no lookaround), pinned by a spec that walks `src/`; a
   pattern that cannot be made safe runs only on input capped to a small stated
   size, or becomes a hand-written scanner.
6. **Prepare off the hot path.** Work that depends only on config and the wordlist
   (normalizing and prioritizing words, parsing the port spec, building the seed
   URL plan, compiling patterns) runs once per scan before the first request,
   never per response. Lookup tables are frozen constants built at load time.
7. **Round trips decide.** A request to the target or a provider costs tens to
   hundreds of milliseconds, seconds through a WAF or tarpit, far more than Crystal
   spends on a response. Cut requests and rounds of waiting first, then
   asymptotics where n is large. Requests are also Nokizaru's footprint on someone
   else's system: a change that adds a request per candidate, refetches a URL
   another module already fetched, or adds a retry without a budget is a
   regression even when it simplifies the code. Fibers overlap network waits but
   share one process for Crystal work, so CPU work per response caps throughput at
   one core, and work inside a shared lock stalls every worker waiting on it.
8. **Space counts.** Everything read from the network has a cap (bytes per body
   and page, records, links, lines), enforced while reading where the client
   allows, so memory stops at the cap rather than trimming a list already built.
   Results keep a fixed-size summary per response (status, length, title,
   fingerprint), never the body. Caches and seen sets belong to one scan and die
   with it. C workers hold at most C responses.
9. **Pin the target with a check.** A target that matters gets a spec that fails
   when it regresses, counting something deterministic: requests a stubbed client
   received for a given wordlist and config (and duplicates to one URL), the peak
   in flight against the configured limit, bytes allocated around a call
   (`GC.stats.total_bytes` before and after, at two input sizes so the growth rate
   shows), parse passes per response, or `Regex` source safety for every literal in
   `src/`. Never a wall-clock timing; deadline logic stubs the clock.

### Security

**All code is OWASP Top 10 avoidant by construction**, and every block that
touches untrusted data is reasoned through before it is written.

1. **Server data is untrusted and hostile.** Nokizaru renders arbitrary HTTP
   responses, DNS and WHOIS replies, and provider JSON from arbitrary targets. All
   external text (bodies, headers, status reasons, titles, extracted links,
   redirect targets, WHOIS text, filenames) passes a sanitize pass before it
   touches the terminal or the filesystem: strip escape sequences, C0 and C1
   controls, and bidirectional overrides. A rendered line drops newline with the
   other controls, because a newline in a value forges a second line; text whose
   breaks are content (a WHOIS record) keeps them (`TerminalText.plain_block`).
   A value stored on the run is sanitized where it enters the result, so the
   report files carry no escapes either. A malicious or compromised target must
   not inject terminal escapes into the TUI or the classic output; styles are
   applied after sanitizing.
2. **Validate at the boundary, never repair.** A redirect `Location`, a crawled
   link's host, a DNS name, a provider-returned hostname, a WHOIS referral are
   validated (scheme, host, scope) and refused when unsafe, not rewritten. Scope
   decides which names a scan may follow; `Destination` decides which addresses
   those names may resolve to, so a target cannot steer a request at the
   operator's own network. A scan aimed at an internal target allows internal
   destinations; one aimed at a public target does not. No outbound request is
   built from unvalidated server data.
3. **Network limits.** Every request has connect and read timeouts and a total
   operation deadline. Every response has its status, content type, and size
   (against a cap) checked before use; bodies, including transparent gzip/deflate,
   stop at the decoded cap. Retries are bounded. TLS verification is on for every
   request; the operator may turn it off for the target they named with
   `--insecure`, and that choice is theirs. Third-party services (subdomain
   providers, the archive, RDAP) stay verified regardless. The one exception is
   the sslinfo module, whose job is to read a certificate that may be invalid.
4. **No shell.** Subprocesses, if ever needed, use argument arrays, never a shell,
   with a timeout and a cleaned environment. Nothing of any provenance is
   shell-interpolated.
5. **Secrets.** API keys, and authentication headers and cookies the operator
   supplies via `-H`, are never written to result files, logs, or module output;
   reference them by name, never echo or persist them silently. The key store is
   written owner-only through a temp file and rename.
6. **Filesystem.** Export paths and anything derived from server data are reduced
   to a safe basename under the owner-only data directory; no path traversal.
7. **Errors.** Every expected failure is one actionable line, no stack trace or
   internal path.
8. **Authorization is the operator's.** Nokizaru scans what it is pointed at; the
   README says scanning a target you are not authorized to test is the operator's
   responsibility.
9. **A safety predicate has one home.** A sanitize, scope, or validation check is
   written once and called everywhere, never re-derived beside a new caller.
10. **Any network exposure is private by default.** A test fixture or debug server
    binds `127.0.0.1` only; `just verify` never touches the network.

### Code Quality

1. **Maximum 40 lines per method or macro.** Extract private helpers.
2. **File size: 500 lines is a hard limit, 300 the soft target.** Split past 300
   unless the code is one cohesive unit that reads worse split.
3. **Maximum 4 parameters per method.** Group more into a `record` or struct, or
   use named arguments.
4. **No duplicated blocks over 6 lines.** Extract the shared code.
5. **No `not_nil!`, `.as(T)` cast, or `uninitialized` in `src/`** without an inline
   comment saying why the type cannot be narrowed. Prefer `if value = ...`
   narrowing and exhaustive `case ... in`. In `spec/`, `not_nil!` is the ordinary
   way to assert presence and is allowed.
   - `Char::Reader` (like every struct) is copied when passed to a method, so a
     helper that advances it advances a copy. Keep a reader in one scope or an ivar.
6. **No dead code.** `crystal tool unreachable --check` fails the gate on any
   method called by neither the binary nor a spec, so nothing is written ahead of
   its caller.
7. **`src/` has no side effects when required.** Only `src/nokizaru.cr` runs
   anything. Nested namespaces use the compact form (`module Nokizaru::Modules`).
8. **Typed state, not hashes.** Module results and the run state are typed structs
   and records; the export is `JSON::Serializable` whose on-wire shape matches the
   Ruby tool's JSON (the parity contract). An untyped `JSON::Any` is not a data
   carrier across module boundaries.

#### Naming

Crystal community conventions: `snake_case` for methods, variables, and files;
`CamelCase` for types; `SCREAMING_CASE` for constants; predicates end in `?` and
raising variants in `!`. One primary type per file, named after it in snake_case,
directories mirroring namespaces (`Nokizaru::Modules::DirectoryEnum` lives in
`src/nokizaru/modules/dirrec/...`).

Avoid non-inclusive terms (use allowlist/denylist, primary/replica, and so on) in
code, comments, and docs.

#### Comments / Documentation

This is a solo-maintainer project with a minimal comment policy, not a
doc-commented library (Ameba's documentation rule stays off).

- A comment appears only where the code is not readably self-explanatory.
- Ideally one line, no ending period.
- Otherwise two to three lines at most, ending in a period, as a docstring-style
  block.
- One exception runs longer: a non-obvious security decision or a known gotcha (a
  crash, a DoS, an ordering trap) may take a short block, ideally ending with a
  pointer (the function it mirrors, the principle it serves).
- No commented-out code, no `TODO`/`FIXME`.
- A deliberate shortcut with a known ceiling carries a lowercase `# ponytail:`
  comment naming the ceiling, the bound that keeps it safe, and the upgrade path
  (a searchable marker, like `ameba:disable`, exempt from the capital-letter rule).
- Never use em dashes anywhere: code, comments, string literals, Markdown, or
  commit messages. Use commas, semicolons, colons, parentheses, or separate
  sentences.

### Dependencies

- **Zero runtime shards.** `shard.yml` has no `dependencies` key; the binary uses
  the standard library only. Every former Ruby gem (thor, json, erb, nokogiri,
  httpx, dnsruby, whois, public_suffix, concurrent-ruby/async, zlib) is hand-rolled
  or covered by the standard library. An HTTP/2 client, when it lands, is
  hand-rolled too; Gori (`hahwul/gori`) may be read for structural insight only,
  never copied.
- **Embedded data is not a dependency.** The Public Suffix List and the curated
  wordlists under `data/` are compile-time `read_file` embeds, carried in the
  binary, not linked code.
- **Ameba is the only development dependency.** Pinned to a commit, `shard.lock`
  committed, installed by `just setup` with `--frozen --skip-postinstall` and built
  from `lib/`, so no install script runs. Adding any other dependency is the
  owner's decision.

### Testing

- `spec/` mirrors `src/` (the Crystal convention). New logic ships with a spec. A
  cross-cutting invariant no single file owns is a seam spec at the `spec/` root
  (the PSL integrity pin, the regex-source-safety walk): it fails the moment one
  file breaks the property.
- **Dependency injection over stubbing.** The clock, the HTTP transport, and the
  resolver are constructor parameters; specs inject fakes. There is no runtime
  method replacement.
- `just verify` never touches the network. Fixtures bind `127.0.0.1` only.
- Count-based checks, never timings: allocation deltas (`GC.stats.total_bytes`),
  stubbed-client request counts, peak in-flight against the configured limit.
- Before trusting a new lint or source rule, prove it fires on a probe.

### What NOT to Do

- Do NOT add a runtime shard, or a second development dependency, without the
  owner's decision.
- Do NOT encode or sanitize an operator's own payload bytes (`-H` values, a
  target path); that is the payload. Sanitize only where a byte is rendered.
- Do NOT cite a `.kiro/specs/` path from committed code, tests, or docs.
- Do NOT add files under `.github/workflows/`.

## Maintainer Tasks

Some upkeep is the maintainer's alone and is not documented for contributors.

- **Refreshing the Public Suffix List.** The embedded `data/public_suffix_list.dat`
  is pinned by `spec/psl_pin_spec.cr` to `Nokizaru::PSL::SHA256`. To update it, the
  maintainer runs `crystal run tools/refresh_psl.cr`: it fetches the canonical
  list, accepts it only if it is still the structured Mozilla list and its delta
  against the committed baseline is purely rule and comment data, rewrites the
  file, and prints the new SHA-256 to paste into `src/nokizaru/psl.cr`. Then review
  the diff and commit. The tool is never run by the build, a scan, or CI, and there
  is no LLM in the loop: the one-time legitimacy judgment is already captured as
  the pinned baseline.

## Dev

Always enter the project-level development shell with `nix develop` before doing
any work. Use the project shell's toolchain, never tools inherited from the host
or agent environment.

The task runner is `just` (`just --list` shows every recipe). `mise install` pins
the toolchain (Crystal and `just`).

```sh
mise trust && mise install   # once per machine: pins crystal + just
just setup                   # once after cloning, and when shard.lock changes (the only networked recipe)
just verify                  # the canonical gate
```

`just verify` runs, stopping at the first failure:

1. `crystal tool format --check src spec`
2. `bin/ameba` (default rules, scoped to `src` and `spec`)
3. `crystal spec --order random`
4. `crystal tool unreachable --check` (roots: the binary and the specs)
5. `crystal build --release` into `bin/nokizaru`

The root `flake.nix` packages the Crystal binary and runs the same development
gate through `nix flake check`.

## Committing

- **One logical change per commit.** Release commits lead with the version and a
  colon (`1.0.0: ...`); smaller commits use a lowercase category prefix (`docs:`,
  `chore:`, `fix:`, `feat:`) or a brief bare summary. Lowercase throughout, no
  trailing period, no body unless it earns one.
- **No AI attribution** anywhere, in a commit or a PR.
- Agent commits only when the owner asks; the owner pushes.

## Refactoring and Bulk Edits

Never use blanket find-and-replace (sed, regex bulk replacement) across the code.
Work occurrence by occurrence, reading the context of each before changing it.
