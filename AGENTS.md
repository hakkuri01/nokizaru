# AGENTS.md — Project Agent Operating Guide (OpenCode)

This repository is a Ruby rewrite of an existing Python project. The codebase is already functioning; the ongoing work is primarily:
- refactoring for performance gains
- fine-tuning
- edge case hardening
- expanded test coverage
- ensuring the Ruby implementation exceeds the Python baseline.

This file defines the non-negotiable operating constraints and the standard workflow for any agentic coding in this repo.

---

## 0) Prime Directive

**Make the Ruby implementation correct, fast, maintainable, and test-verified.**
Do not introduce speculative complexity. Prefer simple, proven approaches with measurable results.

**Default priorities (highest to lowest):**
1. Correctness (incl. edge cases) + test coverage
2. Security (OWASP Top 10-aligned, *justified*, not performative)
3. Performance (measured, not guessed)
4. Maintainability (clean code, idiomatic Ruby, senior-level design)
5. Developer experience (clear docs, clean artifacts, tidy repo)

---

## 1) Code Standards (Must Follow)

### 1.1 Idiomatic Ruby (Required)
- Use idiomatic Ruby patterns, naming, and standard library where appropriate.
- Favor small, composable objects/modules, clear boundaries, and explicit interfaces.
- Avoid clever metaprogramming unless it demonstrably improves the codebase and remains readable.

### 1.2 Senior Ruby Developer Methodology (Required)
- Make changes in small, reviewable increments.
- Keep public APIs stable unless explicitly changing behavior.
- Prefer clarity over “micro-optimizations” until profiling indicates a bottleneck.

### 1.3 Clean Code Principles (Required)
- Single responsibility, descriptive names, minimal side effects.
- Keep methods short and intention-revealing.
- Avoid “action at a distance”: keep state local, pass dependencies explicitly.
- Remove dead code and dead tests as soon as they are verified obsolete.

### 1.4 Security (Required, but Not Security Theater)
Follow **OWASP Top 10 avoidant secure coding best practices**, *with justification*:
- Every security decision must answer:
  1) What is the realistic threat/exploit vector here?
  2) What is the simplest mitigation that meaningfully reduces risk?
  3) What is the performance/complexity cost, and is it worth it?
- Do not add heavy security scaffolding “just because.”
- When you add a mitigation, document it briefly (code comment or PR note) tied to the specific risk.

Common Ruby guidance:
- Validate and sanitize external input at boundaries.
- Avoid dynamic evaluation of untrusted content.
- Use safe defaults for parsing, deserialization, and command execution.
- Treat filesystem paths, shell arguments, and SQL as hostile unless proven otherwise.
- Avoid leaking secrets in logs, errors, or test artifacts.

### 1.5 Style Guide (Required)
This section defines repository style expectations and can be extended over time.

#### Comments
- Add comments for cohesive logic blocks when intent or tradeoffs are not obvious from code alone.
- Keep comments concise and useful: usually 1 line, up to 2-3 lines for complex sections.
- Start comments with a capital letter.
- Do not end comments with a period.
- Explain what the block does and why that approach is used in this codebase context.

---

## 2) Testing & QA Requirements (Must Follow)

### 2.1 Tests Are Mandatory for Behavior & Edge Cases
- Every non-trivial change must include tests.
- Bug fix = test that fails before the fix and passes after.
- Prefer deterministic tests; avoid timing-based flakiness.

### 2.2 Coverage Expectations
- Ensure strong coverage over:
  - edge cases
  - error handling paths
  - boundary conditions
  - performance-sensitive hot paths (at least via regression tests and/or benchmarks)

### 2.3 QA “Double Check” Pass (Required)
After implementing changes:
- Run the full test suite
- Run linters/formatters
- Confirm no debug output, stray files, or unused artifacts remain
- Verify behavior is unchanged unless explicitly intended

---

## 3) Performance Work (Measured, Not Vibes)

### 3.1 Profiling First
Before “optimizing,” identify bottlenecks with real measurements:
- Prefer Ruby profiling tools appropriate to the stack (sampling profiler, allocation profiler).
- Benchmark relevant functions end-to-end where feasible.

### 3.2 Benchmarks Live Beside the Code
- Add or update benchmarks when making performance claims.
- Benchmarks should be:
  - reproducible
  - documented (how to run)
  - representative of production-like workloads where possible

### 3.3 Avoid Premature Micro-Optimization
- First: algorithmic improvements, data structure choices, unnecessary I/O removal.
- Then: allocation reduction, hot loop tuning, caching with invalidation clarity.
- Only optimize with an explicit bottleneck and a regression guard.

---

## 4) Python Rewrite Baseline (Must Use for Validation)

