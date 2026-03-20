# Contributing to Nokizaru

Thanks for your interest in contributing.

Nokizaru is a Ruby recon CLI focused on practical web pentest and bug bounty workflows. Contributions are accepted through GitHub issues and pull requests, then reviewed by maintainers.

## Maintainer Merge Policy

- This repository integrates changes into `main` using **squash merges only**.
- Keep PRs scoped to one logical change so the squashed commit remains clean and readable.

## Ground Rules

- Keep discussions technical, reproducible, and professional.
- Keep pull requests focused and easy to review.
- Do not include secrets, private target data, or non-public scan results in issues or PRs.
- Do not submit code intended for unauthorized or illegal activity.

## Contribution Flow

1. Open an issue (bug, enhancement, provider request), or comment on an existing one.
2. Fork the repository and create a branch from `main`.
3. Implement your change in clear, reviewable commits.
4. Add or run tests plus validation evidence during development.
5. Update docs (`README.md`, `man/nokizaru.1`) if behavior or flags changed.
6. Before opening a PR, clean test-only scaffolding from your branch so `main` remains tidy.
7. Open a pull request and complete the PR checklist.

## Benchmark Contribution Contract

Nokizaru benchmarking is designed to optimize both scan speed and quality of surfaced recon data.
If you contribute benchmark-driven changes, follow this contract so results remain comparable and useful.

### What to run

Use the repository benchmark tooling (do not invent ad-hoc scripts) and include the exact commands used.

Recommended baseline commands:

```bash
ruby bench/comprehensive_benchmark_suite.rb --track track_a
ruby bench/bb_live_target_suite.rb --profile canonical --runs 1 --concurrency 5 --no-skip-existing
```

When requested by maintainers, also run:

```bash
ruby bench/bb_live_target_suite.rb --profile canonical --runs 1 --concurrency 5 --no-skip-existing --write-baseline
```

### What to submit in PRs

Do not commit raw benchmark artifacts. Instead, include a concise benchmark report in the PR body with:

- Commit SHA tested
- Commands executed
- Target profile (`canonical`, `fast`, etc.)
- Before vs after summary metrics:
  - pass/warn/fail
  - speed_fail / quality_fail
  - balance_median
- Notable target-level deltas (improved + regressed)
- Any known transient/environmental anomalies (timeouts, DNS issues, upstream rate limits)

Include runner metadata for reproducibility:

- OS + version
- Ruby version
- CPU model / core count
- RAM
- Approximate region/network context

### Data handling and privacy

- `bench/results/` artifacts are ignored and must not be committed.
- Do not post raw logs that may contain cookies, response headers, discovered URLs, or subdomain lists unless redacted.
- Do not benchmark private/non-public targets in this public workflow.
- Never include secrets, API keys, tokens, or local credential material in benchmark evidence.

### Tuning/iteration policy

Benchmark-driven code changes should improve real-world balance, not only one axis.

- Avoid tuning solely for speed if quality drops.
- Avoid tuning solely for quality if runtime becomes unstable.
- Prefer changes validated across multiple runs and, when available, multiple machines.
- Treat one-machine single-run regressions as investigation signals, not automatic ground truth.
- Prioritize fixes in this order:
  1. both speed+quality failures
  2. quality-only failures
  3. speed-only failures

Long-term goal: aggregate results from multiple contributor machines to reduce "works on my machine" bias and improve robustness against web variance over time.

## Local Setup

```bash
git clone https://github.com/hakkuri01/nokizaru.git
cd nokizaru
bundle install
bundle exec ruby bin/nokizaru --help
```

## Coding Expectations

- Follow idiomatic Ruby and existing project conventions.
- All code should follow relevant OWASP Secure Coding guidelines.
- Prefer simple, explicit designs over speculative abstractions.
- Keep module boundaries clear and avoid unrelated refactors in feature PRs.
- Handle provider/network failures gracefully.
- Never log API keys or sensitive values.

## Style Guide

This section defines repository style expectations and may expand over time.

### Comments

- Add comments for cohesive logic blocks where intent or design tradeoffs are not obvious.
- Keep comments concise and practical, typically 1 line and at most 2-3 lines for complex blocks.
- Start comments with a capital letter.
- Do not end comments with a period.
- Explain what the block is doing and why that approach is used in this codebase context.

## Provider Integration Checklist

When adding or modifying providers:

- Add the provider module under `lib/nokizaru/modules/...`.
- Wire it into CLI/module orchestration with clear naming.
- Support optional credentials through existing key patterns.
- Validate parsing paths against malformed/partial responses.
- Keep timeout/rate behavior conservative.
- Ensure output normalization and dedup behavior remain correct.
- Update user documentation and key docs.

## Pull Request Expectations

A solid PR includes:

- What changed and why.
- Validation evidence (tests and/or reproducible command output used during development).
- Security impact (if any) and mitigation rationale.
- Performance impact (if relevant, with numbers).
- Any docs/man page updates.
- Benchmark methodology and command set used (for benchmark-driven changes).
- Before/after speed-quality-balance summary (for benchmark-driven changes).
- Runner metadata (OS/Ruby/CPU/RAM/region) when reporting benchmark data.
- Confirmation that raw `bench/results/` artifacts were not committed.

Note: temporary test scaffolding is acceptable in development, but the final branch should be cleaned before merge in line with this repo's shipping style.

## Bug Report Quality

Please include:

- Nokizaru version
- Ruby version and OS
- Full command used (redacted)
- Reproduction steps
- Expected vs actual behavior
- Relevant logs/output (redacted)

## Security Vulnerabilities

Do not open public issues for vulnerabilities.
Use GitHub's private vulnerability reporting flow (see `SECURITY.md`).
