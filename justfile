# Nokizaru task runner. `just verify` is the canonical gate: it stops at the
# first failure and never touches the network. `just setup` is the only
# networked recipe (it fetches Ameba's locked source once). `mise install` pins
# crystal + just first.

crystal := env_var_or_default("CRYSTAL", "crystal")
shards := env_var_or_default("SHARDS", "shards")

# List the recipes.
_default:
    @just --list

# The canonical gate: format, lint, spec, unreachable, build (first failure wins).
[group('check')]
verify: format-check lint spec unreachable build

# Build bin/ameba from Ameba's locked source. The only networked recipe; rerun when shard.lock changes.
[group('setup')]
setup:
    {{shards}} install --frozen --skip-postinstall
    mkdir -p bin
    {{crystal}} build lib/ameba/bin/ameba.cr -o bin/ameba

# Run the specs in random order.
[group('check')]
spec:
    {{crystal}} spec --order random

# Lint with the pinned Ameba. Requires `just setup` to have built bin/ameba, keeping the gate offline.
[group('check')]
lint:
    @test -x bin/ameba || { echo "Ameba is missing: run 'just setup'" >&2; exit 1; }
    bin/ameba

# Format src and spec in place.
[group('format')]
format:
    {{crystal}} tool format src spec

# Check formatting without writing.
[group('check')]
format-check:
    {{crystal}} tool format --check src spec

# Fail on any method called by neither the binary nor a spec. The engine is a
# spec-covered library the CLI and TUI consume; a landed-and-tested method counts
# as live before its consumer lands.
[group('check')]
unreachable:
    printf 'require "./src/nokizaru"\nrequire "./spec/**"\n' | {{crystal}} tool unreachable --check --exclude lib --exclude spec --stdin-filename unreachable.cr

# Build bin/nokizaru (release), always rebuilt: a gate that passes on a stale binary is not a gate.
[group('build')]
build:
    mkdir -p bin
    {{crystal}} build --release src/nokizaru.cr -o bin/nokizaru

# Remove bin/.
[group('build')]
clean:
    rm -rf bin
