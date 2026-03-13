#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

export PARRHESIA_NAK_E2E=1

exec ./scripts/run_e2e_suite.sh \
  nak \
  mix test test/parrhesia/e2e/nak_cli_test.exs --no-start --only nak_e2e --timeout 15000
