# Nokizaru Agent Operating Guide

Nokizaru is a mature Ruby security tooling project. Agent work in this repository must preserve production reliability while improving correctness, security, performance, maintainability, and developer experience.

This guide applies to all agentic coding in this repository unless a more specific nested `AGENTS.md` exists.

---

## Purpose And Scope

The codebase is already functioning. Ongoing work is primarily:
- refactoring for performance gains
- fine-tuning
- edge case hardening
- expanded test coverage
- keeping Nokizaru fast, reliable, and production-ready

This file defines the non-negotiable operating constraints and the standard workflow for agentic work in this repo.

---

## Operating Principles

**Prime directive:** make the Ruby implementation correct, fast, maintainable, and test-verified.

Do not introduce speculative complexity. Prefer simple, proven approaches with measurable results.

Before writing code, climb the Ponytail ladder and stop at the first rung that holds: does this need to be built at all; does it already exist in this codebase; does the Ruby standard library, a platform feature, or an already-installed gem cover it; can it be one line; only then, write the minimum code that works.

A deliberate shortcut with a known ceiling (an O(n²) scan over a bounded n, a lock held across a loop, a naive heuristic) carries a `# ponytail:` comment naming the ceiling, the bound that keeps it safe, and the upgrade path. The lowercase tag is a searchable marker, like `rubocop:disable`, so it is exempt from the capital-letter comment rule in `CONTRIBUTING.md`.

**Default priorities, highest to lowest:**
1. Correctness, including edge cases and test coverage
2. Security, OWASP Top 10-aligned, justified, and not performative
3. Performance, measured and not guessed, with every path meeting its complexity target
4. Maintainability, idiomatic Ruby, senior-level design, and clean code
5. Developer experience, clear docs, clean artifacts, and a tidy repo

---

## Code Standards

### Idiomatic Ruby

- Use idiomatic Ruby patterns, naming, and standard library where appropriate
- Favor small, composable objects/modules, clear boundaries, and explicit interfaces
- Avoid clever metaprogramming unless it demonstrably improves the codebase and remains readable

### Senior Ruby Developer Methodology

- Make changes in small, reviewable increments
- Keep public APIs stable unless explicitly changing behavior
- Prefer clarity over micro-optimizations until profiling indicates a bottleneck

### Clean Code Principles

- Single responsibility, descriptive names, minimal side effects
- Keep methods short and intention-revealing
- Avoid action at a distance: keep state local and pass dependencies explicitly
- Remove dead code and dead tests as soon as they are verified obsolete

### Common Ruby Guidance

- Validate and sanitize external input at boundaries
- Avoid dynamic evaluation of untrusted content
- Use safe defaults for parsing, deserialization, and command execution
- Treat filesystem paths, shell arguments, and SQL as hostile unless proven otherwise
- Avoid leaking secrets in logs, errors, or test artifacts

### Style Guide

Follow the repository style guide in `CONTRIBUTING.md`.

---

## Algorithmic Complexity (Big O)

**Complexity is a builder step.** Run it on every change, right after the Ponytail ladder settles what to build, and in every review: name what grows, name the path the code runs on, and meet that path's target. O(1) is the gold standard, O(log n) excellent, O(n) often optimal (the lower bound for anything that must read every item or byte), O(n log n) optimal for general sorting, and O(n²) or worse needs a stated bound on n or a redesign. O(n³), O(2ⁿ), and O(n!) never ship. The goal is the lowest practical complexity for the problem, kept readable and correct; an algorithm cleverer than n will ever need is over-engineering, and the Ponytail ladder still applies to it. This step is design, not tuning: it picks the data structure and algorithm while the code is written, and Performance Work governs tuning existing code against measurements.

