#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");

const DEFAULT_TARGETS = ["parrhesia-pg", "parrhesia-memory", "strfry", "nostr-rs-relay"];

const DEFAULTS = {
  datacenter: "fsn1-dc14",
  serverType: "cx23",
  clientType: "cx23",
  imageBase: "ubuntu-24.04",
  clients: 3,
  runs: 3,
  targets: DEFAULT_TARGETS,
  historyFile: "bench/history.jsonl",
  artifactsDir: "bench/cloud_artifacts",
  gitRef: "HEAD",
  parrhesiaImage: null,
  postgresImage: "postgres:17",
  strfryImage: "ghcr.io/hoytech/strfry:latest",
  nostrRsImage: "scsibug/nostr-rs-relay:latest",
  keep: false,
  bench: {
    connectCount: 200,
    connectRate: 100,
    echoCount: 100,
    echoRate: 50,
    echoSize: 512,
    eventCount: 100,
    eventRate: 50,
    reqCount: 100,
    reqRate: 50,
    reqLimit: 10,
    keepaliveSeconds: 5,
  },
};

function usage() {
  console.log(`usage:
  node scripts/cloud_bench_orchestrate.mjs [options]

Creates one server node + N client nodes on Hetzner Cloud, runs nostr-bench in
parallel from clients against selected relay targets, stores raw client logs in
bench/cloud_artifacts/<run_id>/, and appends metadata + pointers to
bench/history.jsonl.

Options:
  --datacenter <name>          (default: ${DEFAULTS.datacenter})
  --server-type <name>         (default: ${DEFAULTS.serverType})
  --client-type <name>         (default: ${DEFAULTS.clientType})
  --image-base <name>          (default: ${DEFAULTS.imageBase})
  --clients <n>                (default: ${DEFAULTS.clients})
  --runs <n>                   (default: ${DEFAULTS.runs})
  --targets <csv>              (default: ${DEFAULT_TARGETS.join(",")})

  Source selection (choose one style):
  --parrhesia-image <image>    Use remote image tag directly (e.g. ghcr.io/...)
  --git-ref <ref>              Build local nix docker archive from git ref (default: HEAD)

  Images for comparison targets:
  --postgres-image <image>     (default: ${DEFAULTS.postgresImage})
  --strfry-image <image>       (default: ${DEFAULTS.strfryImage})
  --nostr-rs-image <image>     (default: ${DEFAULTS.nostrRsImage})

  Benchmark knobs:
  --connect-count <n>          (default: ${DEFAULTS.bench.connectCount})
  --connect-rate <n>           (default: ${DEFAULTS.bench.connectRate})
  --echo-count <n>             (default: ${DEFAULTS.bench.echoCount})
  --echo-rate <n>              (default: ${DEFAULTS.bench.echoRate})
  --echo-size <n>              (default: ${DEFAULTS.bench.echoSize})
  --event-count <n>            (default: ${DEFAULTS.bench.eventCount})
  --event-rate <n>             (default: ${DEFAULTS.bench.eventRate})
  --req-count <n>              (default: ${DEFAULTS.bench.reqCount})
  --req-rate <n>               (default: ${DEFAULTS.bench.reqRate})
  --req-limit <n>              (default: ${DEFAULTS.bench.reqLimit})
  --keepalive-seconds <n>      (default: ${DEFAULTS.bench.keepaliveSeconds})

  Output + lifecycle:
  --history-file <path>        (default: ${DEFAULTS.historyFile})
  --artifacts-dir <path>       (default: ${DEFAULTS.artifactsDir})
  --keep                       Keep cloud resources (no cleanup)
  -h, --help

Notes:
  - Requires hcloud, ssh, scp, ssh-keygen, git.
  - Requires docker locally to build portable nostr-bench binary.
  - If --parrhesia-image is omitted, requires nix locally.
`);
}

