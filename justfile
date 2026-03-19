set shell := ["bash", "-euo", "pipefail", "-c"]
set script-interpreter := ["bash", "-euo", "pipefail"]

repo_root := justfile_directory()

# Show curated command help (same as `just help`).
default:
  @just help

# Show top-level or topic-specific help.
help topic="":
  @cd "{{repo_root}}" && ./scripts/just_help.sh "{{topic}}"

# Raw e2e harness commands.
[script]
e2e subcommand="help" *args:
  cd "{{repo_root}}"
  subcommand="{{subcommand}}"

  if [[ -z "$subcommand" || "$subcommand" == "help" ]]; then
    just help e2e
  elif [[ "$subcommand" == "nak" ]]; then
    ./scripts/run_nak_e2e.sh {{args}}
  elif [[ "$subcommand" == "marmot" ]]; then
    ./scripts/run_marmot_e2e.sh {{args}}
  elif [[ "$subcommand" == "node-sync" ]]; then
    ./scripts/run_node_sync_e2e.sh {{args}}
  elif [[ "$subcommand" == "node-sync-docker" ]]; then
    ./scripts/run_node_sync_docker_e2e.sh {{args}}
  elif [[ "$subcommand" == "suite" ]]; then
    if [[ -z "{{args}}" ]]; then
      echo "usage: just e2e suite <suite-name> <command> [args...]" >&2
      exit 1
    fi
    ./scripts/run_e2e_suite.sh {{args}}
  else
    echo "Unknown e2e subcommand: $subcommand" >&2
    just help e2e
    exit 1
  fi

# Benchmark flows (local/cloud/history + direct relay targets).
[script]
bench subcommand="help" *args:
  cd "{{repo_root}}"
  subcommand="{{subcommand}}"

  if [[ -z "$subcommand" || "$subcommand" == "help" ]]; then
    just help bench
  elif [[ "$subcommand" == "compare" ]]; then
    ./scripts/run_bench_compare.sh {{args}}
  elif [[ "$subcommand" == "collect" ]]; then
    ./scripts/run_bench_collect.sh {{args}}
  elif [[ "$subcommand" == "update" ]]; then
    ./scripts/run_bench_update.sh {{args}}
  elif [[ "$subcommand" == "list" ]]; then
    ./scripts/run_bench_update.sh --list {{args}}
  elif [[ "$subcommand" == "at" ]]; then
    if [[ -z "{{args}}" ]]; then
      echo "usage: just bench at <git-ref>" >&2
      exit 1
    fi
    ./scripts/run_bench_at_ref.sh {{args}}
  elif [[ "$subcommand" == "cloud" ]]; then
    ./scripts/run_bench_cloud.sh {{args}}
  elif [[ "$subcommand" == "cloud-quick" ]]; then
    ./scripts/run_bench_cloud.sh --quick {{args}}
  elif [[ "$subcommand" == "relay" ]]; then
    ./scripts/run_nostr_bench.sh {{args}}
  elif [[ "$subcommand" == "relay-strfry" ]]; then
    ./scripts/run_nostr_bench_strfry.sh {{args}}
  elif [[ "$subcommand" == "relay-nostr-rs" ]]; then
    ./scripts/run_nostr_bench_nostr_rs_relay.sh {{args}}
  else
    echo "Unknown bench subcommand: $subcommand" >&2
    just help bench
    exit 1
  fi
