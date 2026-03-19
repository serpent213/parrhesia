#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'EOF'
usage:
  ./scripts/run_bench_update.sh [machine_id|all]
  ./scripts/run_bench_update.sh --machine <machine_id|all> [--run-id <run_id>]
  ./scripts/run_bench_update.sh --list

Regenerates bench/chart.svg and updates the benchmark table in README.md
from collected data in bench/history.jsonl.

Options:
  --machine <id|all>    Filter by machine_id (default: hostname -s)
  --run-id <id>         Filter to an exact run_id
  --history-file <path> History JSONL file (default: bench/history.jsonl)
  --list                List available machines and runs, then exit
  -h, --help
EOF
}

BENCH_DIR="$ROOT_DIR/bench"
HISTORY_FILE="$BENCH_DIR/history.jsonl"
CHART_FILE="$BENCH_DIR/chart.svg"
GNUPLOT_TEMPLATE="$BENCH_DIR/chart.gnuplot"
README_FILE="$ROOT_DIR/README.md"

MACHINE_ID="$(hostname -s)"
RUN_ID=""
LIST_ONLY=0
POSITIONAL_MACHINE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --machine)
      MACHINE_ID="$2"
      shift 2
      ;;
    --run-id)
      RUN_ID="$2"
      shift 2
      ;;
    --history-file)
      HISTORY_FILE="$2"
      shift 2
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    *)
      if [[ -z "$POSITIONAL_MACHINE" ]]; then
        POSITIONAL_MACHINE="$1"
        shift
      else
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -n "$POSITIONAL_MACHINE" ]]; then
  MACHINE_ID="$POSITIONAL_MACHINE"
fi

if [[ ! -f "$HISTORY_FILE" ]]; then
  echo "Error: No history file found at $HISTORY_FILE" >&2
  echo "Run ./scripts/run_bench_collect.sh or ./scripts/run_bench_cloud.sh first" >&2
  exit 1
fi

if [[ "$LIST_ONLY" == "1" ]]; then
  node - "$HISTORY_FILE" <<'NODE'
const fs = require("node:fs");

const [, , historyFile] = process.argv;

const entries = fs.readFileSync(historyFile, "utf8")
  .split("\n")
  .filter((l) => l.trim().length > 0)
  .map((l) => JSON.parse(l));

if (entries.length === 0) {
  console.log("No entries in history file.");
  process.exit(0);
}

entries.sort((a, b) => b.timestamp.localeCompare(a.timestamp));

const machines = new Map();
for (const e of entries) {
  const machineId = e.machine_id || "unknown";
  const prev = machines.get(machineId);
  if (!prev) {
    machines.set(machineId, { count: 1, latest: e });
  } else {
    prev.count += 1;
    if ((e.timestamp || "") > (prev.latest.timestamp || "")) prev.latest = e;
  }
}

console.log("Machines:");
console.log("  machine_id                          entries  latest_timestamp         latest_tag");
for (const [machineId, info] of [...machines.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
  const id = machineId.padEnd(34, " ");
  const count = String(info.count).padStart(7, " ");
  const ts = (info.latest.timestamp || "").padEnd(24, " ");
  const tag = info.latest.git_tag || "";
  console.log(`  ${id} ${count}  ${ts} ${tag}`);
}

console.log("\nRuns (newest first):");
console.log("  timestamp                 run_id                               machine_id                 source  git_tag            targets");
for (const e of entries) {
  const ts = (e.timestamp || "").slice(0, 19).padEnd(24, " ");
  const runId = (e.run_id || "").slice(0, 36).padEnd(36, " ");
  const machineId = (e.machine_id || "").slice(0, 24).padEnd(24, " ");
  const source = (e.source?.kind || "").padEnd(6, " ");
  const tag = (e.git_tag || "").slice(0, 16).padEnd(16, " ");
  const targets = (e.bench?.targets || Object.keys(e.servers || {})).join(",");
  console.log(`  ${ts} ${runId} ${machineId} ${source} ${tag} ${targets}`);
}
NODE
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Generating chart (machine=$MACHINE_ID${RUN_ID:+, run_id=$RUN_ID})"

if ! node - "$HISTORY_FILE" "$MACHINE_ID" "$RUN_ID" "$WORK_DIR" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");

const [, , historyFile, machineId, runId, workDir] = process.argv;

function parseSemverTag(tag) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(tag || "");
  return match ? match.slice(1).map(Number) : null;
}

const all = fs.readFileSync(historyFile, "utf8")
  .split("\n")
  .filter((l) => l.trim().length > 0)
  .map((l) => JSON.parse(l));