function parseArgs(argv) {
  const opts = JSON.parse(JSON.stringify(DEFAULTS));

  const intOpt = (name, value) => {
    const n = Number(value);
    if (!Number.isInteger(n) || n < 1) {
      throw new Error(`${name} must be a positive integer, got: ${value}`);
    }
    return n;
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case "-h":
      case "--help":
        usage();
        process.exit(0);
        break;
      case "--datacenter":
        opts.datacenter = argv[++i];
        break;
      case "--server-type":
        opts.serverType = argv[++i];
        break;
      case "--client-type":
        opts.clientType = argv[++i];
        break;
      case "--image-base":
        opts.imageBase = argv[++i];
        break;
      case "--clients":
        opts.clients = intOpt(arg, argv[++i]);
        break;
      case "--runs":
        opts.runs = intOpt(arg, argv[++i]);
        break;
      case "--targets":
        opts.targets = argv[++i]
          .split(",")
          .map((s) => s.trim())
          .filter(Boolean);
        break;
      case "--parrhesia-image":
        opts.parrhesiaImage = argv[++i];
        break;
      case "--git-ref":
        opts.gitRef = argv[++i];
        break;
      case "--postgres-image":
        opts.postgresImage = argv[++i];
        break;
      case "--strfry-image":
        opts.strfryImage = argv[++i];
        break;
      case "--nostr-rs-image":
        opts.nostrRsImage = argv[++i];
        break;
      case "--connect-count":
        opts.bench.connectCount = intOpt(arg, argv[++i]);
        break;
      case "--connect-rate":
        opts.bench.connectRate = intOpt(arg, argv[++i]);
        break;
      case "--echo-count":
        opts.bench.echoCount = intOpt(arg, argv[++i]);
        break;
      case "--echo-rate":
        opts.bench.echoRate = intOpt(arg, argv[++i]);
        break;
      case "--echo-size":
        opts.bench.echoSize = intOpt(arg, argv[++i]);
        break;
      case "--event-count":
        opts.bench.eventCount = intOpt(arg, argv[++i]);
        break;
      case "--event-rate":
        opts.bench.eventRate = intOpt(arg, argv[++i]);
        break;
      case "--req-count":
        opts.bench.reqCount = intOpt(arg, argv[++i]);
        break;
      case "--req-rate":
        opts.bench.reqRate = intOpt(arg, argv[++i]);
        break;
      case "--req-limit":
        opts.bench.reqLimit = intOpt(arg, argv[++i]);
        break;
      case "--keepalive-seconds":
        opts.bench.keepaliveSeconds = intOpt(arg, argv[++i]);
        break;
      case "--history-file":
        opts.historyFile = argv[++i];
        break;
      case "--artifacts-dir":
        opts.artifactsDir = argv[++i];
        break;
      case "--keep":
        opts.keep = true;
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!opts.targets.length) {
    throw new Error("--targets must include at least one target");
  }

  for (const t of opts.targets) {
    if (!DEFAULT_TARGETS.includes(t)) {
      throw new Error(`invalid target: ${t} (valid: ${DEFAULT_TARGETS.join(", ")})`);
    }
  }

  return opts;
}

function shellEscape(value) {
  return `'${String(value).replace(/'/g, `'"'"'`)}'`;
}

function commandExists(cmd) {
  const pathEnv = process.env.PATH || "";
  for (const dir of pathEnv.split(":")) {
    if (!dir) continue;
    const full = path.join(dir, cmd);
    try {
      fs.accessSync(full, fs.constants.X_OK);
      return true;
    } catch {
      // ignore
    }
  }
  return false;
}

function runCommand(command, args = [], options = {}) {
  const { cwd = ROOT_DIR, env = process.env, stdio = "pipe" } = options;

  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, stdio });

    let stdout = "";
    let stderr = "";

    if (child.stdout) {
      child.stdout.on("data", (chunk) => {
        stdout += chunk.toString();
      });
    }

    if (child.stderr) {
      child.stderr.on("data", (chunk) => {
        stderr += chunk.toString();
      });
    }

    child.on("error", (error) => {
      reject(error);
    });

    child.on("close", (code) => {
      if (code === 0) {
        resolve({ code, stdout, stderr });
      } else {
        const error = new Error(
          `Command failed (${code}): ${command} ${args.map((a) => shellEscape(a)).join(" ")}`,
        );
        error.code = code;
        error.stdout = stdout;
        error.stderr = stderr;
        reject(error);
      }
    });
  });
}

async function sshExec(hostIp, keyPath, remoteCommand, options = {}) {
  return runCommand(
    "ssh",
    [
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "BatchMode=yes",
      "-o",
      "ConnectTimeout=8",
      "-i",
      keyPath,
      `root@${hostIp}`,
      remoteCommand,
    ],
    options,
  );
}

async function scpToHost(hostIp, keyPath, localPath, remotePath) {
  await runCommand("scp", [
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-i",
    keyPath,
    localPath,
    `root@${hostIp}:${remotePath}`,
  ]);
}

async function waitForSsh(hostIp, keyPath, attempts = 60) {
  for (let i = 1; i <= attempts; i += 1) {
    try {
      await sshExec(hostIp, keyPath, "echo ready >/dev/null");
      return;
    } catch {
      await new Promise((r) => setTimeout(r, 2000));
    }
  }
  throw new Error(`SSH not ready after ${attempts} attempts: ${hostIp}`);
}

async function ensureLocalPrereqs(opts) {
  const required = ["hcloud", "ssh", "scp", "ssh-keygen", "git", "docker", "file"];
  const needsParrhesia = opts.targets.includes("parrhesia-pg") || opts.targets.includes("parrhesia-memory");

  if (needsParrhesia && !opts.parrhesiaImage) {
    required.push("nix");
  }

  for (const cmd of required) {
    if (!commandExists(cmd)) {
      throw new Error(`Required command not found in PATH: ${cmd}`);
    }
  }
}

