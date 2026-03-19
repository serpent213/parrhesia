#!/usr/bin/env bash
set -euo pipefail

topic="${1:-}"

if [[ -z "$topic" || "$topic" == "root" || "$topic" == "all" ]]; then
  cat <<'EOF'
Parrhesia command runner

Usage:
  just <group> <subcommand> [args...]
  just help [group]

Command groups:
  e2e <subcommand>              End-to-end harness entrypoints
  bench <subcommand>            Benchmark tasks (local/cloud/history/chart)

Notes:
  - Keep using mix aliases for core project workflows:
      mix setup
      mix test
      mix lint
      mix precommit

Examples:
  just help bench
  just e2e marmot
  just e2e node-sync
  just bench compare
  just bench cloud --clients 3 --runs 3
EOF
  exit 0
fi

if [[ "$topic" == "e2e" ]]; then
  cat <<'EOF'
E2E commands

  just e2e nak                  CLI e2e tests via nak
  just e2e marmot               Marmot client e2e tests
  just e2e node-sync            Local two-node sync harness
  just e2e node-sync-docker     Docker two-node sync harness

Advanced:
  just e2e suite <name> <cmd...>
    -> runs scripts/run_e2e_suite.sh directly
EOF
  exit 0
fi

if [[ "$topic" == "bench" ]]; then
  cat <<'EOF'
Benchmark commands

  just bench compare            Local benchmark comparison table only
  just bench collect            Append run results to bench/history.jsonl
  just bench update             Regenerate chart + README table
  just bench list               List machines/runs from history
  just bench at <git-ref>       Run collect benchmark at git ref
  just bench cloud [args...]    Cloud benchmark wrapper
  just bench cloud-quick        Cloud smoke profile

Cloud tip:
  just bench cloud --yes --datacenter auto
    -> auto-pick cheapest compatible DC and skip interactive confirmation

Cloud defaults:
  targets = parrhesia-pg,parrhesia-memory,strfry,nostr-rs-relay,nostream,haven

Relay-target helpers:
  just bench relay [all|connect|echo|event|req] [nostr-bench-args...]
  just bench relay-strfry [...]
  just bench relay-nostr-rs [...]

Examples:
  just bench compare
  just bench collect
  just bench update --machine all
  just bench at v0.5.0
  just bench cloud --clients 3 --runs 3
  just bench cloud --targets parrhesia-pg,nostream,haven --nostream-ref main
EOF
  exit 0
fi

echo "Unknown help topic: $topic" >&2
echo "Run: just help" >&2
exit 1
