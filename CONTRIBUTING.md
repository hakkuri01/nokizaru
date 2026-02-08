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