async function buildNostrBenchBinary(tmpDir) {
  const srcDir = path.join(tmpDir, "nostr-bench-src");
  console.log("[local] cloning nostr-bench source...");
  await runCommand("git", ["clone", "--depth", "1", "https://github.com/rnostr/nostr-bench.git", srcDir], {
    stdio: "inherit",
  });

  let binaryPath = path.join(srcDir, "target", "x86_64-unknown-linux-musl", "release", "nostr-bench");
  let buildMode = "nix-musl-static";

  console.log("[local] building nostr-bench (attempt static musl via nix run cargo)...");
  let staticOk = false;

  if (commandExists("nix")) {
    try {
      await runCommand(
        "nix",
        ["run", "nixpkgs#cargo", "--", "build", "--release", "--target", "x86_64-unknown-linux-musl"],
        { cwd: srcDir, stdio: "inherit" },
      );

      const fileOut = await runCommand("file", [binaryPath]);
      staticOk = fileOut.stdout.includes("statically linked");
    } catch {
      staticOk = false;
    }
  }

  if (!staticOk) {
    buildMode = "docker-glibc-portable";
    binaryPath = path.join(srcDir, "target", "release", "nostr-bench");

    console.log("[local] static build unavailable, building portable glibc binary in rust:1-bookworm...");

    await runCommand(
      "docker",
      [
        "run",
        "--rm",
        "-v",
        `${srcDir}:/src`,
        "-w",
        "/src",
        "rust:1-bookworm",
        "bash",
        "-lc",
        "export PATH=/usr/local/cargo/bin:$PATH; apt-get update -qq >/dev/null; apt-get install -y -qq pkg-config build-essential >/dev/null; cargo build --release",
      ],
      { stdio: "inherit" },
    );

    const fileOut = await runCommand("file", [binaryPath]);
    if (!(fileOut.stdout.includes("/lib64/ld-linux-x86-64.so.2") || fileOut.stdout.includes("statically linked"))) {
      throw new Error(`Built nostr-bench binary does not look portable: ${fileOut.stdout.trim()}`);
    }
  }

  const outPath = path.join(tmpDir, "nostr-bench");
  fs.copyFileSync(binaryPath, outPath);
  fs.chmodSync(outPath, 0o755);

  const fileOut = await runCommand("file", [outPath]);
  console.log(`[local] nostr-bench ready (${buildMode}): ${outPath}`);
  console.log(`[local] ${fileOut.stdout.trim()}`);

  return { path: outPath, buildMode };
}

async function buildParrhesiaArchiveIfNeeded(opts, tmpDir) {
  if (opts.parrhesiaImage) {
    return {
      mode: "remote-image",
      image: opts.parrhesiaImage,
      archivePath: null,
      gitRef: null,
      gitCommit: null,
    };
  }

  const resolved = (await runCommand("git", ["rev-parse", "--verify", opts.gitRef], { cwd: ROOT_DIR })).stdout.trim();

  let buildDir = ROOT_DIR;
  let worktreeDir = null;

  if (opts.gitRef !== "HEAD") {
    worktreeDir = path.join(tmpDir, "parrhesia-worktree");
    console.log(`[local] creating temporary worktree for ${opts.gitRef}...`);
    await runCommand("git", ["worktree", "add", "--detach", worktreeDir, opts.gitRef], {
      cwd: ROOT_DIR,
      stdio: "inherit",
    });
    buildDir = worktreeDir;
  }

  try {
    console.log(`[local] building parrhesia docker archive via nix at ${opts.gitRef}...`);
    const archivePath = (
      await runCommand("nix", ["build", ".#dockerImage", "--print-out-paths", "--no-link"], {
        cwd: buildDir,
      })
    ).stdout.trim();

    if (!archivePath) {
      throw new Error("nix build did not return an archive path");
    }

    return {
      mode: "local-git-ref",
      image: "parrhesia:latest",
      archivePath,
      gitRef: opts.gitRef,
      gitCommit: resolved,
    };
  } finally {
    if (worktreeDir) {
      await runCommand("git", ["worktree", "remove", "--force", worktreeDir], {
        cwd: ROOT_DIR,
      }).catch(() => {
        // ignore
      });
    }
  }
}

