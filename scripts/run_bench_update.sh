#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_bench_update.sh [machine_id]

Regenerates bench/chart.svg and updates the benchmark table in README.md
from collected data in bench/history.jsonl.

Arguments:
  machine_id    Optional. Filter to a specific machine's data.
                Default: current machine (hostname -s)
                Use "all" to include all machines (will use latest entry per tag)

Examples:
  # Update chart for current machine
  ./scripts/run_bench_update.sh

  # Update chart for specific machine
  ./scripts/run_bench_update.sh my-server

  # Update chart using all machines (latest entry per tag wins)
  ./scripts/run_bench_update.sh all
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

# --- Configuration -----------------------------------------------------------

BENCH_DIR="$ROOT_DIR/bench"
HISTORY_FILE="$BENCH_DIR/history.jsonl"
CHART_FILE="$BENCH_DIR/chart.svg"
GNUPLOT_TEMPLATE="$BENCH_DIR/chart.gnuplot"

MACHINE_ID="${1:-$(hostname -s)}"

if [[ ! -f "$HISTORY_FILE" ]]; then
  echo "Error: No history file found at $HISTORY_FILE" >&2
  echo "Run ./scripts/run_bench_collect.sh first to collect benchmark data" >&2
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Generate chart ----------------------------------------------------------

echo "Generating chart for machine: $MACHINE_ID"

node - "$HISTORY_FILE" "$MACHINE_ID" "$WORK_DIR" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [, , historyFile, machineId, workDir] = process.argv;

if (!fs.existsSync(historyFile)) {
  console.log("  no history file, skipping chart generation");
  process.exit(0);
}

const lines = fs.readFileSync(historyFile, "utf8")
  .split("\n")
  .filter(l => l.trim().length > 0)
  .map(l => JSON.parse(l));

// Filter to selected machine(s)
let entries;
if (machineId === "all") {
  entries = lines;
  console.log("  using all machines");
} else {
  entries = lines.filter(e => e.machine_id === machineId);
  console.log("  filtered to machine: " + machineId);
}

if (entries.length === 0) {
  console.log("  no history entries for machine '" + machineId + "', skipping chart");
  process.exit(0);
}

// Sort chronologically, deduplicate by tag (latest wins),
// then order the resulting series by git tag.
entries.sort((a, b) => a.timestamp.localeCompare(b.timestamp));
const byTag = new Map();
for (const e of entries) {
  byTag.set(e.git_tag, e);
}
const deduped = [...byTag.values()];

function parseSemverTag(tag) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(tag);
  return match ? match.slice(1).map(Number) : null;
}

deduped.sort((a, b) => {
  const aTag = parseSemverTag(a.git_tag);
  const bTag = parseSemverTag(b.git_tag);

  if (aTag && bTag) {
    return aTag[0] - bTag[0] || aTag[1] - bTag[1] || aTag[2] - bTag[2];
  }

  return a.git_tag.localeCompare(b.git_tag, undefined, { numeric: true });
});

// Determine which non-parrhesia servers are present
const baselineServerNames = ["strfry", "nostr-rs-relay"];
const presentBaselines = baselineServerNames.filter(srv =>
  deduped.some(e => e.servers[srv])
);

// Metrics to chart
const chartMetrics = [
  { key: "event_tps",      label: "Event Throughput (TPS) — higher is better",    file: "event_tps.tsv",      ylabel: "TPS" },
  { key: "req_tps",        label: "Req Throughput (TPS) — higher is better",      file: "req_tps.tsv",        ylabel: "TPS" },
  { key: "echo_tps",       label: "Echo Throughput (TPS) — higher is better",     file: "echo_tps.tsv",       ylabel: "TPS" },
  { key: "connect_avg_ms", label: "Connect Avg Latency (ms) — lower is better",   file: "connect_avg_ms.tsv", ylabel: "ms"  },
];

