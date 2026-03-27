# Benchmark Suite Guide

This directory contains two complementary benchmark systems:

- `comprehensive_benchmark_suite.rb`
  - Two-track governance suite (deterministic lab + live canary)
  - Used for fast signal on regressions in runtime stability and module quality floors
- `bb_live_target_suite.rb`
  - Full live-environment battery over a curated 104-target set
  - Used for broad real-world validation under diverse edge/WAF/canonicalization behavior

## Tracks

### Track A (`track_a`) - Deterministic Lab (strict gate)

- Uses local fixture profiles in `bench/config/track_a_targets.json`
- Designed for stable, repeatable pass/fail benchmarking
- Default behavior is strict (`--strict`)
- Runtime thresholds are calibrated for current adaptive module behavior while keeping quality/success gates strict

Start fixture server:

```bash
ruby bench/lab_fixture_server.rb
```

The lab fixture is implemented in Ruby to keep deterministic benchmark behavior aligned with Nokizaru runtime changes

Run Track A:

```bash
ruby bench/comprehensive_benchmark_suite.rb --track track_a
```

### Track B (`track_b`) - Live Industry Canary (warning-first)

- Uses public targets in `bench/config/track_b_targets.json`
- Designed for trend visibility under real internet conditions
- Default behavior is non-strict (`--no-strict` implied)
- In non-strict mode, regression threshold misses are warnings, not hard failures
- Baseline keys are aligned to current profile IDs (`live_wikipedia`, `live_badssl`, `live_cloudflare`, `live_httpbin`)

Run Track B:

```bash
ruby bench/comprehensive_benchmark_suite.rb --track track_b
```

## Outputs

Output is written under `bench/results/comprehensive/<track>/`:

- `<track>_manifest_<timestamp>.json`
- `<track>_summary_<timestamp>.md`
- per-job scan exports (`*.json`)
- per-job logs (`logs/*.log`)

The manifest includes:

- raw run results per profile
- aggregated profile metrics (median, p95, elapsed CV, success rate)
- optional resource metrics (median RSS and CPU user/system time)
- baseline comparison verdicts (static file or rolling window)
- process exit code (`0` pass/warn, `2` strict fail)

## Threshold Model

`comprehensive_benchmark_suite` now supports two threshold layers:

- Track defaults from `bench/lib/comprehensive_suite.rb`
- Optional per-profile overrides from each target row (`threshold_overrides`)

Current governance intent:

- Track A: strict quality/success gate, tolerant enough runtime regression window for modern adaptive behavior
- Track B: warning-first trend detection under internet variability

## Post-run evidence review (required)

Benchmark verdicts are only the first gate. After every run, review emitted recon evidence from live target exports to decide whether module output is actionable or noisy.

Focus review on modules with the most user-visible performance and quality impact:

- crawler
- directory enum
- wayback

Recommended review loop:

1. Run the suite (`track_a`, `track_b`, and `bb_live_target_suite` profile needed for the cycle)
2. Open the latest manifest and identify outliers:
   - very high directory candidate counts with very low `directory_prioritized_ratio`
   - crawler runs with low `crawler_total_unique` or saturated `crawler_high_signal_count`
   - wayback runs with large counts that do not improve actionable paths/findings
3. Inspect exported per-target JSON for those outliers and label outputs as:
   - actionable
   - mixed
   - mostly false positives
4. Convert labels into tuning tasks for Nokizaru modules (not just benchmark thresholds)
5. Re-run and compare against previous manifest snapshots

This keeps the suite useful as a data collection system for product tuning, not only as a binary pass/fail gate

## Baseline management

Default baseline file:

- `bench/config/baselines/default.json`

Override baseline path:

```bash
ruby bench/comprehensive_benchmark_suite.rb --track track_a --baseline /path/to/baseline.json
```

Write baseline from current run:

```bash
ruby bench/comprehensive_benchmark_suite.rb --track track_a --runs 5 --write-baseline
```

## Useful flags

```bash
--runs N             # runs per profile
--concurrency N      # concurrent profiles
--timeout S          # command timeout seconds
--targets PATH       # override target config
--baseline PATH      # override baseline file
--strict / --no-strict
--resource-metrics / --no-resource-metrics
--rolling-window N   # use last N manifests as rolling baseline
--write-baseline     # update baseline medians/p95 from current run
--dry-run            # print commands only
```

Recommended governance loop:

1. Track A strict run
2. Track B non-strict run
3. Review manifests/summaries + outlier profile exports
4. Update baseline snapshots only when behavior changes are intentional and validated

## BB Live Target Suite

Canonical run:

```bash
ruby bench/bb_live_target_suite.rb --profile canonical --runs 1
```

Canonical defaults to the `stable` tier for governance-style regression gating

Fast full-battery run (104 targets):

```bash
ruby bench/bb_live_target_suite.rb --profile fast --runs 1 --rolling-window 5 --concurrency 5
```

Fast defaults to the `full` tier for broad observability and trend tracking

Shard across CI runners:

```bash
ruby bench/bb_live_target_suite.rb --profile canonical --shard-count 4 --shard-index 0
```

Common flags:

```bash
--profile canonical|fast
--tier stable|full
--runs N
--concurrency N
--targets x,y,z
--shard-count N
--shard-index N
--rolling-window N
--write-baseline
--skip-existing
--no-skip-existing  # default
--strict / --no-strict
--resource-metrics / --no-resource-metrics
--dry-run
```