function makeServerScript() {
  return `#!/usr/bin/env bash
set -euo pipefail

PARRHESIA_IMAGE="\${PARRHESIA_IMAGE:-parrhesia:latest}"
POSTGRES_IMAGE="\${POSTGRES_IMAGE:-postgres:17}"
STRFRY_IMAGE="\${STRFRY_IMAGE:-ghcr.io/hoytech/strfry:latest}"
NOSTR_RS_IMAGE="\${NOSTR_RS_IMAGE:-scsibug/nostr-rs-relay:latest}"

cleanup_containers() {
  docker rm -f parrhesia pg strfry nostr-rs >/dev/null 2>&1 || true
}

wait_http() {
  local url="\$1"
  local timeout="\${2:-60}"
  local log_container="\${3:-}"

  for _ in \$(seq 1 "\$timeout"); do
    if curl -fsS "\$url" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  if [[ -n "\$log_container" ]]; then
    docker logs --tail 200 "\$log_container" >&2 || true
  fi

  echo "Timed out waiting for HTTP endpoint: \$url" >&2
  return 1
}

wait_pg() {
  local timeout="\${1:-90}"
  for _ in \$(seq 1 "\$timeout"); do
    if docker exec pg pg_isready -U parrhesia -d parrhesia >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail 200 pg >&2 || true
  echo "Timed out waiting for Postgres" >&2
  return 1
}

wait_port() {
  local port="\$1"
  local timeout="\${2:-60}"
  local log_container="\${3:-}"

  for _ in \$(seq 1 "\$timeout"); do
    if ss -ltn | grep -q ":\${port} "; then
      return 0
    fi
    sleep 1
  done

  if [[ -n "\$log_container" ]]; then
    docker logs --tail 200 "\$log_container" >&2 || true
  fi

  echo "Timed out waiting for port: \$port" >&2
  return 1
}

common_parrhesia_env=()
common_parrhesia_env+=( -e PARRHESIA_ENABLE_EXPIRATION_WORKER=0 )
common_parrhesia_env+=( -e PARRHESIA_ENABLE_PARTITION_RETENTION_WORKER=0 )
common_parrhesia_env+=( -e PARRHESIA_PUBLIC_MAX_CONNECTIONS=infinity )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_FRAME_BYTES=16777216 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_EVENT_BYTES=4194304 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_FILTERS_PER_REQ=1024 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_FILTER_LIMIT=100000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_TAGS_PER_EVENT=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_TAG_VALUES_PER_FILTER=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_IP_MAX_EVENT_INGEST_PER_WINDOW=1000000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_RELAY_MAX_EVENT_INGEST_PER_WINDOW=1000000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_SUBSCRIPTIONS_PER_CONNECTION=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_EVENT_FUTURE_SKEW_SECONDS=31536000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_EVENT_INGEST_PER_WINDOW=1000000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_AUTH_MAX_AGE_SECONDS=31536000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_OUTBOUND_QUEUE=65536 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_OUTBOUND_DRAIN_BATCH_SIZE=4096 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_PAYLOAD_BYTES=1048576 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_SESSIONS_PER_CONNECTION=256 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_TOTAL_SESSIONS=100000 )
common_parrhesia_env+=( -e PARRHESIA_LIMITS_MAX_NEGENTROPY_ITEMS_PER_SESSION=1000000 )

cmd="\${1:-}"
if [[ -z "\$cmd" ]]; then
  echo "usage: cloud-bench-server.sh <start-parrhesia-pg|start-parrhesia-memory|start-strfry|start-nostr-rs-relay|cleanup>" >&2
  exit 1
fi

case "\$cmd" in
  start-parrhesia-pg)
    cleanup_containers
    docker network create benchnet >/dev/null 2>&1 || true

    docker run -d --name pg --network benchnet \
      -e POSTGRES_DB=parrhesia \
      -e POSTGRES_USER=parrhesia \
      -e POSTGRES_PASSWORD=parrhesia \
      "\$POSTGRES_IMAGE" >/dev/null

    wait_pg 90

    docker run --rm --network benchnet \
      -e DATABASE_URL=ecto://parrhesia:parrhesia@pg:5432/parrhesia \
      "\$PARRHESIA_IMAGE" \
      eval "Parrhesia.Release.migrate()"

    docker run -d --name parrhesia --network benchnet \
      -p 4413:4413 \
      -e DATABASE_URL=ecto://parrhesia:parrhesia@pg:5432/parrhesia \
      -e POOL_SIZE=20 \
      "\${common_parrhesia_env[@]}" \
      "\$PARRHESIA_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  start-parrhesia-memory)
    cleanup_containers

    docker run -d --name parrhesia \
      -p 4413:4413 \
      -e PARRHESIA_STORAGE_BACKEND=memory \
      -e PARRHESIA_MODERATION_CACHE_ENABLED=0 \
      "\${common_parrhesia_env[@]}" \
      "\$PARRHESIA_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  start-strfry)
    cleanup_containers

    mkdir -p /root/strfry-data/strfry
    cat > /root/strfry.conf <<'EOF'
# generated by cloud bench script
db = "/data/strfry"
relay {
  bind = "0.0.0.0"
  port = 7777
  nofiles = 131072
}
EOF

    docker run -d --name strfry \
      -p 7777:7777 \
      -v /root/strfry.conf:/etc/strfry.conf:ro \
      -v /root/strfry-data:/data \
      "\$STRFRY_IMAGE" \
      --config /etc/strfry.conf relay >/dev/null

    wait_port 7777 60 strfry
    ;;

  start-nostr-rs-relay)
    cleanup_containers

    cat > /root/nostr-rs.toml <<'EOF'
[database]
engine = "sqlite"

[network]
ip = "0.0.0.0"
port = 8080
EOF

    docker run -d --name nostr-rs \
      -p 8080:8080 \
      -v /root/nostr-rs.toml:/usr/src/app/config.toml:ro \
      "\$NOSTR_RS_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:8080/" 60 nostr-rs
    ;;

  cleanup)
    cleanup_containers
    ;;

  *)
    echo "unknown command: \$cmd" >&2
    exit 1
    ;;
esac
`;
}