// Write per-metric TSV files
for (const cm of chartMetrics) {
  const header = ["tag", "parrhesia-pg", "parrhesia-memory"];
  for (const srv of presentBaselines) header.push(srv);

  const rows = [header.join("\t")];
  for (const e of deduped) {
    const row = [
      e.git_tag,
      e.servers["parrhesia-pg"]?.[cm.key] ?? "NaN",
      e.servers["parrhesia-memory"]?.[cm.key] ?? "NaN",
    ];
    for (const srv of presentBaselines) {
      row.push(e.servers[srv]?.[cm.key] ?? "NaN");
    }
    rows.push(row.join("\t"));
  }

  fs.writeFileSync(path.join(workDir, cm.file), rows.join("\n") + "\n", "utf8");
}

// Generate gnuplot plot commands (handles variable column counts)
const serverLabels = ["parrhesia-pg", "parrhesia-memory"];
for (const srv of presentBaselines) serverLabels.push(srv);

const plotLines = [];
for (const cm of chartMetrics) {
  const dataFile = `data_dir."/${cm.file}"`;
  plotLines.push(`set title "${cm.label}"`);
  plotLines.push(`set ylabel "${cm.ylabel}"`);

  const plotParts = [];
  // Column 2 = parrhesia-pg, 3 = parrhesia-memory, 4+ = baselines
  plotParts.push(`${dataFile} using 0:2:xtic(1) lt 1 title "${serverLabels[0]}"`);
  plotParts.push(`'' using 0:3 lt 2 title "${serverLabels[1]}"`);
  for (let i = 0; i < presentBaselines.length; i++) {
    plotParts.push(`'' using 0:${4 + i} lt ${3 + i} title "${serverLabels[2 + i]}"`);
  }

  plotLines.push("plot " + plotParts.join(", \\\n     "));
  plotLines.push("");
}

fs.writeFileSync(
  path.join(workDir, "plot_commands.gnuplot"),
  plotLines.join("\n") + "\n",
  "utf8"
);

console.log("  " + deduped.length + " tag(s), " + presentBaselines.length + " baseline server(s)");
NODE

if [[ -f "$WORK_DIR/plot_commands.gnuplot" ]]; then
  gnuplot \
    -e "data_dir='$WORK_DIR'" \
    -e "output_file='$CHART_FILE'" \
    "$GNUPLOT_TEMPLATE"
  echo "  chart written to $CHART_FILE"
else
  echo "  chart generation skipped (no data for this machine)"
  exit 0
fi

# --- Update README.md -------------------------------------------------------

echo "Updating README.md with latest benchmark..."

# Find the most recent entry for this machine
LATEST_ENTRY=$(node - "$HISTORY_FILE" "$MACHINE_ID" <<'NODE'
const fs = require("node:fs");
const [, , historyFile, machineId] = process.argv;

const lines = fs.readFileSync(historyFile, "utf8")
  .split("\n")
  .filter(l => l.trim().length > 0)
  .map(l => JSON.parse(l));

let entries;
if (machineId === "all") {
  entries = lines;
} else {
  entries = lines.filter(e => e.machine_id === machineId);
}

if (entries.length === 0) {
  console.error("No entries found for machine: " + machineId);
  process.exit(1);
}

// Get latest entry
entries.sort((a, b) => b.timestamp.localeCompare(a.timestamp));
console.log(JSON.stringify(entries[0]));
NODE
)

if [[ -z "$LATEST_ENTRY" ]]; then
  echo "Warning: Could not find latest entry, skipping README update" >&2
  exit 0
fi

node - "$LATEST_ENTRY" "$ROOT_DIR/README.md" <<'NODE'
const fs = require("node:fs");

const [, , entryJson, readmePath] = process.argv;

const entry = JSON.parse(entryJson);
const servers = entry.servers || {};

const pg = servers["parrhesia-pg"];
const mem = servers["parrhesia-memory"];
const strfry = servers["strfry"];
const nostrRs = servers["nostr-rs-relay"];

if (!pg || !mem) {
  const present = Object.keys(servers).sort().join(", ") || "(none)";
  console.error(
    "Latest benchmark entry must include parrhesia-pg and parrhesia-memory. Present servers: " +
      present
  );
  process.exit(1);
}