This Ruby project is a rewrite of a Python codebase (https://github.com/thewhiteh4t/FinalRecon). While this project has long ago reached identical feature/performance parity, and largely risen above its predecessor in terms of performance and features offered at this point, it's important to have this reference point as a historical marker for where the project came from, and as a benchmark for our own project so we understand how we are performing better than the competition.

---

## 5) Repository Hygiene (Clean As You Go)

### 5.1 Remove Dead Artifacts
- After each pass, delete:
  - unused tests
  - obsolete fixtures
  - scratch scripts
  - unused benchmark files
  - redundant helpers
- Confirm removal doesn’t reduce needed coverage or tooling.

### 5.2 Keep the Repo Orderly
- Keep docs current.
- Keep the test suite fast and organized.
- Prefer consistent conventions (paths, naming, structure).

### 5.3 Bundler Cooldown Hygiene
- This project uses Bundler's `cooldown` feature on the public RubyGems source to reduce exposure to freshly published malicious gems after supply-chain incidents.
- Treat the feature as actively evolving until RubyGems/Bundler clearly stabilizes it across Bundler and standalone `gem` workflows.
- In future dependency-hygiene sessions, always investigate the current RubyGems/Bundler cooldown status first, then update the user with findings before changing project policy.
- After the investigation, ask whether to address related hygiene or housekeeping so this remains an intentional recurring maintenance item.
- If the feature has reached a stable or mature state, explicitly say so in the update to the user.
- Emergency bypass for urgent security fixes: `bundle update <gem> --conservative --cooldown 0`.
- Prefer Bundler 4.0.14 or newer for cooldown work because 4.0.14 includes follow-up fixes after the initial 4.0.13 release.

---

## 6) Agent Workflow (OpenCode / CLI-First)

Follow this cycle for each task:

### 6.1 Pre-Flight
1. Read relevant code.
2. Identify the objective:
   - refactor, performance, edge-case fix, or test improvement.
3. Identify risk areas:
   - input boundaries
   - parsing/deserialization
   - filesystem/shell usage
   - auth/session handling (if applicable)
   - concurrency/state

### 6.2 Plan (Short + Concrete)
Write a short plan in the task notes (or output) that includes:
- files to touch
- tests to add/update
- how success will be measured (tests + benchmark/profiling if performance work)
- any security considerations with justification

### 6.3 Execute
- Keep refactors behavior-preserving unless explicitly changing behavior.
- Maintain clean diffs.

### 6.4 Verify (Non-Negotiable)
Run, at minimum:
- full test suite
- linting/formatting if present
- benchmarks if performance-related

### 6.5 Post-Flight Cleanup
- Remove unused artifacts introduced during exploration.
- Ensure there are no temporary files, debug prints, or disabled tests.
- Update docs/bench notes if behavior or performance claims changed.

---

## 7) Secure Coding Guardrails (OWASP-Aware Checklist)

Use this checklist when relevant (not all items apply to all changes):

- **Injection:** Avoid SQL injection, command injection, template injection.
  - Prefer parameterized queries; avoid string interpolation into queries/commands.
- **Broken Access Control:** Validate permissions at boundaries; test negative paths.
- **Cryptographic Failures:** Do not invent crypto; use established libraries/patterns.
- **Insecure Design:** Prefer explicit invariants and constraints; test them.
- **Security Misconfiguration:** Avoid insecure defaults; document required env vars/config.
- **Vulnerable/Outdated Components:** Keep dependencies minimal; document rationale.
- **Identification/Auth Failures:** Avoid leaking auth state; validate session logic.
- **Software/Data Integrity:** Validate inputs; avoid unsafe deserialization.
- **Logging/Monitoring Failures:** Don’t log secrets; ensure errors are actionable but safe.
- **SSRF:** Treat URLs and network destinations as hostile unless allowlisted.

In addition to this, lean on OWASP's entire documentation for Top 10 vulns as well as secure coding best practice when necessary, as the above is not exhaustive.

When a mitigation is added, include a short rationale:
- `# Security: <risk> mitigated by <approach> (cost acceptable because <reason>)`

---

## 8) Output Expectations for the Agent

When delivering changes, include:
- Summary of what changed and why
- Tests added/updated (and what they cover)
- Benchmark/profiling results if performance-related (before/after, same machine/settings)
- Any security-relevant changes with justification
- Any cleanup performed (deleted files, removed dead code)

---

## 9) Practical Defaults

If the repository doesn’t already define these, prefer:
- Stdlib hand-written tests tailored to the situation (or Rspec at most if you need to pull in a dedicated test dependency)
- RuboCop for linting/formatting (Rubocop is implemented through Mise at ~/.local/share/mise/installs/gem-rubocop/1.84.1/bin/rubocop)
- A `bench/` directory with documented scripts

### RuboCop Governance Baseline

- Treat RuboCop as architectural governance, not just syntax cleanup
- Keep `Lint`, `Security`, and `Naming` cops strict as hard quality gates
- Use `Metrics` cops as readability guardrails, calibrated for CLI orchestration code so methods/modules remain cohesive without helper over-fragmentation
- Do not use broad excludes or TODO debt files to suppress structural issues
- Avoid inline cop disables unless truly necessary; when used, add a concise rationale tied to maintainability/performance/security tradeoff
- Keep refactors RuboCop-clean under the curated repo config, without changing cop rules to fit a single patch

### Homebrew Formula Governance

- Formula files under `Formula/` follow Homebrew formula style and are intentionally excluded from project RuboCop checks.
- Validate formula changes with `ruby -c Formula/<name>.rb` plus `brew audit --strict --formula <name>` from a tap context that points at the changed formula.
- Prefer Homebrew audit findings over RuboCop style preferences for formula files, especially quote style and formula DSL conventions.
- Do not use `rubocop Formula/<name>.rb` as a formula quality gate; if checking exclusions directly, pass `--force-exclusion`.
- If local `brew audit` reads a stale tapped formula instead of the workspace file, update or retap the local tap before treating audit output as authoritative.

Do not add new tooling unless it’s justified, lightweight, and consistent with the existing ecosystem of the repo.

---

## 10) Final Note

This codebase is already functional. The goal is to continue making it:
- more robust (edge cases + tests)
- more maintainable (clean, idiomatic Ruby)
- faster (measured improvements)
while staying realistically secure (OWASP-aligned, justified mitigations only).

Operate like a careful, fast senior engineer with a profiler in one hand and a test suite in the other