function makeClientScript() {
  return `#!/usr/bin/env bash
set -euo pipefail

relay_url="\${1:-}"
if [[ -z "\$relay_url" ]]; then
  echo "usage: cloud-bench-client.sh <relay-url>" >&2
  exit 1
fi

bench_bin="\${NOSTR_BENCH_BIN:-/usr/local/bin/nostr-bench}"

echo "==> nostr-bench connect \${relay_url}"
"\$bench_bin" connect --json \
  -c "\${PARRHESIA_BENCH_CONNECT_COUNT:-200}" \
  -r "\${PARRHESIA_BENCH_CONNECT_RATE:-100}" \
  -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
  "\${relay_url}"

echo
echo "==> nostr-bench echo \${relay_url}"
"\$bench_bin" echo --json \
  -c "\${PARRHESIA_BENCH_ECHO_COUNT:-100}" \
  -r "\${PARRHESIA_BENCH_ECHO_RATE:-50}" \
  -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
  --size "\${PARRHESIA_BENCH_ECHO_SIZE:-512}" \
  "\${relay_url}"

echo
echo "==> nostr-bench event \${relay_url}"
"\$bench_bin" event --json \
  -c "\${PARRHESIA_BENCH_EVENT_COUNT:-100}" \
  -r "\${PARRHESIA_BENCH_EVENT_RATE:-50}" \
  -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
  "\${relay_url}"

echo
echo "==> nostr-bench req \${relay_url}"
"\$bench_bin" req --json \
  -c "\${PARRHESIA_BENCH_REQ_COUNT:-100}" \
  -r "\${PARRHESIA_BENCH_REQ_RATE:-50}" \
  -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
  --limit "\${PARRHESIA_BENCH_REQ_LIMIT:-10}" \
  "\${relay_url}"
`;
}

function parseNostrBenchSections(output) {
  const lines = output.split(/\r?\n/);
  let section = null;
  const parsed = {};

  for (const lineRaw of lines) {
    const line = lineRaw.trim();
    const header = line.match(/^==>\s+nostr-bench\s+(connect|echo|event|req)\s+/);
    if (header) {
      section = header[1];
      continue;
    }

    if (!line.startsWith("{")) continue;

    try {
      const json = JSON.parse(line);
      if (section) {
        parsed[section] = json;
      }
    } catch {
      // ignore noisy non-json lines
    }
  }

  return parsed;
}

function mean(values) {
  const valid = values.filter((v) => Number.isFinite(v));
  if (valid.length === 0) return NaN;
  return valid.reduce((a, b) => a + b, 0) / valid.length;
}

function metricFromSections(sections) {
  const connect = sections?.connect?.connect_stats?.success_time || {};
  const echo = sections?.echo || {};
  const event = sections?.event || {};
  const req = sections?.req || {};

  return {
    connect_avg_ms: Number(connect.avg ?? NaN),
    connect_max_ms: Number(connect.max ?? NaN),
    echo_tps: Number(echo.tps ?? NaN),
    echo_mibs: Number(echo.size ?? NaN),
    event_tps: Number(event.tps ?? NaN),
    event_mibs: Number(event.size ?? NaN),
    req_tps: Number(req.tps ?? NaN),
    req_mibs: Number(req.size ?? NaN),
  };
}

function summariseServersFromResults(results) {
  const byServer = new Map();

  for (const runEntry of results) {
    const serverName = runEntry.target;
    if (!byServer.has(serverName)) {
      byServer.set(serverName, []);
    }

    const samples = byServer.get(serverName);
    for (const clientResult of runEntry.clients || []) {
      if (clientResult.status !== "ok") continue;
      samples.push(metricFromSections(clientResult.sections || {}));
    }
  }

  const metricKeys = [
    "connect_avg_ms",
    "connect_max_ms",
    "echo_tps",
    "echo_mibs",
    "event_tps",
    "event_mibs",
    "req_tps",
    "req_mibs",
  ];

  const out = {};
  for (const [serverName, samples] of byServer.entries()) {
    const summary = {};
    for (const key of metricKeys) {
      summary[key] = mean(samples.map((s) => s[key]));
    }
    out[serverName] = summary;
  }

  return out;
}

