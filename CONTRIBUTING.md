# Contributing to Nokizaru

Thanks for your interest in contributing.

Nokizaru is a fast, modular web reconnaissance CLI focused on practical web
pentest and bug bounty workflows. It is a single statically-distributable Crystal
binary built from the standard library only: zero runtime shards, with its data
embedded at compile time. Contributions are accepted through GitHub issues and
pull requests, then reviewed by the maintainer.

## Maintainer Merge Policy

- This repository integrates changes into `main` using **squash merges only**.
- Keep PRs scoped to one logical change so the squashed commit stays clean.

## Ground Rules

- Keep discussions technical, reproducible, and professional.
- Keep pull requests focused and easy to review.
- Do not include secrets, private target data, or non-public scan results in
  issues or PRs.
- Do not submit code intended for unauthorized or illegal activity.
- Do not add a runtime shard: the shipped binary is standard-library only (see
  `AGENTS.md`).

## Contribution Flow

1. Open an issue (bug, enhancement, provider request), or comment on an existing one.
2. Fork the repository and create a branch from `main`.
3. Implement your change in clear, reviewable commits.
4. Add or update specs and run the gate during development.
5. Update `README.md` if behavior or flags changed.
6. Before opening a PR, clean test-only scaffolding from your branch.
7. Open a pull request and complete the PR checklist.

## Local Setup

Source development uses Crystal 1.21.1 and `just`, both pinned by `mise`.

```bash
git clone https://github.com/hakkuri01/nokizaru.git
cd nokizaru
mise trust && mise install   # pins crystal + just
just setup                   # builds the pinned Ameba (the only networked recipe)
just verify                  # the canonical gate
```

`just verify` runs, stopping at the first failure: `crystal tool format --check`,
`bin/ameba`, `crystal spec`, `crystal tool unreachable --check`, and a release
build. It never touches the network; test fixtures bind `127.0.0.1` only.

### Nix

On `aarch64-linux` or `x86_64-linux`, the root flake pins nixpkgs with Crystal
1.21.1 and provides Crystal, shards, `just`, OpenSSL for TLS fixtures, and Ameba
at the commit in `shard.lock`:

```bash
nix develop
just verify
exit
nix build
nix flake check
```

Entering the shell installs the Nix-built pinned linter into `bin/ameba`, so
`just setup` is not needed. Nix may fetch inputs, toolchain binaries, and Ameba
during setup; `just verify` and the sandboxed checks run offline. `nix flake check`
runs the canonical gate plus the release package and CLI smoke tests (help,
version, invalid invocation, config creation, and private key-store writes).
`nix build` runs the spec suite and a version check, as the nixpkgs build
would, then produces `result/bin/nokizaru`, with embedded data and no runtime
shards; Nix manages its linked system libraries.

After changing the Ameba pin in `shard.lock`, update its source hash in
`flake.nix` and rerun the checks. To evaluate both supported architectures without
building the non-native one, use `nix flake check --all-systems --no-build`.

## Coding Expectations

- Follow idiomatic Crystal and the conventions in `AGENTS.md` (40-line methods,
  300/500-line files, at most 4 parameters, minimal comments, no em dashes).
- Standard library first; a new dependency is the maintainer's decision.
- All code follows the OWASP secure-coding guidance in `AGENTS.md`: external
  response data is untrusted and is sanitized before it reaches the terminal or
  the filesystem; validate at the boundary and refuse, do not repair; never log or
  echo API keys or supplied header values.
- Run the complexity (Big O) builder step on every change: name what grows, meet
  the path's target, and leave a count-based spec that fails if it regresses.
- Keep module boundaries clear and avoid unrelated refactors in a feature PR.
- Handle provider and network failures gracefully, with bounded timeouts and retries.

## Style Guide

The repository style guide lives in `AGENTS.md`. Comments are minimal: present
only where intent is not clear from the code, one line where possible, no ending
period on one-liners, and never an em dash.

## Module Integration Checklist

When adding or modifying a scan module or a subdomain provider:

- Add it under `src/nokizaru/modules/...` with a typed result struct.
- Wire it into the CLI and module orchestration with clear naming.
- Support optional credentials through the existing key patterns.
- Validate parsing against malformed, partial, and hostile responses, with caps.
- Keep timeout and rate behavior conservative; do not add requests per candidate.
- Ensure output normalization and dedup behavior remain correct.
- Update user documentation and the key docs.

## Pull Request Expectations

A solid PR includes:

- What changed and why.
- Validation evidence (specs and reproducible command output).
- Security impact, if any, and the mitigation rationale.
- Performance impact, if relevant, with the count-based numbers.
- Any documentation updates.

## Bug Report Quality

Please include:

- Nokizaru version (`nokizaru --version`).
- Platform (OS and architecture) and installation method.
- Full command used (redacted).
- Reproduction steps.
- Expected vs actual behavior.
- Relevant logs/output (redacted).

## Security Vulnerabilities

Do not open public issues for vulnerabilities. Use GitHub's private vulnerability
reporting flow (see `SECURITY.md`).