let selected = all;
if (runId && runId.length > 0) {
  selected = all.filter((e) => e.run_id === runId);
  console.log(`  filtered by run_id: ${runId}`);
} else if (machineId !== "all") {
  selected = all.filter((e) => e.machine_id === machineId);
  console.log(`  filtered to machine: ${machineId}`);
} else {
  console.log("  using all machines");
}

if (selected.length === 0) {
  console.error("  no matching history entries");
  process.exit(1);
}

selected.sort((a, b) => (a.timestamp || "").localeCompare(b.timestamp || ""));

const byTag = new Map();
for (const e of selected) {
  byTag.set(e.git_tag || "untagged", e);
}
const deduped = [...byTag.values()];

deduped.sort((a, b) => {
  const aTag = parseSemverTag(a.git_tag);
  const bTag = parseSemverTag(b.git_tag);

  if (aTag && bTag) {
    return aTag[0] - bTag[0] || aTag[1] - bTag[1] || aTag[2] - bTag[2];
  }

  return (a.git_tag || "").localeCompare(b.git_tag || "", undefined, { numeric: true });
});

const primaryServerNames = new Set(["parrhesia-pg", "parrhesia-memory"]);
const preferredBaselineOrder = ["strfry", "nostr-rs-relay", "nostream", "haven"];

const discoveredBaselines = new Set();
for (const e of deduped) {
  for (const serverName of Object.keys(e.servers || {})) {
    if (!primaryServerNames.has(serverName)) {
      discoveredBaselines.add(serverName);
    }
  }
}

const presentBaselines = [
  ...preferredBaselineOrder.filter((srv) => discoveredBaselines.has(srv)),
  ...[...discoveredBaselines].filter((srv) => !preferredBaselineOrder.includes(srv)).sort((a, b) => a.localeCompare(b)),
];

// --- Colour palette per server: [empty, warm, hot] ---
const serverColours = {
  "parrhesia-pg":     ["#93c5fd", "#3b82f6", "#1e40af"],
  "parrhesia-memory": ["#86efac", "#22c55e", "#166534"],
  "strfry":           ["#fdba74", "#f97316", "#9a3412"],
  "nostr-rs-relay":   ["#fca5a5", "#ef4444", "#991b1b"],
  "nostream":         ["#d8b4fe", "#a855f7", "#6b21a8"],
  "haven":            ["#fde68a", "#eab308", "#854d0e"],
};

const levelStyles = [
  /* empty */ { dt: 3, pt: 6, ps: 0.7, lw: 1.5 },
  /* warm  */ { dt: 2, pt: 8, ps: 0.8, lw: 1.5 },
  /* hot   */ { dt: 1, pt: 7, ps: 1.0, lw: 2 },
];

const levels = ["empty", "warm", "hot"];

const shortLabel = {
  "parrhesia-pg": "pg", "parrhesia-memory": "mem",
  "strfry": "strfry", "nostr-rs-relay": "nostr-rs",
  "nostream": "nostream", "haven": "haven",
};

const allServers = ["parrhesia-pg", "parrhesia-memory", ...presentBaselines];

function isPhased(e) {
  for (const srv of Object.values(e.servers || {})) {
    if (srv.event_empty_tps !== undefined) return true;
  }
  return false;
}

// Build phased key: "event_tps" + "empty" → "event_empty_tps"
function phasedKey(base, level) {
  const idx = base.lastIndexOf("_");
  return `${base.slice(0, idx)}_${level}_${base.slice(idx + 1)}`;
}

// --- Emit linetype definitions (server × level) ---
const plotLines = [];
for (let si = 0; si < allServers.length; si++) {
  const colours = serverColours[allServers[si]] || ["#888888", "#555555", "#222222"];
  for (let li = 0; li < 3; li++) {
    const s = levelStyles[li];
    plotLines.push(
      `set linetype ${si * 3 + li + 1} lc rgb "${colours[li]}" lw ${s.lw} pt ${s.pt} ps ${s.ps} dt ${s.dt}`
    );
  }
}
plotLines.push("");

// Panel definitions — order matches 4x2 grid (left-to-right, top-to-bottom)
const panels = [
  { kind: "simple", key: "echo_tps",       label: "Echo Throughput (TPS) — higher is better",    file: "echo_tps.tsv",       ylabel: "TPS" },
  { kind: "simple", key: "echo_mibs",      label: "Echo Throughput (MiB/s) — higher is better",  file: "echo_mibs.tsv",      ylabel: "MiB/s" },
  { kind: "fill",   base: "event_tps",     label: "Event Throughput (TPS) — higher is better",   file: "event_tps.tsv",      ylabel: "TPS" },
  { kind: "fill",   base: "event_mibs",    label: "Event Throughput (MiB/s) — higher is better", file: "event_mibs.tsv",     ylabel: "MiB/s" },
  { kind: "fill",   base: "req_tps",       label: "Req Throughput (TPS) — higher is better",     file: "req_tps.tsv",        ylabel: "TPS" },
  { kind: "fill",   base: "req_mibs",      label: "Req Throughput (MiB/s) — higher is better",   file: "req_mibs.tsv",       ylabel: "MiB/s" },
  { kind: "simple", key: "connect_avg_ms", label: "Connect Avg Latency (ms) — lower is better",  file: "connect_avg_ms.tsv", ylabel: "ms" },
];