async function tryCommandStdout(command, args = [], options = {}) {
  try {
    const res = await runCommand(command, args, options);
    return res.stdout.trim();
  } catch {
    return "";
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  await ensureLocalPrereqs(opts);

  const timestamp = new Date().toISOString();
  const runId = `cloudbench-${timestamp.replace(/[:.]/g, "-")}-${Math.floor(Math.random() * 100000)}`;

  const detectedGitTag = (await tryCommandStdout("git", ["describe", "--tags", "--abbrev=0"], {
    cwd: ROOT_DIR,
  })) || "untagged";
  const detectedGitCommit = await tryCommandStdout("git", ["rev-parse", "--short=7", "HEAD"], {
    cwd: ROOT_DIR,
  });

  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "parrhesia-cloud-bench-"));
  const localServerScriptPath = path.join(tmpDir, "cloud-bench-server.sh");
  const localClientScriptPath = path.join(tmpDir, "cloud-bench-client.sh");

  fs.writeFileSync(localServerScriptPath, makeServerScript(), "utf8");
  fs.writeFileSync(localClientScriptPath, makeClientScript(), "utf8");
  fs.chmodSync(localServerScriptPath, 0o755);
  fs.chmodSync(localClientScriptPath, 0o755);

  const artifactsRoot = path.resolve(ROOT_DIR, opts.artifactsDir);
  const artifactsDir = path.join(artifactsRoot, runId);
  fs.mkdirSync(artifactsDir, { recursive: true });

  const historyFile = path.resolve(ROOT_DIR, opts.historyFile);
  fs.mkdirSync(path.dirname(historyFile), { recursive: true });

  console.log(`[run] ${runId}`);
  console.log("[phase] local preparation");

  const nostrBench = await buildNostrBenchBinary(tmpDir);
  const needsParrhesia = opts.targets.includes("parrhesia-pg") || opts.targets.includes("parrhesia-memory");
  const parrhesiaSource = needsParrhesia
    ? await buildParrhesiaArchiveIfNeeded(opts, tmpDir)
    : {
        mode: "not-needed",
        image: opts.parrhesiaImage,
        archivePath: null,
        gitRef: null,
        gitCommit: null,
      };

  const keyName = `${runId}-ssh`;
  const keyPath = path.join(tmpDir, "id_ed25519");
  const keyPubPath = `${keyPath}.pub`;

  const createdServers = [];
  let sshKeyCreated = false;

  const cleanup = async () => {
    if (opts.keep) {
      console.log("[cleanup] --keep set, skipping cloud cleanup");
      return;
    }

    if (createdServers.length > 0) {
      console.log("[cleanup] deleting servers...");
      await Promise.all(
        createdServers.map((name) =>
          runCommand("hcloud", ["server", "delete", name], { stdio: "inherit" }).catch(() => {
            // ignore cleanup failures
          }),
        ),
      );
    }

    if (sshKeyCreated) {
      console.log("[cleanup] deleting ssh key...");
      await runCommand("hcloud", ["ssh-key", "delete", keyName], { stdio: "inherit" }).catch(() => {
        // ignore cleanup failures
      });
    }
  };

  try {
    console.log("[phase] create ssh credentials");
    await runCommand("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", keyPath, "-C", keyName], {
      stdio: "inherit",
    });

    await runCommand("hcloud", ["ssh-key", "create", "--name", keyName, "--public-key-from-file", keyPubPath], {
      stdio: "inherit",
    });
    sshKeyCreated = true;

    console.log("[phase] create cloud servers in parallel");

    const serverName = `${runId}-server`;
    const clientNames = Array.from({ length: opts.clients }, (_, i) => `${runId}-client-${i + 1}`);

    const createOne = (name, role, type) =>
      runCommand(
        "hcloud",
        [
          "server",
          "create",
          "--name",
          name,
          "--type",
          type,
          "--datacenter",
          opts.datacenter,
          "--image",
          opts.imageBase,
          "--ssh-key",
          keyName,
          "--label",
          `bench_run=${runId}`,
          "--label",
          `bench_role=${role}`,
          "-o",
          "json",
        ],
        { stdio: "pipe" },
      ).then((res) => JSON.parse(res.stdout));

    const [serverCreate, ...clientCreates] = await Promise.all([
      createOne(serverName, "server", opts.serverType),
      ...clientNames.map((name) => createOne(name, "client", opts.clientType)),
    ]);

    createdServers.push(serverName, ...clientNames);

    const serverIp = serverCreate.server.public_net.ipv4.ip;
    const clientInfos = clientCreates.map((c) => ({
      name: c.server.name,
      id: c.server.id,
      ip: c.server.public_net.ipv4.ip,
    }));

    console.log("[phase] wait for SSH");
    await Promise.all([
      waitForSsh(serverIp, keyPath),
      ...clientInfos.map((client) => waitForSsh(client.ip, keyPath)),
    ]);

    console.log("[phase] install runtime dependencies on nodes");
    const installCmd = [
      "set -euo pipefail",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update -y >/dev/null",
      "apt-get install -y docker.io curl jq >/dev/null",
      "systemctl enable --now docker >/dev/null",
      "docker --version",
    ].join("; ");

    await Promise.all([
      sshExec(serverIp, keyPath, installCmd, { stdio: "inherit" }),
      ...clientInfos.map((client) => sshExec(client.ip, keyPath, installCmd, { stdio: "inherit" })),
    ]);

    console.log("[phase] upload control scripts + nostr-bench binary");

    await scpToHost(serverIp, keyPath, localServerScriptPath, "/root/cloud-bench-server.sh");
    await sshExec(serverIp, keyPath, "chmod +x /root/cloud-bench-server.sh");

    for (const client of clientInfos) {
      await scpToHost(client.ip, keyPath, localClientScriptPath, "/root/cloud-bench-client.sh");
      await scpToHost(client.ip, keyPath, nostrBench.path, "/usr/local/bin/nostr-bench");
      await sshExec(client.ip, keyPath, "chmod +x /root/cloud-bench-client.sh /usr/local/bin/nostr-bench");
    }

    console.log("[phase] server image setup");

    let parrhesiaImageOnServer = parrhesiaSource.image;

    if (needsParrhesia) {
      if (parrhesiaSource.archivePath) {
        console.log("[server] uploading parrhesia docker archive...");
        await scpToHost(serverIp, keyPath, parrhesiaSource.archivePath, "/root/parrhesia.tar.gz");
        await sshExec(serverIp, keyPath, "docker load -i /root/parrhesia.tar.gz", { stdio: "inherit" });
        parrhesiaImageOnServer = "parrhesia:latest";
      } else {
        console.log(`[server] pulling parrhesia image ${parrhesiaImageOnServer}...`);
        await sshExec(serverIp, keyPath, `docker pull ${shellEscape(parrhesiaImageOnServer)}`, {
          stdio: "inherit",
        });
      }
    }

    console.log("[server] pre-pulling comparison images...");
    for (const image of [opts.postgresImage, opts.strfryImage, opts.nostrRsImage]) {
      await sshExec(serverIp, keyPath, `docker pull ${shellEscape(image)}`, { stdio: "inherit" });
    }

    const serverDescribe = JSON.parse(
      (await runCommand("hcloud", ["server", "describe", serverName, "-o", "json"])).stdout,
    );
    const clientDescribes = await Promise.all(
      clientInfos.map(async (c) =>
        JSON.parse((await runCommand("hcloud", ["server", "describe", c.name, "-o", "json"])).stdout),
      ),
    );

    const versions = {
      nostr_bench: (
        await sshExec(clientInfos[0].ip, keyPath, "/usr/local/bin/nostr-bench --version")
      ).stdout.trim(),
    };

    const startCommands = {
      "parrhesia-pg": "start-parrhesia-pg",
      "parrhesia-memory": "start-parrhesia-memory",
      strfry: "start-strfry",
      "nostr-rs-relay": "start-nostr-rs-relay",
    };

    const relayUrls = {
      "parrhesia-pg": `ws://${serverIp}:4413/relay`,
      "parrhesia-memory": `ws://${serverIp}:4413/relay`,
      strfry: `ws://${serverIp}:7777`,
      "nostr-rs-relay": `ws://${serverIp}:8080`,
    };

    const results = [];

    console.log("[phase] benchmark execution");

    for (let runIndex = 1; runIndex <= opts.runs; runIndex += 1) {
      for (const target of opts.targets) {
        console.log(`[bench] run ${runIndex}/${opts.runs} target=${target}`);

        const serverEnvPrefix = [
          `PARRHESIA_IMAGE=${shellEscape(parrhesiaImageOnServer || "parrhesia:latest")}`,
          `POSTGRES_IMAGE=${shellEscape(opts.postgresImage)}`,
          `STRFRY_IMAGE=${shellEscape(opts.strfryImage)}`,
          `NOSTR_RS_IMAGE=${shellEscape(opts.nostrRsImage)}`,
        ].join(" ");

        await sshExec(
          serverIp,
          keyPath,
          `${serverEnvPrefix} /root/cloud-bench-server.sh ${shellEscape(startCommands[target])}`,
          { stdio: "inherit" },
        );

        const relayUrl = relayUrls[target];
        const runTargetDir = path.join(artifactsDir, target, `run-${runIndex}`);
        fs.mkdirSync(runTargetDir, { recursive: true });

        const benchEnvPrefix = [
          `PARRHESIA_BENCH_CONNECT_COUNT=${opts.bench.connectCount}`,
          `PARRHESIA_BENCH_CONNECT_RATE=${opts.bench.connectRate}`,
          `PARRHESIA_BENCH_ECHO_COUNT=${opts.bench.echoCount}`,
          `PARRHESIA_BENCH_ECHO_RATE=${opts.bench.echoRate}`,
          `PARRHESIA_BENCH_ECHO_SIZE=${opts.bench.echoSize}`,
          `PARRHESIA_BENCH_EVENT_COUNT=${opts.bench.eventCount}`,
          `PARRHESIA_BENCH_EVENT_RATE=${opts.bench.eventRate}`,
          `PARRHESIA_BENCH_REQ_COUNT=${opts.bench.reqCount}`,
          `PARRHESIA_BENCH_REQ_RATE=${opts.bench.reqRate}`,
          `PARRHESIA_BENCH_REQ_LIMIT=${opts.bench.reqLimit}`,
          `PARRHESIA_BENCH_KEEPALIVE_SECONDS=${opts.bench.keepaliveSeconds}`,
        ].join(" ");

        const clientRunResults = await Promise.all(
          clientInfos.map(async (client) => {
            const startedAt = new Date().toISOString();
            const startMs = Date.now();
            const stdoutPath = path.join(runTargetDir, `${client.name}.stdout.log`);
            const stderrPath = path.join(runTargetDir, `${client.name}.stderr.log`);

            try {
              const benchRes = await sshExec(
                client.ip,
                keyPath,
                `${benchEnvPrefix} /root/cloud-bench-client.sh ${shellEscape(relayUrl)}`,
              );

              fs.writeFileSync(stdoutPath, benchRes.stdout, "utf8");
              fs.writeFileSync(stderrPath, benchRes.stderr, "utf8");

              return {
                client_name: client.name,
                client_ip: client.ip,
                status: "ok",
                started_at: startedAt,
                finished_at: new Date().toISOString(),
                duration_ms: Date.now() - startMs,
                stdout_path: path.relative(ROOT_DIR, stdoutPath),
                stderr_path: path.relative(ROOT_DIR, stderrPath),
                sections: parseNostrBenchSections(benchRes.stdout),
              };
            } catch (error) {
              const out = error.stdout || "";
              const err = error.stderr || String(error);
              fs.writeFileSync(stdoutPath, out, "utf8");
              fs.writeFileSync(stderrPath, err, "utf8");

              return {
                client_name: client.name,
                client_ip: client.ip,
                status: "error",
                started_at: startedAt,
                finished_at: new Date().toISOString(),
                duration_ms: Date.now() - startMs,
                stdout_path: path.relative(ROOT_DIR, stdoutPath),
                stderr_path: path.relative(ROOT_DIR, stderrPath),
                error: String(error.message || error),
                sections: parseNostrBenchSections(out),
              };
            }
          }),
        );

        results.push({
          run: runIndex,
          target,
          relay_url: relayUrl,
          clients: clientRunResults,
        });

        const failed = clientRunResults.filter((r) => r.status !== "ok");
        if (failed.length > 0) {
          throw new Error(
            `Client benchmark failed for target=${target}, run=${runIndex}: ${failed
              .map((f) => f.client_name)
              .join(", ")}`,
          );
        }
      }
    }

    console.log("[phase] final server cleanup (containers)");
    await sshExec(serverIp, keyPath, "/root/cloud-bench-server.sh cleanup");

    const gitTag = detectedGitTag || "untagged";
    const gitCommit = parrhesiaSource.gitCommit || detectedGitCommit || "unknown";
    const servers = summariseServersFromResults(results);

    const entry = {
      schema_version: 2,
      timestamp,
      run_id: runId,
      machine_id: os.hostname(),
      git_tag: gitTag,
      git_commit: gitCommit,
      runs: opts.runs,
      source: {
        kind: "cloud",
        mode: parrhesiaSource.mode,
        parrhesia_image: parrhesiaImageOnServer,
        git_ref: parrhesiaSource.gitRef,
        git_tag: gitTag,
        git_commit: gitCommit,
      },
      infra: {
        provider: "hcloud",
        datacenter: opts.datacenter,
        server_type: opts.serverType,
        client_type: opts.clientType,
        image_base: opts.imageBase,
        clients: opts.clients,
      },
      bench: {
        runs: opts.runs,
        targets: opts.targets,
        ...opts.bench,
      },
      versions,
      servers,
      artifacts_dir: path.relative(ROOT_DIR, artifactsDir),
      hcloud: {
        server: serverDescribe,
        clients: clientDescribes,
      },
      results,
    };

    fs.appendFileSync(historyFile, `${JSON.stringify(entry)}\n`, "utf8");

    console.log("[done] benchmark complete");
    console.log(`[done] history appended: ${path.relative(ROOT_DIR, historyFile)}`);
    console.log(`[done] artifacts: ${path.relative(ROOT_DIR, artifactsDir)}`);
    if (opts.keep) {
      console.log(`[done] resources kept. server=${serverName} clients=${clientNames.join(",")}`);
      console.log(`[done] ssh key kept: ${keyName}`);
    }
  } finally {
    await cleanup();
  }
}

main().catch((error) => {
  console.error("[error]", error?.message || error);
  if (error?.stderr) {
    console.error(error.stderr);
  }
  process.exit(1);
});
