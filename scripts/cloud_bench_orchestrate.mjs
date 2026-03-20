#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

import {
  parseNostrBenchSections,
  summariseServersFromResults,
  countEventsWritten,
} from "./cloud_bench_results.mjs";

import {
  installMonitoring,
  collectMetrics,
  stopMonitoring,
} from "./cloud_bench_monitoring.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");

const DEFAULT_TARGETS = [
  "parrhesia-pg",
  "parrhesia-memory",
  "strfry",
  "nostr-rs-relay",
  "nostream",
  // "haven", // disabled by default: Haven rejects generic nostr-bench event seeding (auth/whitelist/WoT policies)
];
const ESTIMATE_WINDOW_MINUTES = 30;
const ESTIMATE_WINDOW_HOURS = ESTIMATE_WINDOW_MINUTES / 60;
const ESTIMATE_WINDOW_LABEL = `${ESTIMATE_WINDOW_MINUTES}m`;
const BENCH_BUILD_DIR = path.join(ROOT_DIR, "_build", "bench");
const NOSTR_BENCH_SUBMODULE_DIR = path.join(ROOT_DIR, "nix", "nostr-bench");
const NOSTREAM_REDIS_IMAGE = "redis:7.0.5-alpine3.16";
const SEED_TOLERANCE_RATIO = 0.01;
const SEED_MAX_ROUNDS = 8;
const SEED_ROUND_DEFICIT_RATIO = 0.2;
const SEED_KEEPALIVE_SECONDS = 10;
const SEED_EVENTS_PER_CONNECTION_FALLBACK = 3;
const PHASE_PREP_OFFSET_MINUTES = 3;