for (const panel of panels) {
  if (panel.kind === "simple") {
    // One column per server
    const header = ["tag", ...allServers.map((s) => shortLabel[s] || s)];
    const rows = [header.join("\t")];
    for (const e of deduped) {
      const row = [e.git_tag || "untagged"];
      for (const srv of allServers) {
        row.push(e.servers?.[srv]?.[panel.key] ?? "NaN");
      }
      rows.push(row.join("\t"));
    }
    fs.writeFileSync(path.join(workDir, panel.file), rows.join("\n") + "\n", "utf8");

    // Plot: one series per server, using its "hot" linetype
    const dataFile = `data_dir."/${panel.file}"`;
    plotLines.push(`set title "${panel.label}"`);
    plotLines.push(`set ylabel "${panel.ylabel}"`);
    const parts = allServers.map((srv, si) => {
      const src = si === 0 ? dataFile : "''";
      const xtic = si === 0 ? ":xtic(1)" : "";
      return `${src} using 0:${si + 2}${xtic} lt ${si * 3 + 3} title "${shortLabel[srv] || srv}"`;
    });
    plotLines.push("plot " + parts.join(", \\\n     "));
    plotLines.push("");

  } else {
    // Three columns per server (empty, warm, hot)
    const header = ["tag"];
    for (const srv of allServers) {
      const sl = shortLabel[srv] || srv;
      for (const lvl of levels) header.push(`${sl}-${lvl}`);
    }
    const rows = [header.join("\t")];
    for (const e of deduped) {
      const row = [e.git_tag || "untagged"];
      const phased = isPhased(e);
      for (const srv of allServers) {
        const d = e.servers?.[srv];
        if (!d) { row.push("NaN", "NaN", "NaN"); continue; }
        if (phased) {
          for (const lvl of levels) row.push(d[phasedKey(panel.base, lvl)] ?? "NaN");
        } else {
          row.push("NaN", d[panel.base] ?? "NaN", "NaN"); // flat → warm only
        }
      }
      rows.push(row.join("\t"));
    }
    fs.writeFileSync(path.join(workDir, panel.file), rows.join("\n") + "\n", "utf8");

    // Plot: three series per server (empty/warm/hot)
    const dataFile = `data_dir."/${panel.file}"`;
    plotLines.push(`set title "${panel.label}"`);
    plotLines.push(`set ylabel "${panel.ylabel}"`);
    const parts = [];
    let first = true;
    for (let si = 0; si < allServers.length; si++) {
      const label = shortLabel[allServers[si]] || allServers[si];
      for (let li = 0; li < 3; li++) {
        const src = first ? dataFile : "''";
        const xtic = first ? ":xtic(1)" : "";
        const col = 2 + si * 3 + li;
        parts.push(`${src} using 0:${col}${xtic} lt ${si * 3 + li + 1} title "${label} (${levels[li]})"`);
        first = false;
      }
    }
    plotLines.push("plot " + parts.join(", \\\n     "));
    plotLines.push("");
  }
}

fs.writeFileSync(path.join(workDir, "plot_commands.gnuplot"), plotLines.join("\n") + "\n", "utf8");

const latestForReadme = [...selected]
  .sort((a, b) => (b.timestamp || "").localeCompare(a.timestamp || ""))
  .find((e) => e.servers?.["parrhesia-pg"] && e.servers?.["parrhesia-memory"]);

if (latestForReadme) {
  fs.writeFileSync(path.join(workDir, "latest_entry.json"), JSON.stringify(latestForReadme), "utf8");
}

console.log(`  selected=${selected.length}, series_tags=${deduped.length}, baselines=${presentBaselines.length}`);
NODE
then
  echo "No matching data for chart/update" >&2
  exit 1
fi

if [[ -f "$WORK_DIR/plot_commands.gnuplot" ]]; then
  gnuplot \
    -e "data_dir='$WORK_DIR'" \
    -e "output_file='$CHART_FILE'" \
    "$GNUPLOT_TEMPLATE"
  echo "  chart written to $CHART_FILE"
else
  echo "  chart generation skipped"
fi

echo "Updating README.md with latest benchmark..."

