#!/usr/bin/env node

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");

const DEFAULT_TARGETS = ["parrhesia-pg", "parrhesia-memory", "strfry", "nostr-rs-relay", "nostream", "haven"];
const ESTIMATE_WINDOW_MINUTES = 30;
const ESTIMATE_WINDOW_HOURS = ESTIMATE_WINDOW_MINUTES / 60;
const ESTIMATE_WINDOW_LABEL = `${ESTIMATE_WINDOW_MINUTES}m`;
const BENCH_BUILD_DIR = path.join(ROOT_DIR, "_build", "bench");
const NOSTREAM_REDIS_IMAGE = "redis:7.0.5-alpine3.16";
const SEED_TOLERANCE_RATIO = 0.01;
const SEED_MAX_ROUNDS = 4;
const SEED_EVENT_RATE = 5000;

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
  --datacenter <name>          Initial datacenter selection (default: ${DEFAULTS.datacenter})
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
  -h, --help

Notes:
  - Requires hcloud, ssh, scp, ssh-keygen, git.
  - Before provisioning, checks all datacenters for type availability and estimates ${ESTIMATE_WINDOW_LABEL} cost.
  - In interactive terminals, prompts you to pick + confirm the datacenter.
  - Caches built nostr-bench at _build/bench/nostr-bench and reuses it when valid.
  - Auto-tunes Postgres/Redis/app pool sizing from server RAM + CPU for DB-backed targets.
  - Randomizes target order per run and wipes persisted target data directories on each start.
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

  const defaultChoice = choices.find((choice) => choice.name === opts.datacenter) || choices[0];

  if (!process.stdin.isTTY || !process.stdout.isTTY) {
    if (!choices.some((choice) => choice.name === opts.datacenter)) {
      throw new Error(
        `Requested datacenter ${opts.datacenter} is not currently compatible. Compatible: ${choices
          .map((choice) => choice.name)
          .join(", ")}`,
      );
    }

    console.log(
      `[plan] non-interactive mode: using datacenter ${opts.datacenter} (${ESTIMATE_WINDOW_LABEL} est gross=${formatEuro(defaultChoice.estimatedTotal.gross)} net=${formatEuro(defaultChoice.estimatedTotal.net)})`,
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

    try {
      const fileSummary = await validatePortableBinary(cachedBinaryPath);
      fs.chmodSync(cachedBinaryPath, 0o755);

      const version = await readVersionIfRunnable(cachedBinaryPath, fileSummary, "cache-reuse");
      const metadata = readCacheMetadata();

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
  console.log("[local] cloning nostr-bench source for docker fallback...");
  await runCommand("git", ["clone", "--depth", "1", "https://github.com/rnostr/nostr-bench.git", srcDir], {
    stdio: "inherit",
  });

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

function makeServerScript() {
  return `#!/usr/bin/env bash
set -euo pipefail

PARRHESIA_IMAGE="\${PARRHESIA_IMAGE:-parrhesia:latest}"
POSTGRES_IMAGE="\${POSTGRES_IMAGE:-postgres:18}"
STRFRY_IMAGE="\${STRFRY_IMAGE:-ghcr.io/hoytech/strfry:latest}"
NOSTR_RS_IMAGE="\${NOSTR_RS_IMAGE:-scsibug/nostr-rs-relay:latest}"
NOSTREAM_REPO="\${NOSTREAM_REPO:-https://github.com/Cameri/nostream.git}"
NOSTREAM_REF="\${NOSTREAM_REF:-main}"
NOSTREAM_REDIS_IMAGE="\${NOSTREAM_REDIS_IMAGE:-${NOSTREAM_REDIS_IMAGE}}"
HAVEN_IMAGE="\${HAVEN_IMAGE:-holgerhatgarkeinenode/haven-docker:latest}"
HAVEN_RELAY_URL="\${HAVEN_RELAY_URL:-127.0.0.1:3355}"

NOSTREAM_SECRET="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
HAVEN_OWNER_NPUB="npub1utx00neqgqln72j22kej3ux7803c2k986henvvha4thuwfkper4s7r50e8"

cleanup_containers() {
  docker rm -f parrhesia pg strfry nostr-rs nostream nostream-db nostream-cache haven >/dev/null 2>&1 || true
}

ensure_benchnet() {
  docker network create benchnet >/dev/null 2>&1 || true
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

wait_nostream_pg() {
  local timeout="\${1:-90}"
  for _ in \$(seq 1 "\$timeout"); do
    if docker exec nostream-db pg_isready -U nostr_ts_relay -d nostr_ts_relay >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail 200 nostream-db >&2 || true
  echo "Timed out waiting for nostream Postgres" >&2
  return 1
}

wait_nostream_redis() {
  local timeout="\${1:-60}"
  for _ in \$(seq 1 "\$timeout"); do
    if docker exec nostream-cache redis-cli -a nostr_ts_relay ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs --tail 200 nostream-cache >&2 || true
  echo "Timed out waiting for nostream Redis" >&2
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

clamp() {
  local value="\$1"
  local min="\$2"
  local max="\$3"

  if (( value < min )); then
    echo "\$min"
  elif (( value > max )); then
    echo "\$max"
  else
    echo "\$value"
  fi
}

derive_resource_tuning() {
  local mem_kb
  mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"

  if [[ -z "\$mem_kb" || ! "\$mem_kb" =~ ^[0-9]+$ ]]; then
    mem_kb=4194304
  fi

  HOST_MEM_MB=$((mem_kb / 1024))
  HOST_CPU_CORES=$(nproc 2>/dev/null || echo 2)

  local computed_pg_max_connections=$((HOST_CPU_CORES * 50))
  local computed_pg_shared_buffers_mb=$((HOST_MEM_MB / 4))
  local computed_pg_effective_cache_size_mb=$((HOST_MEM_MB * 3 / 4))
  local computed_pg_maintenance_work_mem_mb=$((HOST_MEM_MB / 16))
  local computed_pg_max_wal_size_gb=$((HOST_MEM_MB / 8192))

  computed_pg_max_connections=$(clamp "\$computed_pg_max_connections" 200 1000)
  computed_pg_shared_buffers_mb=$(clamp "\$computed_pg_shared_buffers_mb" 512 32768)
  computed_pg_effective_cache_size_mb=$(clamp "\$computed_pg_effective_cache_size_mb" 1024 98304)
  computed_pg_maintenance_work_mem_mb=$(clamp "\$computed_pg_maintenance_work_mem_mb" 256 2048)
  computed_pg_max_wal_size_gb=$(clamp "\$computed_pg_max_wal_size_gb" 4 64)

  local computed_pg_min_wal_size_gb=$((computed_pg_max_wal_size_gb / 4))
  computed_pg_min_wal_size_gb=$(clamp "\$computed_pg_min_wal_size_gb" 1 16)

  local computed_pg_work_mem_mb=$(((HOST_MEM_MB - computed_pg_shared_buffers_mb) / (computed_pg_max_connections * 3)))
  computed_pg_work_mem_mb=$(clamp "\$computed_pg_work_mem_mb" 4 128)

  local computed_parrhesia_pool_size=$((HOST_CPU_CORES * 8))
  computed_parrhesia_pool_size=$(clamp "\$computed_parrhesia_pool_size" 20 200)

  local computed_nostream_db_min_pool_size=$((HOST_CPU_CORES * 4))
  computed_nostream_db_min_pool_size=$(clamp "\$computed_nostream_db_min_pool_size" 16 128)

  local computed_nostream_db_max_pool_size=$((HOST_CPU_CORES * 16))
  computed_nostream_db_max_pool_size=$(clamp "\$computed_nostream_db_max_pool_size" 64 512)

  if (( computed_nostream_db_max_pool_size < computed_nostream_db_min_pool_size )); then
    computed_nostream_db_max_pool_size="\$computed_nostream_db_min_pool_size"
  fi

  local computed_redis_maxmemory_mb=$((HOST_MEM_MB / 3))
  computed_redis_maxmemory_mb=$(clamp "\$computed_redis_maxmemory_mb" 256 65536)

  PG_MAX_CONNECTIONS="\${PG_MAX_CONNECTIONS:-\$computed_pg_max_connections}"
  PG_SHARED_BUFFERS_MB="\${PG_SHARED_BUFFERS_MB:-\$computed_pg_shared_buffers_mb}"
  PG_EFFECTIVE_CACHE_SIZE_MB="\${PG_EFFECTIVE_CACHE_SIZE_MB:-\$computed_pg_effective_cache_size_mb}"
  PG_MAINTENANCE_WORK_MEM_MB="\${PG_MAINTENANCE_WORK_MEM_MB:-\$computed_pg_maintenance_work_mem_mb}"
  PG_WORK_MEM_MB="\${PG_WORK_MEM_MB:-\$computed_pg_work_mem_mb}"
  PG_MIN_WAL_SIZE_GB="\${PG_MIN_WAL_SIZE_GB:-\$computed_pg_min_wal_size_gb}"
  PG_MAX_WAL_SIZE_GB="\${PG_MAX_WAL_SIZE_GB:-\$computed_pg_max_wal_size_gb}"
  PARRHESIA_POOL_SIZE="\${PARRHESIA_POOL_SIZE:-\$computed_parrhesia_pool_size}"
  NOSTREAM_DB_MIN_POOL_SIZE="\${NOSTREAM_DB_MIN_POOL_SIZE:-\$computed_nostream_db_min_pool_size}"
  NOSTREAM_DB_MAX_POOL_SIZE="\${NOSTREAM_DB_MAX_POOL_SIZE:-\$computed_nostream_db_max_pool_size}"
  REDIS_MAXMEMORY_MB="\${REDIS_MAXMEMORY_MB:-\$computed_redis_maxmemory_mb}"

  PG_TUNING_ARGS=(
    -c max_connections="\$PG_MAX_CONNECTIONS"
    -c shared_buffers="\${PG_SHARED_BUFFERS_MB}MB"
    -c effective_cache_size="\${PG_EFFECTIVE_CACHE_SIZE_MB}MB"
    -c maintenance_work_mem="\${PG_MAINTENANCE_WORK_MEM_MB}MB"
    -c work_mem="\${PG_WORK_MEM_MB}MB"
    -c min_wal_size="\${PG_MIN_WAL_SIZE_GB}GB"
    -c max_wal_size="\${PG_MAX_WAL_SIZE_GB}GB"
    -c checkpoint_completion_target=0.9
    -c wal_compression=on
  )

  echo "[server] resource profile: mem_mb=\$HOST_MEM_MB cpu_cores=\$HOST_CPU_CORES"
  echo "[server] postgres tuning: max_connections=\$PG_MAX_CONNECTIONS shared_buffers=\${PG_SHARED_BUFFERS_MB}MB effective_cache_size=\${PG_EFFECTIVE_CACHE_SIZE_MB}MB work_mem=\${PG_WORK_MEM_MB}MB"
  echo "[server] app tuning: parrhesia_pool=\$PARRHESIA_POOL_SIZE nostream_db_pool=\${NOSTREAM_DB_MIN_POOL_SIZE}-\${NOSTREAM_DB_MAX_POOL_SIZE} redis_maxmemory=\${REDIS_MAXMEMORY_MB}MB"
}

tune_nostream_settings() {
  local settings_path="/root/nostream-config/settings.yaml"

  if [[ ! -f "\$settings_path" ]]; then
    return 1
  fi

  python3 - "\$settings_path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

def replace_after(marker: str, old: str, new: str) -> None:
    global text
    marker_idx = text.find(marker)
    if marker_idx == -1:
        return

    old_idx = text.find(old, marker_idx)
    if old_idx == -1:
        return

    text = text[:old_idx] + new + text[old_idx + len(old):]

text = text.replace("  remoteIpHeader: x-forwarded-for", "  # remoteIpHeader disabled for direct bench traffic")

text = text.replace(
    "  connection:\\n    rateLimits:\\n      - period: 1000\\n        rate: 12\\n      - period: 60000\\n        rate: 48",
    "  connection:\\n    rateLimits:\\n      - period: 1000\\n        rate: 300\\n      - period: 60000\\n        rate: 12000",
)

replace_after("description: 30 admission checks/min or 1 check every 2 seconds", "rate: 30", "rate: 3000")
replace_after("description: 6 events/min for event kinds 0, 3, 40 and 41", "rate: 6", "rate: 600")
replace_after("description: 12 events/min for event kinds 1, 2, 4 and 42", "rate: 12", "rate: 1200")
replace_after("description: 30 events/min for event kind ranges 5-7 and 43-49", "rate: 30", "rate: 3000")
replace_after("description: 24 events/min for replaceable events and parameterized replaceable", "rate: 24", "rate: 2400")
replace_after("description: 60 events/min for ephemeral events", "rate: 60", "rate: 6000")
replace_after("description: 720 events/hour for all events", "rate: 720", "rate: 72000")
replace_after("description: 240 raw messages/min", "rate: 240", "rate: 120000")

text = text.replace("maxSubscriptions: 10", "maxSubscriptions: 512")
text = text.replace("maxFilters: 10", "maxFilters: 128")
text = text.replace("maxFilterValues: 2500", "maxFilterValues: 100000")
text = text.replace("maxLimit: 5000", "maxLimit: 50000")

path.write_text(text, encoding="utf-8")
PY
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
  echo "usage: cloud-bench-server.sh <start-*|wipe-data-*|cleanup>" >&2
  exit 1
fi

derive_resource_tuning

case "\$cmd" in
  start-parrhesia-pg)
    cleanup_containers
    docker network create benchnet >/dev/null 2>&1 || true

    docker run -d --name pg --network benchnet \
      --ulimit nofile=262144:262144 \
      -e POSTGRES_DB=parrhesia \
      -e POSTGRES_USER=parrhesia \
      -e POSTGRES_PASSWORD=parrhesia \
      "\$POSTGRES_IMAGE" \
      "\${PG_TUNING_ARGS[@]}" >/dev/null

    wait_pg 90

    docker run --rm --network benchnet \
      -e DATABASE_URL=ecto://parrhesia:parrhesia@pg:5432/parrhesia \
      "\$PARRHESIA_IMAGE" \
      eval "Parrhesia.Release.migrate()"

    docker run -d --name parrhesia --network benchnet \
      --ulimit nofile=262144:262144 \
      -p 4413:4413 \
      -e DATABASE_URL=ecto://parrhesia:parrhesia@pg:5432/parrhesia \
      -e POOL_SIZE="\$PARRHESIA_POOL_SIZE" \
      "\${common_parrhesia_env[@]}" \
      "\$PARRHESIA_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  start-parrhesia-memory)
    cleanup_containers

    docker run -d --name parrhesia \
      --ulimit nofile=262144:262144 \
      -p 4413:4413 \
      -e PARRHESIA_STORAGE_BACKEND=memory \
      -e PARRHESIA_MODERATION_CACHE_ENABLED=0 \
      "\${common_parrhesia_env[@]}" \
      "\$PARRHESIA_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  start-strfry)
    cleanup_containers

    rm -rf /root/strfry-data
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
      --ulimit nofile=262144:262144 \
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
address = "0.0.0.0"
port = 8080
ping_interval = 120

[options]
reject_future_seconds = 1800

[limits]
messages_per_sec = 5000
subscriptions_per_min = 6000
max_event_bytes = 1048576
max_ws_message_bytes = 16777216
max_ws_frame_bytes = 16777216
broadcast_buffer = 65536
event_persist_buffer = 16384
limit_scrapers = false
EOF

    docker run -d --name nostr-rs \
      --ulimit nofile=262144:262144 \
      -p 8080:8080 \
      -v /root/nostr-rs.toml:/usr/src/app/config.toml:ro \
      "\$NOSTR_RS_IMAGE" >/dev/null

    wait_http "http://127.0.0.1:8080/" 60 nostr-rs
    ;;

  start-nostream)
    cleanup_containers
    ensure_benchnet

    if [[ ! -d /root/nostream-src/.git ]]; then
      git clone --depth 1 "\$NOSTREAM_REPO" /root/nostream-src >/dev/null
    fi

    git -C /root/nostream-src fetch --depth 1 origin "\$NOSTREAM_REF" >/dev/null 2>&1 || true
    if git -C /root/nostream-src rev-parse --verify FETCH_HEAD >/dev/null 2>&1; then
      git -C /root/nostream-src checkout --force FETCH_HEAD >/dev/null
    else
      git -C /root/nostream-src checkout --force "\$NOSTREAM_REF" >/dev/null
    fi

    nostream_ref_marker=/root/nostream-src/.bench_ref
    should_build_nostream=0
    if ! docker image inspect nostream:bench >/dev/null 2>&1; then
      should_build_nostream=1
    elif [[ ! -f "\$nostream_ref_marker" ]] || [[ "$(cat "\$nostream_ref_marker")" != "\$NOSTREAM_REF" ]]; then
      should_build_nostream=1
    fi

    if [[ "\$should_build_nostream" == "1" ]]; then
      docker build -t nostream:bench /root/nostream-src >/dev/null
      printf '%s\n' "\$NOSTREAM_REF" > "\$nostream_ref_marker"
    fi

    mkdir -p /root/nostream-config
    if [[ ! -f /root/nostream-config/settings.yaml ]]; then
      cp /root/nostream-src/resources/default-settings.yaml /root/nostream-config/settings.yaml
    fi

    tune_nostream_settings

    docker run -d --name nostream-db --network benchnet \
      --ulimit nofile=262144:262144 \
      -e POSTGRES_DB=nostr_ts_relay \
      -e POSTGRES_USER=nostr_ts_relay \
      -e POSTGRES_PASSWORD=nostr_ts_relay \
      "\$POSTGRES_IMAGE" \
      "\${PG_TUNING_ARGS[@]}" >/dev/null

    wait_nostream_pg 90

    docker run -d --name nostream-cache --network benchnet \
      "\$NOSTREAM_REDIS_IMAGE" \
      redis-server \
      --loglevel warning \
      --requirepass nostr_ts_relay \
      --maxmemory "\${REDIS_MAXMEMORY_MB}mb" \
      --maxmemory-policy noeviction >/dev/null

    wait_nostream_redis 60

    docker run --rm --network benchnet \
      -e DB_HOST=nostream-db \
      -e DB_PORT=5432 \
      -e DB_USER=nostr_ts_relay \
      -e DB_PASSWORD=nostr_ts_relay \
      -e DB_NAME=nostr_ts_relay \
      -v /root/nostream-src/migrations:/code/migrations:ro \
      -v /root/nostream-src/knexfile.js:/code/knexfile.js:ro \
      node:18-alpine3.16 \
      sh -lc 'cd /code && npm install --no-save --quiet knex@2.4.0 pg@8.8.0 && npx knex migrate:latest'

    docker run -d --name nostream --network benchnet \
      --ulimit nofile=262144:262144 \
      -p 8008:8008 \
      -e SECRET="\$NOSTREAM_SECRET" \
      -e RELAY_PORT=8008 \
      -e NOSTR_CONFIG_DIR=/home/node/.nostr \
      -e DB_HOST=nostream-db \
      -e DB_PORT=5432 \
      -e DB_USER=nostr_ts_relay \
      -e DB_PASSWORD=nostr_ts_relay \
      -e DB_NAME=nostr_ts_relay \
      -e DB_MIN_POOL_SIZE="\$NOSTREAM_DB_MIN_POOL_SIZE" \
      -e DB_MAX_POOL_SIZE="\$NOSTREAM_DB_MAX_POOL_SIZE" \
      -e DB_ACQUIRE_CONNECTION_TIMEOUT=60000 \
      -e REDIS_HOST=nostream-cache \
      -e REDIS_PORT=6379 \
      -e REDIS_USER=default \
      -e REDIS_PASSWORD=nostr_ts_relay \
      -v /root/nostream-config:/home/node/.nostr:ro \
      nostream:bench >/dev/null

    wait_port 8008 180 nostream
    ;;

  start-haven)
    cleanup_containers

    rm -rf /root/haven-bench
    mkdir -p /root/haven-bench/db
    mkdir -p /root/haven-bench/blossom
    mkdir -p /root/haven-bench/templates/static

    if [[ ! -f /root/haven-bench/templates/index.html ]]; then
      cat > /root/haven-bench/templates/index.html <<'EOF'
<!doctype html>
<html>
  <head>
    <meta charset="utf-8" />
    <title>Haven</title>
  </head>
  <body>
    <h1>Haven</h1>
  </body>
</html>
EOF
    fi

    printf '[]\n' > /root/haven-bench/relays_import.json
    printf '[]\n' > /root/haven-bench/relays_blastr.json
    printf '[]\n' > /root/haven-bench/blacklisted_npubs.json
    printf '[]\n' > /root/haven-bench/whitelisted_npubs.json

    cat > /root/haven-bench/haven.env <<EOF
OWNER_NPUB=\$HAVEN_OWNER_NPUB
RELAY_URL=\$HAVEN_RELAY_URL
RELAY_PORT=3355
RELAY_BIND_ADDRESS=0.0.0.0
DB_ENGINE=badger
LMDB_MAPSIZE=0
BLOSSOM_PATH=blossom/
PRIVATE_RELAY_NAME=Private Relay
PRIVATE_RELAY_NPUB=\$HAVEN_OWNER_NPUB
PRIVATE_RELAY_DESCRIPTION=Private relay for benchmarking
PRIVATE_RELAY_ICON=https://example.com/icon.png
PRIVATE_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
PRIVATE_RELAY_EVENT_IP_LIMITER_INTERVAL=1
PRIVATE_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
PRIVATE_RELAY_ALLOW_EMPTY_FILTERS=true
PRIVATE_RELAY_ALLOW_COMPLEX_FILTERS=true
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
PRIVATE_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
CHAT_RELAY_NAME=Chat Relay
CHAT_RELAY_NPUB=\$HAVEN_OWNER_NPUB
CHAT_RELAY_DESCRIPTION=Chat relay for benchmarking
CHAT_RELAY_ICON=https://example.com/icon.png
CHAT_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
CHAT_RELAY_EVENT_IP_LIMITER_INTERVAL=1
CHAT_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
CHAT_RELAY_ALLOW_EMPTY_FILTERS=true
CHAT_RELAY_ALLOW_COMPLEX_FILTERS=true
CHAT_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
CHAT_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
CHAT_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
OUTBOX_RELAY_NAME=Outbox Relay
OUTBOX_RELAY_NPUB=\$HAVEN_OWNER_NPUB
OUTBOX_RELAY_DESCRIPTION=Outbox relay for benchmarking
OUTBOX_RELAY_ICON=https://example.com/icon.png
OUTBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
OUTBOX_RELAY_EVENT_IP_LIMITER_INTERVAL=1
OUTBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
OUTBOX_RELAY_ALLOW_EMPTY_FILTERS=true
OUTBOX_RELAY_ALLOW_COMPLEX_FILTERS=true
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
OUTBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
INBOX_RELAY_NAME=Inbox Relay
INBOX_RELAY_NPUB=\$HAVEN_OWNER_NPUB
INBOX_RELAY_DESCRIPTION=Inbox relay for benchmarking
INBOX_RELAY_ICON=https://example.com/icon.png
INBOX_RELAY_EVENT_IP_LIMITER_TOKENS_PER_INTERVAL=1000
INBOX_RELAY_EVENT_IP_LIMITER_INTERVAL=1
INBOX_RELAY_EVENT_IP_LIMITER_MAX_TOKENS=5000
INBOX_RELAY_ALLOW_EMPTY_FILTERS=true
INBOX_RELAY_ALLOW_COMPLEX_FILTERS=true
INBOX_RELAY_CONNECTION_RATE_LIMITER_TOKENS_PER_INTERVAL=500
INBOX_RELAY_CONNECTION_RATE_LIMITER_INTERVAL=1
INBOX_RELAY_CONNECTION_RATE_LIMITER_MAX_TOKENS=2000
INBOX_PULL_INTERVAL_SECONDS=600
IMPORT_START_DATE=2023-01-20
IMPORT_OWNER_NOTES_FETCH_TIMEOUT_SECONDS=60
IMPORT_TAGGED_NOTES_FETCH_TIMEOUT_SECONDS=120
IMPORT_SEED_RELAYS_FILE=/app/relays_import.json
BACKUP_PROVIDER=none
BACKUP_INTERVAL_HOURS=24
BLASTR_RELAYS_FILE=/app/relays_blastr.json
BLASTR_TIMEOUT_SECONDS=5
WOT_DEPTH=3
WOT_MINIMUM_FOLLOWERS=0
WOT_FETCH_TIMEOUT_SECONDS=30
WOT_REFRESH_INTERVAL=24h
WHITELISTED_NPUBS_FILE=
BLACKLISTED_NPUBS_FILE=
HAVEN_LOG_LEVEL=INFO
EOF

    chmod -R a+rwX /root/haven-bench

    docker run -d --name haven \
      --ulimit nofile=262144:262144 \
      -p 3355:3355 \
      --env-file /root/haven-bench/haven.env \
      -v /root/haven-bench/db:/app/db \
      -v /root/haven-bench/blossom:/app/blossom \
      -v /root/haven-bench/templates:/app/templates \
      -v /root/haven-bench/relays_import.json:/app/relays_import.json \
      -v /root/haven-bench/relays_blastr.json:/app/relays_blastr.json \
      -v /root/haven-bench/blacklisted_npubs.json:/app/blacklisted_npubs.json \
      -v /root/haven-bench/whitelisted_npubs.json:/app/whitelisted_npubs.json \
      "\$HAVEN_IMAGE" >/dev/null

    wait_port 3355 120 haven
    ;;

  wipe-data-parrhesia-pg)
    docker exec pg psql -U parrhesia -d parrhesia -c \
      "TRUNCATE event_ids, event_tags, events, replaceable_event_state, addressable_event_state CASCADE"
    ;;

  wipe-data-parrhesia-memory)
    docker restart parrhesia
    wait_http "http://127.0.0.1:4413/health" 120 parrhesia
    ;;

  wipe-data-strfry)
    docker stop strfry
    rm -rf /root/strfry-data/strfry/*
    docker start strfry
    wait_port 7777 60 strfry
    ;;

  wipe-data-nostr-rs-relay)
    docker rm -f nostr-rs
    docker run -d --name nostr-rs \
      --ulimit nofile=262144:262144 \
      -p 8080:8080 \
      -v /root/nostr-rs.toml:/usr/src/app/config.toml:ro \
      "\$NOSTR_RS_IMAGE" >/dev/null
    wait_http "http://127.0.0.1:8080/" 60 nostr-rs
    ;;

  wipe-data-nostream)
    docker exec nostream-db psql -U nostr_ts_relay -d nostr_ts_relay -c \
      "TRUNCATE events CASCADE"
    ;;

  wipe-data-haven)
    docker stop haven
    rm -rf /root/haven-bench/db/*
    docker start haven
    wait_port 3355 120 haven
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
mode="\${2:-all}"

if [[ -z "\$relay_url" ]]; then
  echo "usage: cloud-bench-client.sh <relay-url> [connect|echo|event|req|all]" >&2
  exit 1
fi

bench_bin="\${NOSTR_BENCH_BIN:-/usr/local/bin/nostr-bench}"
bench_threads="\${PARRHESIA_BENCH_THREADS:-0}"
client_nofile="\${PARRHESIA_BENCH_CLIENT_NOFILE:-262144}"

ulimit -n "\${client_nofile}" >/dev/null 2>&1 || true

run_connect() {
  echo "==> nostr-bench connect \${relay_url}"
  "\$bench_bin" connect --json \
    -c "\${PARRHESIA_BENCH_CONNECT_COUNT:-200}" \
    -r "\${PARRHESIA_BENCH_CONNECT_RATE:-100}" \
    -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "\${bench_threads}" \
    "\${relay_url}"
}

run_echo() {
  echo "==> nostr-bench echo \${relay_url}"
  "\$bench_bin" echo --json \
    -c "\${PARRHESIA_BENCH_ECHO_COUNT:-100}" \
    -r "\${PARRHESIA_BENCH_ECHO_RATE:-50}" \
    -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "\${bench_threads}" \
    --size "\${PARRHESIA_BENCH_ECHO_SIZE:-512}" \
    "\${relay_url}"
}

run_event() {
  echo "==> nostr-bench event \${relay_url}"
  "\$bench_bin" event --json \
    -c "\${PARRHESIA_BENCH_EVENT_COUNT:-100}" \
    -r "\${PARRHESIA_BENCH_EVENT_RATE:-50}" \
    -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "\${bench_threads}" \
    "\${relay_url}"
}

run_req() {
  echo "==> nostr-bench req \${relay_url}"
  "\$bench_bin" req --json \
    -c "\${PARRHESIA_BENCH_REQ_COUNT:-100}" \
    -r "\${PARRHESIA_BENCH_REQ_RATE:-50}" \
    -k "\${PARRHESIA_BENCH_KEEPALIVE_SECONDS:-5}" \
    -t "\${bench_threads}" \
    --limit "\${PARRHESIA_BENCH_REQ_LIMIT:-10}" \
    "\${relay_url}"
}

case "\$mode" in
  connect) run_connect ;;
  echo)    run_echo ;;
  event)   run_event ;;
  req)     run_req ;;
  all)     run_connect; echo; run_echo; echo; run_event; echo; run_req ;;
  *)       echo "unknown mode: \$mode" >&2; exit 1 ;;
esac
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

function sum(values) {
  const valid = values.filter((v) => Number.isFinite(v));
  if (valid.length === 0) return NaN;
  return valid.reduce((a, b) => a + b, 0);
}

function throughputFromSection(section) {
  const elapsedMs = Number(section?.elapsed ?? NaN);
  const complete = Number(section?.message_stats?.complete ?? NaN);
  const totalBytes = Number(section?.message_stats?.size ?? NaN);

  const cumulativeTps =
    Number.isFinite(elapsedMs) && elapsedMs > 0 && Number.isFinite(complete)
      ? complete / (elapsedMs / 1000)
      : NaN;

  const cumulativeMibs =
    Number.isFinite(elapsedMs) && elapsedMs > 0 && Number.isFinite(totalBytes)
      ? totalBytes / (1024 * 1024) / (elapsedMs / 1000)
      : NaN;

  const sampleTps = Number(section?.tps ?? NaN);
  const sampleMibs = Number(section?.size ?? NaN);

  return {
    tps: Number.isFinite(cumulativeTps) ? cumulativeTps : sampleTps,
    mibs: Number.isFinite(cumulativeMibs) ? cumulativeMibs : sampleMibs,
  };
}

function metricFromSections(sections) {
  const connect = sections?.connect?.connect_stats?.success_time || {};
  const echo = throughputFromSection(sections?.echo || {});
  const event = throughputFromSection(sections?.event || {});
  const req = throughputFromSection(sections?.req || {});

  return {
    connect_avg_ms: Number(connect.avg ?? NaN),
    connect_max_ms: Number(connect.max ?? NaN),
    echo_tps: echo.tps,
    echo_mibs: echo.mibs,
    event_tps: event.tps,
    event_mibs: event.mibs,
    req_tps: req.tps,
    req_mibs: req.mibs,
  };
}

function summariseFlatResults(results) {
  const byServer = new Map();

  for (const runEntry of results) {
    const serverName = runEntry.target;
    if (!byServer.has(serverName)) {
      byServer.set(serverName, []);
    }

    const clientSamples = (runEntry.clients || [])
      .filter((clientResult) => clientResult.status === "ok")
      .map((clientResult) => metricFromSections(clientResult.sections || {}));

    if (clientSamples.length === 0) {
      continue;
    }

    byServer.get(serverName).push({
      connect_avg_ms: mean(clientSamples.map((s) => s.connect_avg_ms)),
      connect_max_ms: mean(clientSamples.map((s) => s.connect_max_ms)),
      echo_tps: sum(clientSamples.map((s) => s.echo_tps)),
      echo_mibs: sum(clientSamples.map((s) => s.echo_mibs)),
      event_tps: sum(clientSamples.map((s) => s.event_tps)),
      event_mibs: sum(clientSamples.map((s) => s.event_mibs)),
      req_tps: sum(clientSamples.map((s) => s.req_tps)),
      req_mibs: sum(clientSamples.map((s) => s.req_mibs)),
    });
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
  for (const [serverName, runSamples] of byServer.entries()) {
    const summary = {};
    for (const key of metricKeys) {
      summary[key] = mean(runSamples.map((s) => s[key]));
    }
    out[serverName] = summary;
  }

  return out;
}

function summarisePhasedResults(results) {
  const byServer = new Map();

  for (const entry of results) {
    if (!byServer.has(entry.target)) byServer.set(entry.target, []);
    const phases = entry.phases;
    if (!phases) continue;

    const sample = {};

    // connect
    const connectClients = (phases.connect?.clients || [])
      .filter((c) => c.status === "ok")
      .map((c) => metricFromSections(c.sections || {}));
    if (connectClients.length > 0) {
      sample.connect_avg_ms = mean(connectClients.map((s) => s.connect_avg_ms));
      sample.connect_max_ms = mean(connectClients.map((s) => s.connect_max_ms));
    }

    // echo
    const echoClients = (phases.echo?.clients || [])
      .filter((c) => c.status === "ok")
      .map((c) => metricFromSections(c.sections || {}));
    if (echoClients.length > 0) {
      sample.echo_tps = sum(echoClients.map((s) => s.echo_tps));
      sample.echo_mibs = sum(echoClients.map((s) => s.echo_mibs));
    }

    // Per-level req and event metrics
    for (const level of ["empty", "warm", "hot"]) {
      const phase = phases[level];
      if (!phase) continue;

      const reqClients = (phase.req?.clients || [])
        .filter((c) => c.status === "ok")
        .map((c) => metricFromSections(c.sections || {}));
      if (reqClients.length > 0) {
        sample[`req_${level}_tps`] = sum(reqClients.map((s) => s.req_tps));
        sample[`req_${level}_mibs`] = sum(reqClients.map((s) => s.req_mibs));
      }

      const eventClients = (phase.event?.clients || [])
        .filter((c) => c.status === "ok")
        .map((c) => metricFromSections(c.sections || {}));
      if (eventClients.length > 0) {
        sample[`event_${level}_tps`] = sum(eventClients.map((s) => s.event_tps));
        sample[`event_${level}_mibs`] = sum(eventClients.map((s) => s.event_mibs));
      }
    }

    byServer.get(entry.target).push(sample);
  }

  const out = {};
  for (const [name, samples] of byServer.entries()) {
    if (samples.length === 0) continue;
    const allKeys = new Set(samples.flatMap((s) => Object.keys(s)));
    const summary = {};
    for (const key of allKeys) {
      summary[key] = mean(samples.map((s) => s[key]).filter((v) => v !== undefined));
    }
    out[name] = summary;
  }

  return out;
}

function summariseServersFromResults(results) {
  const isPhased = results.some((r) => r.mode === "phased");
  return isPhased ? summarisePhasedResults(results) : summariseFlatResults(results);
}

// Count events successfully written by event benchmarks across all clients.
function countEventsWritten(clientResults) {
  let total = 0;
  for (const cr of clientResults) {
    if (cr.status !== "ok") continue;
    const eventSection = cr.sections?.event;
    if (eventSection?.message_stats?.complete) {
      total += Number(eventSection.message_stats.complete) || 0;
    }
  }
  return total;
}

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

      const eventConnections = 1;
      const eventKeepalive = Math.max(5, Math.ceil(desiredEvents / SEED_EVENT_RATE));
      const eventRate = Math.max(1, Math.ceil(desiredEvents / eventKeepalive));
      const projectedEvents = eventConnections * eventRate * eventKeepalive;

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
        const acked = Number(parsed?.event?.message_stats?.complete) || 0;

        return {
          client_name: client.name,
          client_ip: client.ip,
          status: "ok",
          desired_events: desiredEvents,
          projected_events: projectedEvents,
          event_connections: eventConnections,
          event_rate: eventRate,
          event_keepalive_seconds: eventKeepalive,
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
}) {
  if (targetCount <= 0) return { eventsInDb, seeded: 0, wiped: false };

  let wiped = false;
  if (eventsInDb > targetCount) {
    console.log(`[fill] ${target}: have ${eventsInDb} > ${targetCount}, wiping and reseeding`);
    const wipeCmd = `wipe-data-${target}`;
    await sshExec(serverIp, keyPath, `${serverEnvPrefix} /root/cloud-bench-server.sh ${shellEscape(wipeCmd)}`);
    eventsInDb = 0;
    wiped = true;
  }

  const tolerance = Math.max(1, Math.floor(targetCount * SEED_TOLERANCE_RATIO));
  let deficit = targetCount - eventsInDb;

  if (deficit <= tolerance) {
    console.log(
      `[fill] ${target}: already within tolerance (${eventsInDb}/${targetCount}, tolerance=${tolerance}), skipping`,
    );
    return { eventsInDb, seeded: 0, wiped };
  }

  console.log(
    `[fill] ${target}:${phase}: seeding to ~${targetCount} events from ${eventsInDb} (deficit=${deficit}, tolerance=${tolerance})`,
  );

  let seededTotal = 0;

  for (let round = 1; round <= SEED_MAX_ROUNDS; round += 1) {
    if (deficit <= tolerance) break;

    const roundStartMs = Date.now();
    const roundResult = await runClientSeedingRound({
      target,
      phase,
      round,
      deficit,
      clientInfos,
      keyPath,
      relayUrl,
      artifactDir,
      threads,
    });

    const elapsedSec = (Date.now() - roundStartMs) / 1000;
    const eventsPerSec = elapsedSec > 0 ? Math.round(roundResult.acked / elapsedSec) : 0;

    eventsInDb += roundResult.acked;
    seededTotal += roundResult.acked;
    deficit = targetCount - eventsInDb;

    console.log(
      `[fill] ${target}:${phase} round ${round}: acked ${roundResult.acked} (desired=${roundResult.desired}, projected=${roundResult.projected}) in ${elapsedSec.toFixed(1)}s (${eventsPerSec} events/s), now ~${eventsInDb}/${targetCount}`,
    );

    if (roundResult.acked <= 0) {
      console.warn(`[fill] ${target}:${phase} round ${round}: no progress, stopping early`);
      break;
    }
  }

  const remaining = Math.max(0, targetCount - eventsInDb);
  if (remaining > tolerance) {
    console.warn(
      `[fill] ${target}:${phase}: remaining deficit ${remaining} exceeds tolerance ${tolerance} after ${SEED_MAX_ROUNDS} rounds`,
    );
  }

  return { eventsInDb, seeded: seededTotal, wiped };
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

  const datacenterChoice = await chooseDatacenter(opts);
  opts.datacenter = datacenterChoice.name;
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

    console.log("[phase] wait for SSH");
    await Promise.all([
      waitForSsh(serverIp, keyPath),
      ...clientInfos.map((client) => waitForSsh(client.ip, keyPath)),
    ]);

    console.log("[phase] install runtime dependencies on server node");
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

    console.log("[phase] minimal client setup (no apt install)");
    const clientBootstrapCmd = [
      "set -euo pipefail",
      "mkdir -p /usr/local/bin",
      "sysctl -w net.ipv4.ip_local_port_range='10000 65535' >/dev/null || true",
      "sysctl -w net.core.somaxconn=65535 >/dev/null || true",
      "bash --version",
      "uname -m",
    ].join("; ");

    await Promise.all(clientInfos.map((client) => sshExec(client.ip, keyPath, clientBootstrapCmd, { stdio: "inherit" })));

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

    console.log(`[phase] benchmark execution (mode=${opts.quick ? "quick" : "phased"})`);

    for (let runIndex = 1; runIndex <= opts.runs; runIndex += 1) {
      const runTargets = shuffled(opts.targets);
      targetOrderPerRun.push({ run: runIndex, targets: runTargets });
      console.log(`[bench] run ${runIndex}/${opts.runs} target-order=${runTargets.join(",")}`);

      for (const target of runTargets) {
        console.log(`[bench] run ${runIndex}/${opts.runs} target=${target}`);

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
          eventsInDb += countEventsWritten(emptyEventResults);
          console.log(`[bench] ${target}: ~${eventsInDb} events in DB after empty phase`);

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
          eventsInDb += countEventsWritten(warmEventResults);

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

    console.log("[phase] final server cleanup (containers)");
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