const DEFAULTS = {
  datacenter: "fsn1-dc14",
  serverType: "ccx43",
  clientType: "cpx31",
  imageBase: "ubuntu-24.04",
  clients: 3,
  runs: 5,
  targets: DEFAULT_TARGETS,
  historyFile: "bench/history.jsonl",
  artifactsDir: "bench/cloud_artifacts",
  gitRef: "HEAD",
  parrhesiaImage: null,
  postgresImage: "postgres:18",
  strfryImage: "ghcr.io/hoytech/strfry:latest",
  nostrRsImage: "scsibug/nostr-rs-relay:latest",
  nostreamRepo: "https://github.com/Cameri/nostream.git",
  nostreamRef: "main",
  havenImage: "holgerhatgarkeinenode/haven-docker:latest",
  keep: false,
  quick: false,
  monitoring: true,
  yes: false,
  warmEvents: 25000,
  hotEvents: 250000,
  bench: {
    connectCount: 3000,
    connectRate: 1500,
    echoCount: 3000,
    echoRate: 1500,
    echoSize: 512,
    eventCount: 5000,
    eventRate: 2000,
    reqCount: 3000,
    reqRate: 1500,
    reqLimit: 50,
    keepaliveSeconds: 10,
    threads: 0,
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
  --datacenter <name|auto>     Initial datacenter selection (default: ${DEFAULTS.datacenter})
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
  --nostream-repo <url>        (default: ${DEFAULTS.nostreamRepo})
  --nostream-ref <ref>         (default: ${DEFAULTS.nostreamRef})
  --haven-image <image>        (default: ${DEFAULTS.havenImage})

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
  --threads <n>                nostr-bench worker threads (0 = auto, default: ${DEFAULTS.bench.threads})

  Phased benchmark:
  --warm-events <n>            DB fill level for warm phase (default: ${DEFAULTS.warmEvents})
  --hot-events <n>             DB fill level for hot phase (default: ${DEFAULTS.hotEvents})
  --quick                      Skip phased benchmarks, run flat connect→echo→event→req

  Output + lifecycle:
  --history-file <path>        (default: ${DEFAULTS.historyFile})
  --artifacts-dir <path>       (default: ${DEFAULTS.artifactsDir})
  --keep                       Keep cloud resources (no cleanup)
  --no-monitoring              Skip Prometheus + node_exporter setup
  --yes                        Skip interactive prompts and proceed immediately
  -h, --help

Notes:
  - Requires hcloud, ssh, scp, ssh-keygen, git.
  - Before provisioning, checks all datacenters for type availability and estimates ${ESTIMATE_WINDOW_LABEL} cost.
  - In interactive terminals, prompts you to pick + confirm the datacenter unless --yes is set.
  - Caches built nostr-bench at _build/bench/nostr-bench and reuses it when valid.
  - Auto-tunes Postgres/Redis/app pool sizing from server RAM + CPU for DB-backed targets.
  - Randomizes target order per run and wipes persisted target data directories on each start.
  - Creates a Hetzner Cloud firewall restricting inbound access to benchmark ports from known IPs only.
  - Handles Ctrl-C / SIGTERM with best-effort cloud cleanup.
  - Tries nix .#nostrBenchStaticX86_64Musl first; falls back to docker-built portable nostr-bench.
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

  const nonNegativeIntOpt = (name, value) => {
    const n = Number(value);
    if (!Number.isInteger(n) || n < 0) {
      throw new Error(`${name} must be a non-negative integer, got: ${value}`);
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
      case "--nostream-repo":
        opts.nostreamRepo = argv[++i];
        break;
      case "--nostream-ref":
        opts.nostreamRef = argv[++i];
        break;
      case "--haven-image":
        opts.havenImage = argv[++i];
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
      case "--threads":
        opts.bench.threads = nonNegativeIntOpt(arg, argv[++i]);
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
      case "--quick":
        opts.quick = true;
        break;
      case "--no-monitoring":
        opts.monitoring = false;
        break;
      case "--yes":
        opts.yes = true;
        break;
      case "--warm-events":
        opts.warmEvents = intOpt(arg, argv[++i]);
        break;
      case "--hot-events":
        opts.hotEvents = intOpt(arg, argv[++i]);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (process.env.PARRHESIA_BENCH_WARM_EVENTS) opts.warmEvents = Number(process.env.PARRHESIA_BENCH_WARM_EVENTS);
  if (process.env.PARRHESIA_BENCH_HOT_EVENTS) opts.hotEvents = Number(process.env.PARRHESIA_BENCH_HOT_EVENTS);
  if (process.env.PARRHESIA_BENCH_THREADS) {
    opts.bench.threads = nonNegativeIntOpt("PARRHESIA_BENCH_THREADS", process.env.PARRHESIA_BENCH_THREADS);
  }
  if (process.env.PARRHESIA_BENCH_QUICK === "1") opts.quick = true;

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

function shuffled(values) {
  const out = [...values];
  for (let i = out.length - 1; i > 0; i -= 1) {
    const j = Math.floor(Math.random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
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
      "LogLevel=ERROR",
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
    "-o",
    "LogLevel=ERROR",
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

function priceForLocation(serverType, locationName, key) {
  const price = serverType.prices?.find((entry) => entry.location === locationName);
  const value = Number(price?.price_hourly?.[key]);
  if (!Number.isFinite(value)) {
    return null;
  }
  return value;
}

function formatEuro(value) {
  if (!Number.isFinite(value)) {
    return "n/a";
  }
  return `€${value.toFixed(4)}`;
}

function createPhaseLogger(prepOffsetMinutes = PHASE_PREP_OFFSET_MINUTES) {
  let phaseZeroMs = null;

  const prefix = () => {
    if (phaseZeroMs === null) {
      return "T+0m";
    }

    const elapsedMinutes = Math.floor((Date.now() - phaseZeroMs) / 60000);
    const sign = elapsedMinutes >= 0 ? "+" : "";
    return `T${sign}${elapsedMinutes}m`;
  };

  return {
    setPrepOffsetNow() {
      phaseZeroMs = Date.now() + prepOffsetMinutes * 60_000;
    },

    setZeroNow() {
      phaseZeroMs = Date.now();
    },

    logPhase(message) {
      console.log(`${prefix()} ${message}`);
    },
  };
}

function compatibleDatacenterChoices(datacenters, serverType, clientType, clientCount) {
  const compatible = [];

  for (const dc of datacenters) {
    const availableIds = dc?.server_types?.available || dc?.server_types?.supported || [];
    if (!availableIds.includes(serverType.id) || !availableIds.includes(clientType.id)) {
      continue;
    }

    const locationName = dc.location?.name;
    const serverGrossHourly = priceForLocation(serverType, locationName, "gross");
    const clientGrossHourly = priceForLocation(clientType, locationName, "gross");
    const serverNetHourly = priceForLocation(serverType, locationName, "net");
    const clientNetHourly = priceForLocation(clientType, locationName, "net");

    const totalGrossHourly =
      Number.isFinite(serverGrossHourly) && Number.isFinite(clientGrossHourly)
        ? serverGrossHourly + clientGrossHourly * clientCount
        : null;

    const totalNetHourly =
      Number.isFinite(serverNetHourly) && Number.isFinite(clientNetHourly)
        ? serverNetHourly + clientNetHourly * clientCount
        : null;

    compatible.push({
      name: dc.name,
      description: dc.description,
      location: {
        name: locationName,
        city: dc.location?.city,
        country: dc.location?.country,
      },
      totalHourly: {
        gross: totalGrossHourly,
        net: totalNetHourly,
      },
      estimatedTotal: {
        gross: Number.isFinite(totalGrossHourly) ? totalGrossHourly * ESTIMATE_WINDOW_HOURS : null,
        net: Number.isFinite(totalNetHourly) ? totalNetHourly * ESTIMATE_WINDOW_HOURS : null,
      },
    });
  }

  compatible.sort((a, b) => {
    const aPrice = Number.isFinite(a.estimatedTotal.gross) ? a.estimatedTotal.gross : Number.POSITIVE_INFINITY;
    const bPrice = Number.isFinite(b.estimatedTotal.gross) ? b.estimatedTotal.gross : Number.POSITIVE_INFINITY;
    if (aPrice !== bPrice) {
      return aPrice - bPrice;
    }
    return a.name.localeCompare(b.name);
  });

  return compatible;
}

function printDatacenterChoices(choices, opts) {
  console.log("[plan] datacenter availability for requested server/client types");
  console.log(
    `[plan] requested: server=${opts.serverType}, client=${opts.clientType}, clients=${opts.clients}, estimate window=${ESTIMATE_WINDOW_LABEL}`,
  );

  choices.forEach((choice, index) => {
    const where = `${choice.location.name} (${choice.location.city}, ${choice.location.country})`;
    console.log(
      `  [${index + 1}] ${choice.name.padEnd(10)} ${where}  ${ESTIMATE_WINDOW_LABEL} est gross=${formatEuro(choice.estimatedTotal.gross)} net=${formatEuro(choice.estimatedTotal.net)}`,
    );
  });
}

function askLine(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    rl.question(prompt, (answer) => {
      rl.close();
      resolve(answer.trim());
    });
  });
}

async function chooseDatacenter(opts) {
  const [dcRes, serverTypeRes] = await Promise.all([
    runCommand("hcloud", ["datacenter", "list", "-o", "json"]),
    runCommand("hcloud", ["server-type", "list", "-o", "json"]),
  ]);

  const datacenters = JSON.parse(dcRes.stdout);
  const serverTypes = JSON.parse(serverTypeRes.stdout);

  const serverType = serverTypes.find((type) => type.name === opts.serverType);
  if (!serverType) {
    throw new Error(`Unknown server type: ${opts.serverType}`);
  }

  const clientType = serverTypes.find((type) => type.name === opts.clientType);
  if (!clientType) {
    throw new Error(`Unknown client type: ${opts.clientType}`);
  }

  const choices = compatibleDatacenterChoices(datacenters, serverType, clientType, opts.clients);

  if (choices.length === 0) {
    throw new Error(
      `No datacenter has both server type ${opts.serverType} and client type ${opts.clientType} available right now`,
    );
  }

  printDatacenterChoices(choices, opts);

  const wantsAutoDatacenter = opts.datacenter === "auto";
  const defaultChoice = wantsAutoDatacenter
    ? choices[0]
    : choices.find((choice) => choice.name === opts.datacenter) || choices[0];

  const nonInteractiveOrYes = !process.stdin.isTTY || !process.stdout.isTTY || opts.yes;

  if (nonInteractiveOrYes) {
    if (!wantsAutoDatacenter && !choices.some((choice) => choice.name === opts.datacenter)) {
      throw new Error(
        `Requested datacenter ${opts.datacenter} is not currently compatible. Compatible: ${choices
          .map((choice) => choice.name)
          .join(", ")}`,
      );
    }

    const modeLabel = opts.yes && process.stdin.isTTY && process.stdout.isTTY
      ? "auto-confirm mode (--yes)"
      : "non-interactive mode";
    const selectionLabel = wantsAutoDatacenter
      ? "auto cheapest compatible datacenter"
      : `requested datacenter ${defaultChoice.name}`;

    console.log(
      `[plan] ${modeLabel}: using ${selectionLabel} (${ESTIMATE_WINDOW_LABEL} est gross=${formatEuro(defaultChoice.estimatedTotal.gross)} net=${formatEuro(defaultChoice.estimatedTotal.net)})`,
    );
    return defaultChoice;
  }

  const defaultIndex = choices.findIndex((choice) => choice.name === defaultChoice.name) + 1;

  let selected = defaultChoice;

  while (true) {
    const response = await askLine(
      `Select datacenter by number or name [default: ${defaultIndex}/${defaultChoice.name}] (or 'abort'): `,
    );

    if (response === "") {
      selected = defaultChoice;
      break;
    }

    const normalized = response.trim().toLowerCase();
    if (["a", "abort", "q", "quit", "n"].includes(normalized)) {
      throw new Error("Aborted by user before provisioning");
    }

    if (/^\d+$/.test(response)) {
      const idx = Number(response);
      if (idx >= 1 && idx <= choices.length) {
        selected = choices[idx - 1];
        break;
      }
    }

    const byName = choices.find((choice) => choice.name.toLowerCase() === normalized);
    if (byName) {
      selected = byName;
      break;
    }

    console.log(`Invalid selection: ${response}`);
  }

  const confirm = await askLine(
    `Provision in ${selected.name} (${ESTIMATE_WINDOW_LABEL} est gross=${formatEuro(selected.estimatedTotal.gross)} net=${formatEuro(selected.estimatedTotal.net)})? [y/N]: `,
  );

  if (!["y", "yes"].includes(confirm.trim().toLowerCase())) {
    throw new Error("Aborted by user before provisioning");
  }

  return selected;
}

async function buildNostrBenchBinary(tmpDir) {
  const cacheDir = BENCH_BUILD_DIR;
  const cachedBinaryPath = path.join(cacheDir, "nostr-bench");
  const cacheMetadataPath = path.join(cacheDir, "nostr-bench.json");

  fs.mkdirSync(cacheDir, { recursive: true });

  if (!fs.existsSync(path.join(NOSTR_BENCH_SUBMODULE_DIR, "Cargo.toml"))) {
    throw new Error(
      `nostr-bench source not found at ${NOSTR_BENCH_SUBMODULE_DIR}. Run: git submodule update --init --recursive nix/nostr-bench`,
    );
  }

  const resolveSourceFingerprint = async () => {
    let revision = "unknown";
    let dirty = false;

    try {
      revision = (await runCommand("git", ["-C", NOSTR_BENCH_SUBMODULE_DIR, "rev-parse", "HEAD"])).stdout.trim();
      dirty = (await runCommand("git", ["-C", NOSTR_BENCH_SUBMODULE_DIR, "status", "--porcelain"])).stdout.trim().length > 0;
    } catch {
      // Fallback for non-git checkouts of the submodule source.
      const lockPath = path.join(NOSTR_BENCH_SUBMODULE_DIR, "Cargo.lock");
      const lockMtime = fs.existsSync(lockPath) ? fs.statSync(lockPath).mtimeMs : 0;
      revision = `mtime-${Math.trunc(lockMtime)}`;
      dirty = false;
    }

    return dirty ? `${revision}-dirty` : revision;
  };

  const sourceFingerprint = await resolveSourceFingerprint();

  const staticLinked = (fileOutput) => fileOutput.includes("statically linked") || fileOutput.includes("static-pie linked");

  const binaryLooksPortable = (fileOutput) =>
    fileOutput.includes("/lib64/ld-linux-x86-64.so.2") || staticLinked(fileOutput);

  const validatePortableBinary = async (binaryPath) => {
    const fileOut = await runCommand("file", [binaryPath]);
    if (!binaryLooksPortable(fileOut.stdout)) {
      throw new Error(`Built nostr-bench binary does not look portable: ${fileOut.stdout.trim()}`);
    }
    return fileOut.stdout.trim();
  };

  const readCacheMetadata = () => {
    if (!fs.existsSync(cacheMetadataPath)) {
      return null;
    }

    try {
      return JSON.parse(fs.readFileSync(cacheMetadataPath, "utf8"));
    } catch {
      return null;
    }
  };

  const writeCacheMetadata = (metadata) => {
    fs.writeFileSync(cacheMetadataPath, `${JSON.stringify(metadata, null, 2)}\n`, "utf8");
  };

  const readVersionIfRunnable = async (binaryPath, fileSummary, phase) => {
    const binaryIsX86_64 = /x86-64|x86_64/i.test(fileSummary);

    if (binaryIsX86_64 && process.arch !== "x64") {
      console.log(
        `[local] skipping nostr-bench --version check (${phase}): host arch ${process.arch} cannot execute x86_64 binary`,
      );
      return "";
    }

    try {
      return (await runCommand(binaryPath, ["--version"])).stdout.trim();
    } catch (error) {
      console.warn(`[local] unable to run nostr-bench --version (${phase}), continuing: ${error.message}`);
      return "";
    }
  };

  const tryReuseCachedBinary = async () => {
    if (!fs.existsSync(cachedBinaryPath)) {
      return null;
    }

    const metadata = readCacheMetadata();
    if (!metadata?.source_fingerprint) {
      console.log("[local] cached nostr-bench has no source fingerprint, rebuilding");
      return null;
    }

    if (metadata.source_fingerprint !== sourceFingerprint) {
      console.log(
        `[local] nostr-bench source changed (${metadata.source_fingerprint} -> ${sourceFingerprint}), rebuilding cache`,
      );
      return null;
    }

    try {
      const fileSummary = await validatePortableBinary(cachedBinaryPath);
      fs.chmodSync(cachedBinaryPath, 0o755);

      const version = await readVersionIfRunnable(cachedBinaryPath, fileSummary, "cache-reuse");

      console.log(`[local] reusing cached nostr-bench: ${cachedBinaryPath}`);
      if (metadata?.build_mode) {
        console.log(`[local] cache metadata: build_mode=${metadata.build_mode}, built_at=${metadata.built_at || "unknown"}`);
      }
      if (version) {
        console.log(`[local] ${version}`);
      }
      console.log(`[local] ${fileSummary}`);

      return { path: cachedBinaryPath, buildMode: "cache-reuse" };
    } catch (error) {
      console.warn(`[local] cached nostr-bench invalid, rebuilding: ${error.message}`);
      return null;
    }
  };

  const cacheAndValidateBinary = async (binaryPath, buildMode) => {
    await validatePortableBinary(binaryPath);

    fs.copyFileSync(binaryPath, cachedBinaryPath);
    fs.chmodSync(cachedBinaryPath, 0o755);

    const copiedFileOut = await runCommand("file", [cachedBinaryPath]);

    const version = await readVersionIfRunnable(cachedBinaryPath, copiedFileOut.stdout.trim(), "post-build");

    writeCacheMetadata({
      build_mode: buildMode,
      built_at: new Date().toISOString(),
      source_fingerprint: sourceFingerprint,
      source_path: path.relative(ROOT_DIR, NOSTR_BENCH_SUBMODULE_DIR),
      binary_path: cachedBinaryPath,
      file_summary: copiedFileOut.stdout.trim(),
      version,
    });

    console.log(`[local] nostr-bench ready (${buildMode}): ${cachedBinaryPath}`);
    if (version) {
      console.log(`[local] ${version}`);
    }
    console.log(`[local] ${copiedFileOut.stdout.trim()}`);

    return { path: cachedBinaryPath, buildMode };
  };

  const cachedBinary = await tryReuseCachedBinary();
  if (cachedBinary) {
    return cachedBinary;
  }

  if (commandExists("nix")) {
    try {
      console.log("[local] building nostr-bench static binary via nix flake output .#nostrBenchStaticX86_64Musl...");

      const nixOut = (
        await runCommand("nix", ["build", ".#nostrBenchStaticX86_64Musl", "--print-out-paths", "--no-link"], {
          cwd: ROOT_DIR,
        })
      ).stdout.trim();

      if (!nixOut) {
        throw new Error("nix build did not return an output path");
      }

      const binaryPath = path.join(nixOut, "bin", "nostr-bench");
      return await cacheAndValidateBinary(binaryPath, "nix-flake-musl-static");
    } catch (error) {
      console.warn(`[local] nix static build unavailable, falling back to docker build: ${error.message}`);
    }
  }

  const srcDir = path.join(tmpDir, "nostr-bench-src");
  console.log(`[local] preparing nostr-bench source from ${path.relative(ROOT_DIR, NOSTR_BENCH_SUBMODULE_DIR)} for docker fallback...`);
  fs.cpSync(NOSTR_BENCH_SUBMODULE_DIR, srcDir, { recursive: true });

  const binaryPath = path.join(srcDir, "target", "release", "nostr-bench");

  console.log("[local] building portable glibc binary in rust:1-bookworm...");

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

  return await cacheAndValidateBinary(binaryPath, "docker-glibc-portable");
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

// Server and client bash scripts are in cloud_bench_server.sh and
// cloud_bench_client.sh (read from disk in main()).

// Server and client bash scripts are in cloud_bench_server.sh and
// cloud_bench_client.sh (read from disk in main()).

function splitCountAcrossClients(total, clients) {
  if (clients <= 0 || total <= 0) return [];
  const base = Math.floor(total / clients);
  const remainder = total % clients;
  return Array.from({ length: clients }, (_, i) => base + (i < remainder ? 1 : 0));
}

async function runClientSeedingRound({
  target,
  phase,
  round,
  deficit,
  clientInfos,
  keyPath,
  relayUrl,
  artifactDir,
  threads,
  seedEventsPerConnection,
  seedKeepaliveSeconds,
}) {
  const benchThreads = Number.isInteger(threads) && threads >= 0 ? threads : 0;
  const clientsForRound = clientInfos.slice(0, Math.min(clientInfos.length, deficit));
  const shares = splitCountAcrossClients(deficit, clientsForRound.length);
  const roundDir = path.join(artifactDir, `round-${round}`);
  fs.mkdirSync(roundDir, { recursive: true });

  const seedResults = await Promise.all(
    clientsForRound.map(async (client, idx) => {
      const desiredEvents = shares[idx] || 0;
      const stdoutPath = path.join(roundDir, `${client.name}.stdout.log`);
      const stderrPath = path.join(roundDir, `${client.name}.stderr.log`);

      if (desiredEvents <= 0) {
        fs.writeFileSync(stdoutPath, "", "utf8");
        fs.writeFileSync(stderrPath, "", "utf8");
        return {
          client_name: client.name,
          client_ip: client.ip,
          status: "skipped",
          desired_events: desiredEvents,
          projected_events: 0,
          acked: 0,
          stdout_path: path.relative(ROOT_DIR, stdoutPath),
          stderr_path: path.relative(ROOT_DIR, stderrPath),
        };
      }

      const eventsPerConnection = Math.max(
        0.1,
        Number(seedEventsPerConnection) || SEED_EVENTS_PER_CONNECTION_FALLBACK,
      );
      const eventConnections = Math.max(1, Math.ceil(desiredEvents / eventsPerConnection));
      const eventKeepalive = Math.max(2, Number(seedKeepaliveSeconds) || SEED_KEEPALIVE_SECONDS);
      const eventRate = Math.max(1, Math.ceil(eventConnections / eventKeepalive));
      const projectedEvents = Math.round(eventConnections * eventsPerConnection);

      const seedEnvPrefix = [
        `PARRHESIA_BENCH_EVENT_COUNT=${eventConnections}`,
        `PARRHESIA_BENCH_EVENT_RATE=${eventRate}`,
        `PARRHESIA_BENCH_KEEPALIVE_SECONDS=${eventKeepalive}`,
        `PARRHESIA_BENCH_THREADS=${benchThreads}`,
      ].join(" ");

      try {
        const benchRes = await sshExec(
          client.ip,
          keyPath,
          `${seedEnvPrefix} /root/cloud-bench-client.sh ${shellEscape(relayUrl)} event`,
        );

        fs.writeFileSync(stdoutPath, benchRes.stdout, "utf8");
        fs.writeFileSync(stderrPath, benchRes.stderr, "utf8");

        const parsed = parseNostrBenchSections(benchRes.stdout);
        const complete = Number(parsed?.event?.message_stats?.complete) || 0;
        const error = Number(parsed?.event?.message_stats?.error) || 0;
        const acked = Math.max(0, complete - error);

        return {
          client_name: client.name,
          client_ip: client.ip,
          status: "ok",
          desired_events: desiredEvents,
          projected_events: projectedEvents,
          event_connections: eventConnections,
          event_rate: eventRate,
          event_keepalive_seconds: eventKeepalive,
          events_per_connection_estimate: eventsPerConnection,
          event_complete: complete,
          event_error: error,
          acked,
          stdout_path: path.relative(ROOT_DIR, stdoutPath),
          stderr_path: path.relative(ROOT_DIR, stderrPath),
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
          desired_events: desiredEvents,
          projected_events: projectedEvents,
          event_connections: eventConnections,
          event_rate: eventRate,
          event_keepalive_seconds: eventKeepalive,
          events_per_connection_estimate: eventsPerConnection,
          acked: 0,
          stdout_path: path.relative(ROOT_DIR, stdoutPath),
          stderr_path: path.relative(ROOT_DIR, stderrPath),
          error: error.message || String(error),
        };
      }
    }),
  );

  const failed = seedResults.filter((r) => r.status === "error");
  if (failed.length > 0) {
    throw new Error(
      `[fill] ${target}:${phase} round ${round} failed on clients: ${failed.map((f) => f.client_name).join(", ")}`,
    );
  }

  const acked = seedResults.reduce((sum, r) => sum + (Number(r.acked) || 0), 0);
  const desired = seedResults.reduce((sum, r) => sum + (Number(r.desired_events) || 0), 0);
  const projected = seedResults.reduce((sum, r) => sum + (Number(r.projected_events) || 0), 0);

  return {
    desired,
    projected,
    acked,
    clients: seedResults,
  };
}

async function fetchServerEventCount({ target, serverIp, keyPath, serverEnvPrefix }) {
  const countableTargets = new Set(["parrhesia-pg", "nostream"]);
  if (!countableTargets.has(target)) return null;

  const countCmd = `count-data-${target}`;

  try {
    const res = await sshExec(
      serverIp,
      keyPath,
      `${serverEnvPrefix} /root/cloud-bench-server.sh ${shellEscape(countCmd)}`,
    );

    const lines = res.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean);

    const numericLine = [...lines].reverse().find((line) => /^\d+$/.test(line));
    if (!numericLine) return null;

    const count = Number(numericLine);
    return Number.isInteger(count) && count >= 0 ? count : null;
  } catch (error) {
    console.warn(`[fill] ${target}: failed to fetch server event count (${error.message || error})`);
    return null;
  }
}

// Ensure the relay has approximately `targetCount` events.
// Uses client-side nostr-bench event seeding in parallel and accepts <=1% drift.
async function smartFill({
  target,
  phase,
  targetCount,
  eventsInDb,
  relayUrl,
  serverIp,
  keyPath,
  clientInfos,
  serverEnvPrefix,
  artifactDir,
  threads,
  seedEventsPerConnection,
  seedKeepaliveSeconds,
  skipFill,
  fetchEventCount,
}) {
  if (targetCount <= 0) return { eventsInDb, seeded: 0, wiped: false, skipped: false };

  if (skipFill) {
    console.log(`[fill] ${target}:${phase}: skipped (target does not support generic event seeding)`);
    return { eventsInDb, seeded: 0, wiped: false, skipped: true };
  }

  let wiped = false;
  if (eventsInDb > targetCount) {
    console.log(`[fill] ${target}: have ${eventsInDb} > ${targetCount}, wiping and reseeding`);
    const wipeCmd = `wipe-data-${target}`;
    await sshExec(serverIp, keyPath, `${serverEnvPrefix} /root/cloud-bench-server.sh ${shellEscape(wipeCmd)}`);
    eventsInDb = 0;
    wiped = true;
  }

  if (typeof fetchEventCount === "function") {
    const authoritative = await fetchEventCount();
    if (Number.isInteger(authoritative) && authoritative >= 0) {
      eventsInDb = authoritative;
    }
  }

  const tolerance = Math.max(1, Math.floor(targetCount * SEED_TOLERANCE_RATIO));
  let deficit = targetCount - eventsInDb;

  if (deficit <= tolerance) {
    console.log(
      `[fill] ${target}: already within tolerance (${eventsInDb}/${targetCount}, tolerance=${tolerance}), skipping`,
    );
    return { eventsInDb, seeded: 0, wiped, skipped: false };
  }

  const perConnectionEstimate = Math.max(
    0.1,
    Number(seedEventsPerConnection) || SEED_EVENTS_PER_CONNECTION_FALLBACK,
  );
  const keepaliveSeconds = Math.max(2, Number(seedKeepaliveSeconds) || SEED_KEEPALIVE_SECONDS);

  console.log(
    `[fill] ${target}:${phase}: seeding to ~${targetCount} events from ${eventsInDb} (deficit=${deficit}, tolerance=${tolerance}, events_per_connection≈${perConnectionEstimate.toFixed(2)}, keepalive=${keepaliveSeconds}s)`,
  );

  let seededTotal = 0;
  let roundsExecuted = 0;

  for (let round = 1; round <= SEED_MAX_ROUNDS; round += 1) {
    if (deficit <= tolerance) break;
    roundsExecuted = round;

    const roundDeficit = Math.max(1, Math.ceil(deficit * SEED_ROUND_DEFICIT_RATIO));
    const roundStartMs = Date.now();
    const eventsBeforeRound = eventsInDb;

    const roundResult = await runClientSeedingRound({
      target,
      phase,
      round,
      deficit: roundDeficit,
      clientInfos,
      keyPath,
      relayUrl,
      artifactDir,
      threads,
      seedEventsPerConnection: perConnectionEstimate,
      seedKeepaliveSeconds: keepaliveSeconds,
    });

    let observedAdded = roundResult.acked;

    if (typeof fetchEventCount === "function") {
      const authoritative = await fetchEventCount();
      if (Number.isInteger(authoritative) && authoritative >= 0) {
        eventsInDb = authoritative;
        observedAdded = Math.max(0, eventsInDb - eventsBeforeRound);
      } else {
        eventsInDb += roundResult.acked;
      }
    } else {
      eventsInDb += roundResult.acked;
    }

    const elapsedSec = (Date.now() - roundStartMs) / 1000;
    const eventsPerSec = elapsedSec > 0 ? Math.round(observedAdded / elapsedSec) : 0;

    seededTotal += observedAdded;
    deficit = targetCount - eventsInDb;

    console.log(
      `[fill] ${target}:${phase} round ${round}: observed ${observedAdded} (acked=${roundResult.acked}, desired=${roundResult.desired}, projected=${roundResult.projected}) in ${elapsedSec.toFixed(1)}s (${eventsPerSec} events/s), now ~${eventsInDb}/${targetCount}`,
    );

    if (observedAdded <= 0) {
      console.warn(`[fill] ${target}:${phase} round ${round}: no progress, stopping early`);
      break;
    }
  }

  const remaining = Math.max(0, targetCount - eventsInDb);
  if (remaining > tolerance) {
    console.warn(
      `[fill] ${target}:${phase}: remaining deficit ${remaining} exceeds tolerance ${tolerance} after ${roundsExecuted} rounds`,
    );
  }

  return { eventsInDb, seeded: seededTotal, wiped, skipped: false };
}

// Run a single benchmark type across all clients in parallel.
async function runSingleBenchmark({
  clientInfos,
  keyPath,
  benchEnvPrefix,
  relayUrl,
  mode,
  artifactDir,
}) {
  fs.mkdirSync(artifactDir, { recursive: true });

  const clientResults = await Promise.all(
    clientInfos.map(async (client) => {
      const startedAt = new Date().toISOString();
      const startMs = Date.now();
      const stdoutPath = path.join(artifactDir, `${client.name}.stdout.log`);
      const stderrPath = path.join(artifactDir, `${client.name}.stderr.log`);

      try {
        const benchRes = await sshExec(
          client.ip,
          keyPath,
          `${benchEnvPrefix} /root/cloud-bench-client.sh ${shellEscape(relayUrl)} ${shellEscape(mode)}`,
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

  const failed = clientResults.filter((r) => r.status !== "ok");
  if (failed.length > 0) {
    throw new Error(
      `Client benchmark failed: ${failed.map((f) => f.client_name).join(", ")}`,
    );
  }

  return clientResults;
}

async function tryCommandStdout(command, args = [], options = {}) {
  try {
    const res = await runCommand(command, args, options);
    return res.stdout.trim();
  } catch {
    return "";
  }
}

function firstNonEmptyLine(value) {
  return String(value || "")
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean);
}

async function sshTryStdout(hostIp, keyPath, remoteCommand) {
  try {
    const res = await sshExec(hostIp, keyPath, remoteCommand);
    return res.stdout.trim();
  } catch {
    return "";
  }
}

async function inspectRemoteDockerImage(hostIp, keyPath, imageRef) {
  const imageId =
    firstNonEmptyLine(
      await sshTryStdout(hostIp, keyPath, `docker image inspect ${shellEscape(imageRef)} --format '{{.Id}}'`),
    ) || null;

  const repoDigestsRaw = await sshTryStdout(
    hostIp,
    keyPath,
    `docker image inspect ${shellEscape(imageRef)} --format '{{json .RepoDigests}}'`,
  );

  let imageDigests = [];
  try {
    const parsed = JSON.parse(repoDigestsRaw || "[]");
    if (Array.isArray(parsed)) {
      imageDigests = parsed;
    }
  } catch {
    // ignore parse failures
  }

  return {
    image: imageRef,
    image_id: imageId,
    image_digests: imageDigests,
  };
}

async function collectCloudComponentVersions({
  serverIp,
  keyPath,
  opts,
  needsParrhesia,
  parrhesiaImageOnServer,
  gitTag,
  gitCommit,
}) {
  const relays = {};
  const datastores = {};

  if (needsParrhesia && parrhesiaImageOnServer) {
    relays.parrhesia = {
      ...(await inspectRemoteDockerImage(serverIp, keyPath, parrhesiaImageOnServer)),
      version:
        firstNonEmptyLine(
          await sshTryStdout(serverIp, keyPath, `docker run --rm ${shellEscape(parrhesiaImageOnServer)} --version`),
        ) || null,
      git_tag: gitTag || null,
      git_commit: gitCommit || null,
      git_ref: opts.gitRef || null,
    };
  }

  if (opts.targets.includes("strfry")) {
    relays.strfry = {
      ...(await inspectRemoteDockerImage(serverIp, keyPath, opts.strfryImage)),
      version:
        firstNonEmptyLine(await sshTryStdout(serverIp, keyPath, `docker run --rm ${shellEscape(opts.strfryImage)} --version`)) ||
        null,
    };
  }

  if (opts.targets.includes("nostr-rs-relay")) {
    const nostrRsVersion =
      firstNonEmptyLine(
        await sshTryStdout(
          serverIp,
          keyPath,
          `docker run --rm --entrypoint /usr/src/app/nostr-rs-relay ${shellEscape(opts.nostrRsImage)} --version`,
        ),
      ) ||
      firstNonEmptyLine(await sshTryStdout(serverIp, keyPath, `docker run --rm ${shellEscape(opts.nostrRsImage)} --version`)) ||
      null;

    relays.nostr_rs_relay = {
      ...(await inspectRemoteDockerImage(serverIp, keyPath, opts.nostrRsImage)),
      version: nostrRsVersion,
    };
  }

  if (opts.targets.includes("nostream")) {
    const nostreamPackageVersion =
      firstNonEmptyLine(
        await sshTryStdout(serverIp, keyPath, `jq -r '.version // empty' /root/nostream-src/package.json 2>/dev/null || true`),
      ) || null;
    const nostreamCommit =
      firstNonEmptyLine(await sshTryStdout(serverIp, keyPath, "git -C /root/nostream-src rev-parse --short=12 HEAD")) ||
      null;

    relays.nostream = {
      ...(await inspectRemoteDockerImage(serverIp, keyPath, "nostream:bench")),
      version: nostreamPackageVersion,
      git_commit: nostreamCommit,
      git_ref: opts.nostreamRef,
      repo: opts.nostreamRepo,
    };
  }

  if (opts.targets.includes("haven")) {
    const havenVersionLabel =
      firstNonEmptyLine(
        await sshTryStdout(
          serverIp,
          keyPath,
          `docker image inspect ${shellEscape(opts.havenImage)} --format '{{index .Config.Labels "org.opencontainers.image.version"}}'`,
        ),
      ) || null;

    relays.haven = {
      ...(await inspectRemoteDockerImage(serverIp, keyPath, opts.havenImage)),
      version: havenVersionLabel,
    };
  }

  if (opts.targets.includes("parrhesia-pg") || opts.targets.includes("nostream")) {
    datastores.postgres = {
      ...(await inspectRemoteDockerImage(serverIp, keyPath, opts.postgresImage)),
      version:
        firstNonEmptyLine(
          await sshTryStdout(serverIp, keyPath, `docker run --rm ${shellEscape(opts.postgresImage)} postgres --version`),
        ) || null,
    };
  }

  if (opts.targets.includes("nostream")) {
    datastores.redis = {
      ...(await inspectRemoteDockerImage(serverIp, keyPath, NOSTREAM_REDIS_IMAGE)),
      version:
        firstNonEmptyLine(
          await sshTryStdout(serverIp, keyPath, `docker run --rm ${shellEscape(NOSTREAM_REDIS_IMAGE)} redis-server --version`),
        ) || null,
    };
  }

  return {
    relays,
    datastores,
  };
}

function exitCodeForSignal(signal) {
  if (signal === "SIGINT") return 130;
  if (signal === "SIGTERM") return 143;
  return 1;
}

function installSignalCleanup(cleanupFn) {
  let handling = false;

  const handler = (signal) => {
    if (handling) {
      console.warn(`[signal] ${signal} received again, forcing exit`);
      process.exit(exitCodeForSignal(signal));
      return;
    }

    handling = true;
    console.warn(`[signal] ${signal} received, cleaning up cloud resources...`);

    Promise.resolve()
      .then(() => cleanupFn(signal))
      .then(() => {
        console.warn("[signal] cleanup complete");
        process.exit(exitCodeForSignal(signal));
      })
      .catch((error) => {
        console.error("[signal] cleanup failed", error?.message || error);
        if (error?.stderr) {
          console.error(error.stderr);
        }
        process.exit(1);
      });
  };

  process.on("SIGINT", handler);
  process.on("SIGTERM", handler);

  return () => {
    process.off("SIGINT", handler);
    process.off("SIGTERM", handler);
  };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  await ensureLocalPrereqs(opts);

  const phaseLogger = createPhaseLogger();

  const datacenterChoice = await chooseDatacenter(opts);
  opts.datacenter = datacenterChoice.name;
  phaseLogger.setPrepOffsetNow();
  console.log(
    `[plan] selected datacenter=${opts.datacenter} (${ESTIMATE_WINDOW_LABEL} est gross=${formatEuro(datacenterChoice.estimatedTotal.gross)} net=${formatEuro(datacenterChoice.estimatedTotal.net)})`,
  );

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

  fs.writeFileSync(localServerScriptPath, fs.readFileSync(path.join(__dirname, "cloud_bench_server.sh"), "utf8"), "utf8");
  fs.writeFileSync(localClientScriptPath, fs.readFileSync(path.join(__dirname, "cloud_bench_client.sh"), "utf8"), "utf8");
  fs.chmodSync(localServerScriptPath, 0o755);
  fs.chmodSync(localClientScriptPath, 0o755);

  const artifactsRoot = path.resolve(ROOT_DIR, opts.artifactsDir);
  const artifactsDir = path.join(artifactsRoot, runId);
  fs.mkdirSync(artifactsDir, { recursive: true });

  const historyFile = path.resolve(ROOT_DIR, opts.historyFile);
  fs.mkdirSync(path.dirname(historyFile), { recursive: true });

  console.log(`[run] ${runId}`);
  phaseLogger.logPhase("[phase] local preparation");

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
  let firewallName = null;
  let firewallCreated = false;
  let cleanupPromise = null;

  const cleanup = async () => {
    if (cleanupPromise) {
      return cleanupPromise;
    }

    cleanupPromise = (async () => {
      if (opts.keep) {
        console.log("[cleanup] --keep set, skipping cloud cleanup");
        return;
      }

      if (createdServers.length > 0) {
        console.log("[cleanup] deleting servers...");
        await Promise.all(
          createdServers.map((name) =>
            runCommand("hcloud", ["server", "delete", name])
              .then(() => {
                console.log(`[cleanup] deleted server: ${name}`);
              })
              .catch((error) => {
                console.warn(`[cleanup] failed to delete server ${name}: ${error.message || error}`);
              }),
          ),
        );
      }

      if (firewallCreated) {
        console.log("[cleanup] deleting firewall...");
        await runCommand("hcloud", ["firewall", "delete", firewallName])
          .then(() => {
            console.log(`[cleanup] deleted firewall: ${firewallName}`);
          })
          .catch((error) => {
            console.warn(`[cleanup] failed to delete firewall ${firewallName}: ${error.message || error}`);
          });
      }

      if (sshKeyCreated) {
        console.log("[cleanup] deleting ssh key...");
        await runCommand("hcloud", ["ssh-key", "delete", keyName])
          .then(() => {
            console.log(`[cleanup] deleted ssh key: ${keyName}`);
          })
          .catch((error) => {
            console.warn(`[cleanup] failed to delete ssh key ${keyName}: ${error.message || error}`);
          });
      }
    })();

    return cleanupPromise;
  };

  const removeSignalHandlers = installSignalCleanup(async () => {
    await cleanup();
  });

  try {
    phaseLogger.logPhase("[phase] create ssh credentials");
    await runCommand("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", keyPath, "-C", keyName], {
      stdio: "inherit",
    });

    await runCommand("hcloud", ["ssh-key", "create", "--name", keyName, "--public-key-from-file", keyPubPath], {
      stdio: "inherit",
    });
    sshKeyCreated = true;

    phaseLogger.logPhase("[phase] create cloud servers in parallel");

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

    const createRequests = [
      { name: serverName, role: "server", type: opts.serverType },
      ...clientNames.map((name) => ({ name, role: "client", type: opts.clientType })),
    ];

    const createResults = await Promise.allSettled(
      createRequests.map((req) => createOne(req.name, req.role, req.type)),
    );

    const createdByName = new Map();
    const createFailures = [];

    createResults.forEach((result, index) => {
      const req = createRequests[index];
      if (result.status === "fulfilled") {
        createdServers.push(req.name);
        createdByName.set(req.name, result.value);
      } else {
        createFailures.push(`${req.role}:${req.name}: ${result.reason?.message || result.reason}`);
      }
    });

    if (createFailures.length > 0) {
      throw new Error(`Failed to create cloud servers: ${createFailures.join(" | ")}`);
    }

    const serverCreate = createdByName.get(serverName);
    if (!serverCreate) {
      throw new Error(`Failed to create cloud server node: ${serverName}`);
    }

    const clientCreates = clientNames.map((name) => createdByName.get(name));
    const serverIp = serverCreate.server.public_net.ipv4.ip;
    const clientInfos = clientCreates.map((c) => ({
      name: c.server.name,
      id: c.server.id,
      ip: c.server.public_net.ipv4.ip,
    }));

    // Reset phase clock to T+0 when cloud servers are successfully created.
    phaseLogger.setZeroNow();
    phaseLogger.logPhase("[phase] wait for SSH");
    await Promise.all([
      waitForSsh(serverIp, keyPath),
      ...clientInfos.map((client) => waitForSsh(client.ip, keyPath)),
    ]);

    // Detect orchestrator public IP from the server's perspective.
    const orchestratorIp = (
      await sshExec(serverIp, keyPath, "echo $SSH_CLIENT")
    ).stdout.trim().split(/\s+/)[0];

    // Create a firewall restricting inbound access to known benchmark IPs only.
    firewallName = `${runId}-fw`;
    const allBenchIps = [orchestratorIp, serverIp, ...clientInfos.map((c) => c.ip)];
    const sourceIps = [...new Set(allBenchIps)].map((ip) => `${ip}/32`);

    const firewallRules = [
      { direction: "in", protocol: "tcp", port: "22",   source_ips: sourceIps, description: "SSH" },
      { direction: "in", protocol: "tcp", port: "3355", source_ips: sourceIps, description: "Haven" },
      { direction: "in", protocol: "tcp", port: "4413", source_ips: sourceIps, description: "Parrhesia" },
      { direction: "in", protocol: "tcp", port: "7777", source_ips: sourceIps, description: "strfry" },
      { direction: "in", protocol: "tcp", port: "8008", source_ips: sourceIps, description: "Nostream" },
      { direction: "in", protocol: "tcp", port: "8080", source_ips: sourceIps, description: "nostr-rs-relay" },
      { direction: "in", protocol: "tcp", port: "9090", source_ips: sourceIps, description: "Prometheus" },
      { direction: "in", protocol: "tcp", port: "9100", source_ips: sourceIps, description: "node_exporter" },
      { direction: "in", protocol: "icmp",              source_ips: ["0.0.0.0/0", "::/0"], description: "ICMP" },
    ];

    const rulesPath = path.join(tmpDir, "firewall-rules.json");
    fs.writeFileSync(rulesPath, JSON.stringify(firewallRules));

    await runCommand("hcloud", ["firewall", "create", "--name", firewallName, "--rules-file", rulesPath]);
    firewallCreated = true;

    for (const name of createdServers) {
      await runCommand("hcloud", [
        "firewall", "apply-to-resource", firewallName,
        "--type", "server", "--server", name,
      ]);
    }
    console.log(`[firewall] ${firewallName} applied (sources: ${sourceIps.join(", ")})`);

    phaseLogger.logPhase("[phase] install runtime dependencies on server node");
    const serverInstallCmd = [
      "set -euo pipefail",
      "export DEBIAN_FRONTEND=noninteractive",
      "apt-get update -y >/dev/null",
      "apt-get install -y docker.io curl jq git python3 >/dev/null",
      "systemctl enable --now docker >/dev/null",
      "sysctl -w net.ipv4.ip_local_port_range='10000 65535' >/dev/null || true",
      "sysctl -w net.core.somaxconn=65535 >/dev/null || true",
      "docker --version",
      "python3 --version",
      "git --version",
      "curl --version",
    ].join("; ");

    await sshExec(serverIp, keyPath, serverInstallCmd, { stdio: "inherit" });

    phaseLogger.logPhase("[phase] minimal client setup (no apt install)");
    const clientBootstrapCmd = [
      "set -euo pipefail",
      "mkdir -p /usr/local/bin",
      "sysctl -w net.ipv4.ip_local_port_range='10000 65535' >/dev/null || true",
      "sysctl -w net.core.somaxconn=65535 >/dev/null || true",
    ].join("; ");

    await Promise.all(clientInfos.map((client) => sshExec(client.ip, keyPath, clientBootstrapCmd, { stdio: "inherit" })));

    phaseLogger.logPhase("[phase] upload control scripts + nostr-bench binary");

    await scpToHost(serverIp, keyPath, localServerScriptPath, "/root/cloud-bench-server.sh");
    await sshExec(serverIp, keyPath, "chmod +x /root/cloud-bench-server.sh");

    for (const client of clientInfos) {
      await scpToHost(client.ip, keyPath, localClientScriptPath, "/root/cloud-bench-client.sh");
      await scpToHost(client.ip, keyPath, nostrBench.path, "/usr/local/bin/nostr-bench");
      await sshExec(client.ip, keyPath, "chmod +x /root/cloud-bench-client.sh /usr/local/bin/nostr-bench");
    }

    phaseLogger.logPhase("[phase] server image setup");

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
    const comparisonImages = new Set();

    if (opts.targets.includes("parrhesia-pg") || opts.targets.includes("nostream")) {
      comparisonImages.add(opts.postgresImage);
    }
    if (opts.targets.includes("strfry")) {
      comparisonImages.add(opts.strfryImage);
    }
    if (opts.targets.includes("nostr-rs-relay")) {
      comparisonImages.add(opts.nostrRsImage);
    }
    if (opts.targets.includes("nostream")) {
      comparisonImages.add(NOSTREAM_REDIS_IMAGE);
      comparisonImages.add("node:18-alpine3.16");
    }
    if (opts.targets.includes("haven")) {
      comparisonImages.add(opts.havenImage);
    }

    for (const image of comparisonImages) {
      await sshExec(serverIp, keyPath, `docker pull ${shellEscape(image)}`, { stdio: "inherit" });
    }

    // Install Prometheus + node_exporter for kernel/app metrics collection.
    const clientIps = clientInfos.map((c) => c.ip);
    if (opts.monitoring) {
      await installMonitoring({
        serverIp,
        clientIps,
        keyPath,
        ssh: (ip, kp, cmd) => sshExec(ip, kp, cmd),
      });
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
      nostream: "start-nostream",
      haven: "start-haven",
    };

    const relayUrls = {
      "parrhesia-pg": `ws://${serverIp}:4413/relay`,
      "parrhesia-memory": `ws://${serverIp}:4413/relay`,
      strfry: `ws://${serverIp}:7777`,
      "nostr-rs-relay": `ws://${serverIp}:8080`,
      nostream: `ws://${serverIp}:8008`,
      haven: `ws://${serverIp}:3355`,
    };

    const results = [];
    const targetOrderPerRun = [];

    phaseLogger.logPhase(`[phase] benchmark execution (mode=${opts.quick ? "quick" : "phased"})`);

    for (let runIndex = 1; runIndex <= opts.runs; runIndex += 1) {
      const runTargets = shuffled(opts.targets);
      targetOrderPerRun.push({ run: runIndex, targets: runTargets });
      console.log(`[bench] run ${runIndex}/${opts.runs} target-order=${runTargets.join(",")}`);

      for (const target of runTargets) {
        console.log(`[bench] run ${runIndex}/${opts.runs} target=${target}`);
        const targetStartTime = new Date().toISOString();

        const serverEnvPrefix = [
          `PARRHESIA_IMAGE=${shellEscape(parrhesiaImageOnServer || "parrhesia:latest")}`,
          `POSTGRES_IMAGE=${shellEscape(opts.postgresImage)}`,
          `STRFRY_IMAGE=${shellEscape(opts.strfryImage)}`,
          `NOSTR_RS_IMAGE=${shellEscape(opts.nostrRsImage)}`,
          `NOSTREAM_REPO=${shellEscape(opts.nostreamRepo)}`,
          `NOSTREAM_REF=${shellEscape(opts.nostreamRef)}`,
          `NOSTREAM_REDIS_IMAGE=${shellEscape(NOSTREAM_REDIS_IMAGE)}`,
          `HAVEN_IMAGE=${shellEscape(opts.havenImage)}`,
          `HAVEN_RELAY_URL=${shellEscape(`${serverIp}:3355`)}`,
        ].join(" ");

        try {
          await sshExec(serverIp, keyPath, `${serverEnvPrefix} /root/cloud-bench-server.sh ${shellEscape(startCommands[target])}`);
        } catch (error) {
          console.error(`[bench] target startup failed target=${target} run=${runIndex}`);
          if (error?.stdout?.trim()) {
            console.error(`[bench] server startup stdout:\n${error.stdout.trim()}`);
          }
          if (error?.stderr?.trim()) {
            console.error(`[bench] server startup stderr:\n${error.stderr.trim()}`);
          }
          throw error;
        }

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
          `PARRHESIA_BENCH_THREADS=${opts.bench.threads}`,
        ].join(" ");

        const benchArgs = { clientInfos, keyPath, benchEnvPrefix, relayUrl };
        const fetchEventCountForTarget = async () =>
          fetchServerEventCount({
            target,
            serverIp,
            keyPath,
            serverEnvPrefix,
          });

        if (opts.quick) {
          // Flat mode: run all benchmarks in one shot (backward compat)
          const clientRunResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "all",
            artifactDir: runTargetDir,
          });

          results.push({
            run: runIndex,
            target,
            relay_url: relayUrl,
            mode: "flat",
            clients: clientRunResults,
          });
        } else {
          // Phased mode: separate benchmarks at different DB fill levels
          let eventsInDb = 0;

          console.log(`[bench] ${target}: connect`);
          const connectResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "connect",
            artifactDir: path.join(runTargetDir, "connect"),
          });

          console.log(`[bench] ${target}: echo`);
          const echoResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "echo",
            artifactDir: path.join(runTargetDir, "echo"),
          });

          // Phase: empty
          console.log(`[bench] ${target}: req (empty, ${eventsInDb} events)`);
          const emptyReqResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "req",
            artifactDir: path.join(runTargetDir, "empty-req"),
          });

          console.log(`[bench] ${target}: event (empty, ${eventsInDb} events)`);
          const emptyEventResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "event",
            artifactDir: path.join(runTargetDir, "empty-event"),
          });
          const estimatedEmptyEventWritten = countEventsWritten(emptyEventResults);
          eventsInDb += estimatedEmptyEventWritten;

          let observedEmptyEventWritten = estimatedEmptyEventWritten;
          const authoritativeAfterEmpty = await fetchEventCountForTarget();
          if (Number.isInteger(authoritativeAfterEmpty) && authoritativeAfterEmpty >= 0) {
            observedEmptyEventWritten = Math.max(0, authoritativeAfterEmpty);
            eventsInDb = authoritativeAfterEmpty;
          }

          console.log(`[bench] ${target}: ~${eventsInDb} events in DB after empty phase`);

          const warmSeedEventsPerConnection = Math.max(
            0.1,
            observedEmptyEventWritten / Math.max(1, opts.bench.eventCount * clientInfos.length),
          );

          // Fill to warm
          const fillWarm = await smartFill({
            target,
            phase: "warm",
            targetCount: opts.warmEvents,
            eventsInDb,
            relayUrl,
            serverIp,
            keyPath,
            clientInfos,
            serverEnvPrefix,
            artifactDir: path.join(runTargetDir, "fill-warm"),
            threads: opts.bench.threads,
            seedEventsPerConnection: warmSeedEventsPerConnection,
            seedKeepaliveSeconds: opts.bench.keepaliveSeconds,
            skipFill: target === "haven",
            fetchEventCount: fetchEventCountForTarget,
          });
          eventsInDb = fillWarm.eventsInDb;

          // Phase: warm
          console.log(`[bench] ${target}: req (warm, ~${eventsInDb} events)`);
          const warmReqResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "req",
            artifactDir: path.join(runTargetDir, "warm-req"),
          });

          console.log(`[bench] ${target}: event (warm, ~${eventsInDb} events)`);
          const warmEventResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "event",
            artifactDir: path.join(runTargetDir, "warm-event"),
          });
          const estimatedWarmEventWritten = countEventsWritten(warmEventResults);
          const warmEventsBefore = eventsInDb;
          eventsInDb += estimatedWarmEventWritten;

          let observedWarmEventWritten = estimatedWarmEventWritten;
          const authoritativeAfterWarmEvent = await fetchEventCountForTarget();
          if (Number.isInteger(authoritativeAfterWarmEvent) && authoritativeAfterWarmEvent >= 0) {
            observedWarmEventWritten = Math.max(0, authoritativeAfterWarmEvent - warmEventsBefore);
            eventsInDb = authoritativeAfterWarmEvent;
          }

          const hotSeedEventsPerConnection = Math.max(
            0.1,
            observedWarmEventWritten / Math.max(1, opts.bench.eventCount * clientInfos.length),
          );

          // Fill to hot
          const fillHot = await smartFill({
            target,
            phase: "hot",
            targetCount: opts.hotEvents,
            eventsInDb,
            relayUrl,
            serverIp,
            keyPath,
            clientInfos,
            serverEnvPrefix,
            artifactDir: path.join(runTargetDir, "fill-hot"),
            threads: opts.bench.threads,
            seedEventsPerConnection: hotSeedEventsPerConnection,
            seedKeepaliveSeconds: opts.bench.keepaliveSeconds,
            skipFill: target === "haven",
            fetchEventCount: fetchEventCountForTarget,
          });
          eventsInDb = fillHot.eventsInDb;

          // Phase: hot
          console.log(`[bench] ${target}: req (hot, ~${eventsInDb} events)`);
          const hotReqResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "req",
            artifactDir: path.join(runTargetDir, "hot-req"),
          });

          console.log(`[bench] ${target}: event (hot, ~${eventsInDb} events)`);
          const hotEventResults = await runSingleBenchmark({
            ...benchArgs,
            mode: "event",
            artifactDir: path.join(runTargetDir, "hot-event"),
          });

          results.push({
            run: runIndex,
            target,
            relay_url: relayUrl,
            mode: "phased",
            phases: {
              connect: { clients: connectResults },
              echo: { clients: echoResults },
              empty: {
                req: { clients: emptyReqResults },
                event: { clients: emptyEventResults },
                db_events_before: 0,
              },
              warm: {
                req: { clients: warmReqResults },
                event: { clients: warmEventResults },
                db_events_before: fillWarm.eventsInDb,
                seeded: fillWarm.seeded,
                wiped: fillWarm.wiped,
              },
              hot: {
                req: { clients: hotReqResults },
                event: { clients: hotEventResults },
                db_events_before: fillHot.eventsInDb,
                seeded: fillHot.seeded,
                wiped: fillHot.wiped,
              },
            },
          });
        }

        // Collect Prometheus metrics for this target's benchmark window.
        if (opts.monitoring) {
          const metrics = await collectMetrics({
            serverIp,
            startTime: targetStartTime,
            endTime: new Date().toISOString(),
          });
          if (metrics) {
            const metricsPath = path.join(runTargetDir, "metrics.json");
            fs.writeFileSync(metricsPath, JSON.stringify(metrics, null, 2));
            console.log(`[monitoring] saved ${path.relative(ROOT_DIR, metricsPath)}`);
          }
        }
      }
    }

    const gitTag = detectedGitTag || "untagged";
    const gitCommit = parrhesiaSource.gitCommit || detectedGitCommit || "unknown";

    versions.components = await collectCloudComponentVersions({
      serverIp,
      keyPath,
      opts,
      needsParrhesia,
      parrhesiaImageOnServer,
      gitTag,
      gitCommit,
    });

    if (opts.monitoring) {
      await stopMonitoring({
        serverIp,
        clientIps,
        keyPath,
        ssh: (ip, kp, cmd) => sshExec(ip, kp, cmd),
      });
    }

    phaseLogger.logPhase("[phase] final server cleanup (containers)");
    await sshExec(serverIp, keyPath, "/root/cloud-bench-server.sh cleanup");

    const servers = summariseServersFromResults(results);

    const entry = {
      schema_version: opts.quick ? 2 : 3,
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
        datacenter_location: datacenterChoice.location,
        server_type: opts.serverType,
        client_type: opts.clientType,
        image_base: opts.imageBase,
        clients: opts.clients,
        estimated_price_window_eur: {
          minutes: ESTIMATE_WINDOW_MINUTES,
          gross: datacenterChoice.estimatedTotal.gross,
          net: datacenterChoice.estimatedTotal.net,
        },
      },
      bench: {
        runs: opts.runs,
        targets: opts.targets,
        target_order_per_run: targetOrderPerRun,
        mode: opts.quick ? "flat" : "phased",
        warm_events: opts.warmEvents,
        hot_events: opts.hotEvents,
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
    removeSignalHandlers();
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
