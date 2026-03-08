# Comprehensive Benchmarks

This directory now has two benchmark suites:

- `bb_live_target_suite.rb`
  - Curated 50-target live-web suite for benchmark tooling targets, popular public sites, and bug bounty/VDP-heavy targets
  - Supports canonical and fast profiles, sharding, rolling baseline, and resource metrics
- `comprehensive_benchmark_suite.rb`
  - New two-track benchmark suite for performance governance

## Tracks

### Track A (`track_a`) - Deterministic Lab (strict gate)

- Uses local fixture profiles in `bench/config/track_a_targets.json`
- Designed for stable pass/fail benchmarking
- Default behavior is strict (`--strict`)

Start fixture server:

```bash
ruby bench/lab_fixture_server.rb
```

The lab fixture is implemented in Ruby only to keep benchmark behavior aligned with this codebase runtime

Run Track A:

```bash
ruby bench/comprehensive_benchmark_suite.rb --track track_a
```

### Track B (`track_b`) - Live Industry Canary (warning-first)

- Uses public targets in `bench/config/track_b_targets.json`
- Designed for trend visibility under real internet conditions
- Default behavior is non-strict (`--no-strict` implied)
- In non-strict mode, regression threshold misses are warnings, not hard failures

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
- baseline comparison verdicts
- process exit code (`0` pass/warn, `2` strict fail)

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

## BB live target suite

Canonical run:

```bash
ruby bench/bb_live_target_suite.rb --profile canonical --runs 1
```

Fast feedback run:

```bash
ruby bench/bb_live_target_suite.rb --profile fast --concurrency 3 --rolling-window 5
```

Shard across CI runners:

```bash
ruby bench/bb_live_target_suite.rb --profile canonical --shard-count 4 --shard-index 0
```

Common flags:

```bash
--profile canonical|fast
--runs N
--concurrency N
--targets x,y,z
--shard-count N
--shard-index N
--rolling-window N
--write-baseline
--strict / --no-strict
--resource-metrics / --no-resource-metrics
--dry-run
```