function toFixed(v, d = 2) {
  return Number.isFinite(v) ? v.toFixed(d) : "n/a";
}

function ratio(base, other) {
  if (!Number.isFinite(base) || !Number.isFinite(other) || base === 0) return "n/a";
  return (other / base).toFixed(2) + "x";
}

function boldIf(ratioStr, lowerIsBetter) {
  if (ratioStr === "n/a") return ratioStr;
  const num = parseFloat(ratioStr);
  const better = lowerIsBetter ? num < 1 : num > 1;
  return better ? "**" + ratioStr + "**" : ratioStr;
}

const metricRows = [
  ["connect avg latency (ms) ↓", "connect_avg_ms", true],
  ["connect max latency (ms) ↓", "connect_max_ms", true],
  ["echo throughput (TPS) ↑",    "echo_tps",       false],
  ["echo throughput (MiB/s) ↑",  "echo_mibs",      false],
  ["event throughput (TPS) ↑",   "event_tps",      false],
  ["event throughput (MiB/s) ↑", "event_mibs",     false],
  ["req throughput (TPS) ↑",     "req_tps",        false],
  ["req throughput (MiB/s) ↑",   "req_mibs",       false],
];

const hasStrfry = !!strfry;
const hasNostrRs = !!nostrRs;

// Build header
const header = ["metric", "parrhesia-pg", "parrhesia-mem"];
if (hasStrfry) header.push("strfry");
if (hasNostrRs) header.push("nostr-rs-relay");
header.push("mem/pg");
if (hasStrfry) header.push("strfry/pg");
if (hasNostrRs) header.push("nostr-rs/pg");

const alignRow = ["---"];
for (let i = 1; i < header.length; i++) alignRow.push("---:");

const rows = metricRows.map(([label, key, lowerIsBetter]) => {
  const row = [label, toFixed(pg[key]), toFixed(mem[key])];
  if (hasStrfry) row.push(toFixed(strfry[key]));
  if (hasNostrRs) row.push(toFixed(nostrRs[key]));

  row.push(boldIf(ratio(pg[key], mem[key]), lowerIsBetter));
  if (hasStrfry) row.push(boldIf(ratio(pg[key], strfry[key]), lowerIsBetter));
  if (hasNostrRs) row.push(boldIf(ratio(pg[key], nostrRs[key]), lowerIsBetter));

  return row;
});

const tableLines = [
  "| " + header.join(" | ") + " |",
  "| " + alignRow.join(" | ") + " |",
  ...rows.map(r => "| " + r.join(" | ") + " |"),
];

// Replace the first markdown table in the ## Benchmark section
const readme = fs.readFileSync(readmePath, "utf8");
const readmeLines = readme.split("\n");
const benchIdx = readmeLines.findIndex(l => /^## Benchmark/.test(l));
if (benchIdx === -1) {
  console.error("Could not find '## Benchmark' section in README.md");
  process.exit(1);
}

let tableStart = -1;
let tableEnd = -1;
for (let i = benchIdx + 1; i < readmeLines.length; i++) {
  if (readmeLines[i].startsWith("|")) {
    if (tableStart === -1) tableStart = i;
    tableEnd = i;
  } else if (tableStart !== -1) {
    break;
  }
}

if (tableStart === -1) {
  console.error("Could not find markdown table in ## Benchmark section");
  process.exit(1);
}

const before = readmeLines.slice(0, tableStart);
const after = readmeLines.slice(tableEnd + 1);
const updated = [...before, ...tableLines, ...after].join("\n");

fs.writeFileSync(readmePath, updated, "utf8");
console.log("  table updated (" + tableLines.length + " rows)");
NODE

# --- Done ---------------------------------------------------------------------

echo
echo "Benchmark rendering complete. Files updated:"
echo "  $CHART_FILE"
echo "  $ROOT_DIR/README.md"
echo
echo "Review with: git diff"
