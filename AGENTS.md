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

**Default priorities, highest to lowest:**
1. Correctness, including edge cases and test coverage
2. Security, OWASP Top 10-aligned, justified, and not performative
3. Performance, measured and not guessed
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

This section defines repository style expectations and can be extended over time.

#### Comments

- Add comments for cohesive logic blocks when intent or tradeoffs are not obvious from code alone
- Keep comments concise and useful: usually 1 line, up to 2-3 lines for complex sections
- Start comments with a capital letter
- Do not end comments with a period
- Explain what the block does and why that approach is used in this codebase context

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
- performance-sensitive hot paths, at least via regression tests and/or benchmarks

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
- Benchmark relevant functions end-to-end where feasible

### Benchmarks Live Beside The Code

- Add or update benchmarks when making performance claims
- Benchmarks should be reproducible
- Benchmarks should document how to run them
- Benchmarks should be representative of production-like workloads where possible

### Avoid Premature Micro-Optimization

- First: algorithmic improvements, data structure choices, and unnecessary I/O removal
- Then: allocation reduction, hot loop tuning, and caching with invalidation clarity
- Only optimize with an explicit bottleneck and a regression guard

---

## Repository Hygiene

### Remove Dead Artifacts

After each pass, delete unused tests, obsolete fixtures, scratch scripts, unused benchmark files, and redundant helpers.

Confirm removal does not reduce needed coverage or tooling.

### Keep The Repo Orderly

- Keep docs current
- Keep the test suite fast and organized
- Prefer consistent conventions for paths, naming, and structure

### Packaging And Release Hygiene

- Source clones and source tarballs may include contributor files such as tests, benchmarks, docs, and repository metadata
- Runtime packages should stay lean through the gemspec allowlist
- Do not broaden `spec.files` casually; include only runtime files and user-facing documentation needed by installed packages
- If Homebrew packaging behavior changes from source-tarball builds to curated release artifacts, verify that the formula and gemspec still agree on the runtime/install boundary

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

### Plan

Write a short, concrete plan in task notes or output that includes:
- files to touch
- tests to add or update
- how success will be measured, including tests and benchmark/profiling if performance work
- any security considerations with justification

### Execute

- Keep refactors behavior-preserving unless explicitly changing behavior
- Maintain clean diffs

### Verify

Run, at minimum:
- full test suite
- linting/formatting if present
- benchmarks if performance-related

### Post-Flight Cleanup

- Remove unused artifacts introduced during exploration
- Ensure there are no temporary files, debug prints, or disabled tests
- Update docs/bench notes if behavior or performance claims changed

---

## Practical Defaults

If the repository does not already define these, prefer:
- stdlib hand-written tests tailored to the situation, or RSpec at most if a dedicated test dependency is needed
- RuboCop for linting/formatting
- a documented `bench/` directory for benchmark scripts

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
- benchmark/profiling results if performance-related, before/after on the same machine/settings
- any security-relevant changes with justification
- any cleanup performed, such as deleted files or removed dead code

---

## Final Note

This codebase is already functional. The goal is to continue making it:
- more robust, with edge cases and tests
- more maintainable, with clean and idiomatic Ruby
- faster, with measured improvements
- realistically secure, with OWASP-aligned and justified mitigations
