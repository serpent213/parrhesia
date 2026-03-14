#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Check if the marmot-ts submodule is initialised
if [[ ! -f "$ROOT_DIR/marmot-ts/package.json" ]]; then
  echo "marmot-ts submodule is not initialised." >&2
  if [[ -t 0 ]]; then
    read -rp "Initialise it now? [y/N] " answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      git -C "$ROOT_DIR" submodule update --init marmot-ts
    else
      echo "Skipping marmot e2e tests."
      exit 0
    fi
  else
    echo "Run 'git submodule update --init marmot-ts' to initialise it." >&2
    exit 1
  fi
fi

cd "$ROOT_DIR/marmot-ts"

if [[ ! -d node_modules ]]; then
  npm install --no-audit --no-fund
fi

npm run compile

cd "$ROOT_DIR"
export PARRHESIA_MARMOT_E2E=1

exec ./scripts/run_e2e_suite.sh \
  marmot \
  node --test ./test/marmot_e2e/marmot_client_e2e.test.mjs
