#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