if [[ ! -f "$WORK_DIR/latest_entry.json" ]]; then
  echo "Warning: no selected entry contains both parrhesia-pg and parrhesia-memory; skipping README table update" >&2
  echo
  echo "Benchmark rendering complete. Files updated:"
  echo "  $CHART_FILE"
  echo
  exit 0
fi

node - "$WORK_DIR/latest_entry.json" "$README_FILE" <<'NODE'
const fs = require("node:fs");

const [, , entryPath, readmePath] = process.argv;
const entry = JSON.parse(fs.readFileSync(entryPath, "utf8"));
const servers = entry.servers || {};

const pg = servers["parrhesia-pg"];
const mem = servers["parrhesia-memory"];

if (!pg || !mem) {
  console.error("Selected entry is missing parrhesia-pg or parrhesia-memory");
  process.exit(1);
}

// Detect phased entries — use hot fill level as headline metric
const phased = pg.event_empty_tps !== undefined;

// For phased entries, resolve "event_tps" → "event_hot_tps" etc.
function resolveKey(key) {
  if (!phased) return key;
  const fillKeys = ["event_tps", "event_mibs", "req_tps", "req_mibs"];
  if (!fillKeys.includes(key)) return key;
  const idx = key.lastIndexOf("_");
  return `${key.slice(0, idx)}_hot_${key.slice(idx + 1)}`;
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
  const num = Number.parseFloat(ratioStr);
  if (!Number.isFinite(num)) return ratioStr;
  const better = lowerIsBetter ? num < 1 : num > 1;
  return better ? `**${ratioStr}**` : ratioStr;
}

const fillNote = phased ? " (hot fill level)" : "";

const metricRows = [
  ["connect avg latency (ms) ↓", "connect_avg_ms", true],
  ["connect max latency (ms) ↓", "connect_max_ms", true],
  ["echo throughput (TPS) ↑", "echo_tps", false],
  ["echo throughput (MiB/s) ↑", "echo_mibs", false],
  [`event throughput (TPS)${fillNote} ↑`, "event_tps", false],
  [`event throughput (MiB/s)${fillNote} ↑`, "event_mibs", false],
  [`req throughput (TPS)${fillNote} ↑`, "req_tps", false],
  [`req throughput (MiB/s)${fillNote} ↑`, "req_mibs", false],
];

const preferredComparisonOrder = ["strfry", "nostr-rs-relay", "nostream", "haven"];
const discoveredComparisons = Object.keys(servers).filter(
  (name) => name !== "parrhesia-pg" && name !== "parrhesia-memory",
);

const comparisonServers = [
  ...preferredComparisonOrder.filter((name) => discoveredComparisons.includes(name)),
  ...discoveredComparisons.filter((name) => !preferredComparisonOrder.includes(name)).sort((a, b) => a.localeCompare(b)),
];

const header = ["metric", "parrhesia-pg", "parrhesia-mem", ...comparisonServers, "mem/pg"];
for (const serverName of comparisonServers) {
  header.push(`${serverName}/pg`);
}

const alignRow = ["---"];
for (let i = 1; i < header.length; i += 1) alignRow.push("---:");

const rows = metricRows.map(([label, key, lowerIsBetter]) => {
  const rk = resolveKey(key);
  const row = [label, toFixed(pg[rk]), toFixed(mem[rk])];

  for (const serverName of comparisonServers) {
    row.push(toFixed(servers?.[serverName]?.[rk]));
  }

  row.push(boldIf(ratio(pg[rk], mem[rk]), lowerIsBetter));

  for (const serverName of comparisonServers) {
    row.push(boldIf(ratio(pg[rk], servers?.[serverName]?.[rk]), lowerIsBetter));
  }

  return row;
});

const tableLines = [
  "| " + header.join(" | ") + " |",
  "| " + alignRow.join(" | ") + " |",
  ...rows.map((r) => "| " + r.join(" | ") + " |"),
];

const readme = fs.readFileSync(readmePath, "utf8");
const lines = readme.split("\n");
const benchIdx = lines.findIndex((l) => /^## Benchmark/.test(l));
if (benchIdx === -1) {
  console.error("Could not find '## Benchmark' section in README.md");
  process.exit(1);
}

let tableStart = -1;
let tableEnd = -1;
for (let i = benchIdx + 1; i < lines.length; i += 1) {
  if (lines[i].startsWith("|")) {
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

const updated = [
  ...lines.slice(0, tableStart),
  ...tableLines,
  ...lines.slice(tableEnd + 1),
].join("\n");

fs.writeFileSync(readmePath, updated, "utf8");
console.log(`  table updated (${tableLines.length} rows)`);
NODE

echo
echo "Benchmark rendering complete. Files updated:"
echo "  $CHART_FILE"
echo "  $README_FILE"
echo
echo "Review with: git diff"