1. **Name what grows.** Here: candidate URLs in directory enumeration (W wordlist entries times one plus E extensions; the bundled lists hold 2,048, 5,120, and 10,240 entries, and a custom `-w` list can hold millions), ports per scan (P, up to 65,535), requests in flight (C: `-dt` and `-pt`, 50 by default; a large port scan opens up to `LARGE_SCAN_MAX_CONCURRENCY` (1,024) sockets, held under the open-file limit; 8 crawl fetch workers; 10 workers across the 17 subdomain providers), names returned per provider, links, scripts, and sitemaps per crawl, and Wayback CDX records (1,000 a page, up to 50,000 and 32 MB). Above all, text from outside: response bodies and headers, robots.txt, sitemaps, JavaScript, WHOIS and RDAP replies, DNS records, and provider JSON. The target is the system under test and may be built to fight back (tarpits, WAFs, endless or oversized responses), so all of it is untrusted and unbounded until capped. Per run: progress redraws (every 0.12 s while the rail runs), dashboard frames (in a terminal: up to 30 a second, drawn only when something changed) and the lines each dashboard tab holds (capped at `Tab::MAX_LINES`, 20,000), and the export payload, which is the sum of every module's results.
2. **Name the path, and meet its target.**

   | Path | Runs | Target | Accepted ceiling (with a `# ponytail:` comment naming n's bound) |
   |---|---|---|---|
   | Per candidate (pick the next URL or port, send it) | Once per candidate, C at a time | O(1): one request per candidate plus a fixed retry budget; the work queue is generated lazily and walked by cursor, never materialized up front or rescanned; the seen check is a `Set`; probe sets (preflight, soft-404 baselines) are fixed in size, never proportional to W | None worse than O(1) amortized |
   | Per response (classify, soft-404 and confidence checks, pressure and concurrency adaptation) | Once per response, from every worker | O(1) in the responses seen so far: counters and windows update incrementally, comparisons run against fixed-size baselines, and work under the shared runtime `Mutex` stays O(1) | O(window) over a fixed-size window (`PRESSURE_WINDOW_REQUESTS`, `ADAPTIVE_CONCURRENCY_WINDOW`, `TIMEOUT_ADAPT_SAMPLE_SIZE`), outside the lock where it can be; never O(responses so far) |
   | Text from outside (parse, extract, normalize, fingerprint) | Over every byte of every body, header, and reply | One O(n) pass over input capped first; a document is parsed once and its tree queried, never re-parsed. The text is untrusted, so worse than linear in its length is a denial of service, not only slow | None |
   | Port scan event loop | Every `IO.select` turn | O(C) over the sockets in flight (`IO.select` is linear in what it watches) | C bounded by `LARGE_SCAN_MAX_CONCURRENCY` and the open-file limit |
   | Network rounds (subdomain providers, Wayback, WHOIS and RDAP, crawl fetches) | Per module, per run | O(1) rounds of waiting per module: independent calls run side by side on a fixed pool, every call has a timeout and a bounded retry count, and nothing already fetched is fetched again | Cursor pagination (Wayback CDX) is sequential by nature; one round per level of dependency (a sitemap index, then its sitemaps) |
   | Once per scan (wordlist load, port spec, URL plan, findings, export) | Once per run | O(n) to read and dedupe through a `Hash` or `Set`, O(n log n) to sort | O(n) memory for the wordlist and the seen set, the price of exact dedup |
   | Per progress redraw | Every 0.12 s tick and every progress update | O(terminal width), drawn from counters in a snapshot | None: a redraw never walks results |
   | Dashboard loop (TUI) | Every `IO.select` turn, one 0.05 s tick, each printed line | Waits only in `IO.select`, which releases the GVL, so scan threads keep full speed; a printed line is sanitized, capped (`Feed::MAX_LINE_BYTES`), and queued in O(its length); a tick drains at most `Program::DRAIN_LIMIT` lines and appends each in O(1) amortized, wrapping only the new line | None |
   | Dashboard frame (TUI) | Up to 30 a second, only when the model changed | O(rows × cols): the focused tab's visible window is a slice by offset, the HUD reads one progress snapshot copy; changed rows only are written | None: a frame never walks a tab's lines. Re-wrapping a tab after a resize is O(its lines), once per resize, bounded by `Tab::MAX_LINES` |
   | Tests and local tooling (`test/`, `bench/`) | Per suite run | O(n log n) | Polynomial for a bounded n |

3. **Look up by key.** A lookup or membership test inside a loop over candidates, responses, ports, provider results, links, or CDX records goes through a `Hash` or a `Set` (`to_set`, `to_h`, `group_by`, `each_with_object({})`). A `find`, `include?`, `index`, `delete`, or `select` over one such collection inside a loop over another is a hidden O(n²). `uniq`, `|`, `&`, and `-` hash their operands and stay linear. A linear `include?` over a small frozen constant list is fine: it is fixed and small.
4. **Ruby strings and arrays hide quadratics.**
   - On a string holding any non-ASCII character, `str[i]` and `str[i, len]` count characters from the start, so a loop that indexes by character is O(n²). ASCII-only strings index in O(1), so the trap stays hidden until a target serves non-ASCII text. Walk with `each_char`, `each_byte`, or `StringScanner`, and work in byte offsets (`byteindex`, `byteslice`).
   - `str += part` copies the whole string every time, so output built that way in a loop is O(n²). Build with `<<` on an unfrozen buffer (`+''` or `String.new`), `Array#join`, or `StringIO`.
   - `list = list + other` and `inject(:+)` over arrays copy on every step; use `concat`, `<<`, `flat_map`, or `each_with_object([])`.
   - Take the best item with `min_by` or `max_by` (O(n)), and a top k with `max_by(k)`, rather than `sort_by(...).first`.
   - A `Regexp` literal with interpolation (`/#{value}/`) compiles every time it is evaluated; hoist it into a constant or build it once per scan.
5. **Regexes on untrusted text run in linear time.** Ruby memoizes regex matching, so most patterns are linear, but a backreference opts a pattern out. Every pattern applied to text from outside passes `Regexp.linear_time?`, pinned by a test; a pattern that cannot (it needs a backreference) runs only on input capped to a small stated size, with a `# ponytail:` comment naming the cap.
6. **Prepare off the hot path.** Work that depends only on the configuration and the wordlist (normalizing, deduping, and prioritizing words, parsing the port spec, building the seed URL plan, compiling patterns) runs once per scan before the first request, never per response. Lookup tables and pattern lists are frozen constants built at load time, not rebuilt inside a method that runs per response.
7. **Round trips decide.** Big O ignores constants, and here they are large: one request to the target or a provider costs tens to hundreds of milliseconds, and seconds through a WAF or a tarpit, far more than Ruby spends on a typical response. Cut requests and rounds of waiting first, then asymptotics where n is large enough to matter. Requests are also Nokizaru's footprint on a system someone else runs: a change that adds requests per candidate, re-fetches a URL another module already fetched, or adds a retry without a budget is a regression in speed and in noise, even when it simplifies the code. Threads overlap network waits but share one GVL for Ruby work, so CPU-bound work per response caps throughput at one core however many threads run, and work inside a shared `Mutex` stalls every worker waiting on it.
8. **Space counts.** Everything read from the network has a cap (bytes per body and page, records, links, lines); every httpx response body stops at `BodyCap::MAX_BYTES` (8 MiB decoded, gzip and deflate included) at the transport, and Wayback's `CDX::MAX_BODY_BYTES`, `Query::MAX_CDX_RECORDS`, and `Normalize::CATEGORY_LIMIT` and the crawler's `MAX_*` link limits are examples of tighter ones. Enforce a cap while reading or collecting where the client allows, so memory stops at the cap, rather than trimming a list already built. Results keep a fixed-size summary of each response (status, length, title, fingerprint), never the body. Caches and seen sets belong to one scan and die with it. Work run side by side multiplies peak memory, so C workers hold at most C responses.
9. **Pin the target with a check.** A target that matters gets a test that fails when it regresses, counting something deterministic: requests a stubbed client received for a given wordlist and config (and duplicates to one URL), the peak number in flight against the configured threads, objects allocated around a call (`GC.stat(:total_allocated_objects)` before and after, at two input sizes so the growth rate shows), parse passes per response, or `Regexp.linear_time?` for every regex literal in `lib/` (`test/regex_linear_time_test.rb` walks the source, so a new pattern is pinned without being listed). Never a wall-clock timing, which is flaky under load; deadline logic stubs the clock (`Process.stub(:clock_gettime, ...)`), as the existing tests do. A fix's check must fail on the code before the fix.

---

## Security Requirements

Follow OWASP Top 10 avoidant secure coding best practices, with justification.

Every security decision must answer:
1. What is the realistic threat or exploit vector here?
2. What is the simplest mitigation that meaningfully reduces risk?
3. What is the performance or complexity cost, and is it worth it?

Do not add heavy security scaffolding just because. When a mitigation is added, document it briefly with a code comment or PR note tied to the specific risk.

### OWASP-Aware Checklist

Use this checklist when relevant. Not all items apply to all changes.

- **Injection:** Avoid SQL injection, command injection, and template injection. Prefer parameterized queries; avoid string interpolation into queries or commands
- **Broken Access Control:** Validate permissions at boundaries; test negative paths
- **Cryptographic Failures:** Do not invent crypto; use established libraries and patterns
- **Insecure Design:** Prefer explicit invariants and constraints; test them
- **Security Misconfiguration:** Avoid insecure defaults; document required env vars/config
- **Vulnerable/Outdated Components:** Keep dependencies minimal; document rationale
- **Identification/Auth Failures:** Avoid leaking auth state; validate session logic
- **Software/Data Integrity:** Validate inputs; avoid unsafe deserialization
- **Logging/Monitoring Failures:** Do not log secrets; ensure errors are actionable but safe
- **SSRF:** Treat URLs and network destinations as hostile unless allowlisted

Lean on OWASP's broader Top 10 documentation and secure coding guidance when necessary; the checklist above is not exhaustive.

When a mitigation is added, include a short rationale:
- `# Security: <risk> mitigated by <approach> (cost acceptable because <reason>)`

---

## Testing And QA

### Tests Are Mandatory For Behavior And Edge Cases

- Every non-trivial change must include tests
- Bug fix = test that fails before the fix and passes after
- Prefer deterministic tests; avoid timing-based flakiness

### Coverage Expectations

Ensure strong coverage over:
- edge cases
- error handling paths
- boundary conditions
- performance-sensitive hot paths, via count-based regression tests (see Algorithmic Complexity, rule 9)

### QA Double Check Pass

After implementing changes:
- Run the full test suite
- Run linters/formatters
- Confirm no debug output, stray files, or unused artifacts remain
- Verify behavior is unchanged unless explicitly intended

---

## Performance Work

### Profiling First

Before optimizing, identify bottlenecks with real measurements:
- Prefer Ruby profiling tools appropriate to the stack, such as a sampling profiler or allocation profiler
- Measure relevant functions end-to-end where feasible
- Use representative production-like workloads where possible
- Keep profiling and benchmark scripts in the gitignored `bench/` directory so they never ship
- Measurements find the bottleneck; the regression guard that lands with the fix is a count-based test (see Algorithmic Complexity, rule 9), never a timing

### Avoid Premature Micro-Optimization

- First: fewer requests and rounds of waiting, then algorithmic improvements, data structure choices, and unnecessary I/O removal
- Then: allocation reduction, hot loop tuning, and caching with invalidation clarity
- Only optimize with an explicit bottleneck and a count-based regression guard

---

## Repository Hygiene

### Remove Dead Artifacts

After each pass, delete unused tests, obsolete fixtures, scratch scripts, and redundant helpers.

Confirm removal does not reduce needed coverage or tooling.

### Keep The Repo Orderly

- Keep docs current
- Keep the test suite fast and organized
- Prefer consistent conventions for paths, naming, and structure

### Packaging And Release Hygiene

- Source clones and source tarballs may include contributor files such as tests, docs, and repository metadata
- Runtime packages should stay lean through the gemspec allowlist
- Do not broaden `spec.files` casually; include only runtime files and user-facing documentation needed by installed packages
- The versioned Nix flake is the only maintained package-manager release target; git clones and source tarballs remain supported installation methods
- Additional package-manager pipelines must be contributor-owned, complete, and accepted through review before becoming supported
- Keep `Gemfile.nix.lock` on the generic `ruby` platform and version-aligned with `Gemfile.lock`
- Regenerate `gemset.nix` whenever `Gemfile.nix.lock` changes and review every source hash
- Run `nix flake check` natively before release and evaluate all declared systems with `nix flake check --all-systems --no-build`
- Never place credentials, API keys, mutable configuration, or private scan data in a Nix derivation or flake input
- Never add GitHub Actions or other files under `.github/workflows/`
- Submit nixpkgs packaging only after the corresponding immutable release tag exists

### Bundler Cooldown Hygiene

- This project uses Bundler's `cooldown` feature on the public RubyGems source to reduce exposure to freshly published malicious gems after supply-chain incidents
- Treat the feature as actively evolving until RubyGems/Bundler clearly stabilizes it across Bundler and standalone `gem` workflows
- In future dependency-hygiene sessions, always investigate the current RubyGems/Bundler cooldown status first, then update the user with findings before changing project policy
- After the investigation, ask whether to address related hygiene or housekeeping so this remains an intentional recurring maintenance item
- If the feature has reached a stable or mature state, explicitly say so in the update to the user
- Emergency bypass for urgent security fixes: `bundle update <gem> --conservative --cooldown 0`
- Prefer Bundler 4.0.14 or newer for cooldown work because 4.0.14 includes follow-up fixes after the initial 4.0.13 release

---

## Agent Workflow

Follow this cycle for each task.

### Pre-Flight

1. Read relevant code
2. Identify the objective: refactor, performance, edge-case fix, test improvement, or another clearly scoped task
3. Identify risk areas: input boundaries, parsing/deserialization, filesystem/shell usage, auth/session handling if applicable, and concurrency/state
4. Name what grows and the complexity path each touched method runs on (see Algorithmic Complexity)

### Plan

Write a short, concrete plan in task notes or output that includes:
- files to touch
- tests to add or update
- how success will be measured, including tests and profiling data if performance work
- the complexity target for each path touched, and any ceiling to accept with a `# ponytail:` comment
- any security considerations with justification

### Execute

- Keep refactors behavior-preserving unless explicitly changing behavior
- Maintain clean diffs

### Verify

Run, at minimum:
- full test suite
- linting/formatting if present
- performance measurements if performance-related
- the complexity step: every path touched meets its target, or its ceiling carries a `# ponytail:` comment naming the bound

### Post-Flight Cleanup

- Remove unused artifacts introduced during exploration
- Ensure there are no temporary files, debug prints, or disabled tests
- Update docs if behavior or performance claims changed

---

## Practical Defaults

If the repository does not already define these, prefer:
- stdlib hand-written tests tailored to the situation, or RSpec at most if a dedicated test dependency is needed
- RuboCop for linting/formatting

### RuboCop Governance Baseline

- Treat RuboCop as architectural governance, not just syntax cleanup
- Keep `Lint`, `Security`, and `Naming` cops strict as hard quality gates
- Use `Metrics` cops as readability guardrails, calibrated for CLI orchestration code so methods/modules remain cohesive without helper over-fragmentation
- Do not use broad excludes or TODO debt files to suppress structural issues
- Avoid inline cop disables unless truly necessary; when used, add a concise rationale tied to maintainability/performance/security tradeoff
- Keep refactors RuboCop-clean under the curated repo config, without changing cop rules to fit a single patch

Do not add new tooling unless it is justified, lightweight, and consistent with the existing ecosystem of the repo.

---

## Output Expectations

When delivering changes, include:
- summary of what changed and why
- tests added or updated, and what they cover
- profiling or performance results if relevant, before/after on the same machine/settings
- complexity notes: paths touched, targets met, and any accepted ceilings
- any security-relevant changes with justification
- any cleanup performed, such as deleted files or removed dead code
