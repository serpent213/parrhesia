#!/usr/bin/env node

// Nostr event seeder — generates and publishes events matching nostr-bench
// patterns to a relay via WebSocket.
//
// Standalone:
//   node scripts/nostr_seed.mjs --url ws://127.0.0.1:4413/relay --count 10000 [--concurrency 8]
//
// As module:
//   import { seedEvents } from './nostr_seed.mjs';
//   const result = await seedEvents({ url, count, concurrency: 8 });

import { generateSecretKey, getPublicKey, finalizeEvent } from "nostr-tools/pure";
import WebSocket from "ws";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

// Matches nostr-bench util.rs:48-66 exactly.
function generateBenchEvent() {
  const sk = generateSecretKey();
  const pk = getPublicKey(sk);
  const benchTag = `nostr-bench-${Math.floor(Math.random() * 1000)}`;

  return finalizeEvent(
    {
      kind: 1,
      created_at: Math.floor(Date.now() / 1000),
      content: "This is a message from nostr-bench client",
      tags: [
        ["p", pk],
        [
          "e",
          "378f145897eea948952674269945e88612420db35791784abf0616b4fed56ef7",
        ],
        ["t", "nostr-bench-"],
        ["t", benchTag],
      ],
    },
    sk,
  );
}

/**
 * Seed exactly `count` events to a relay.
 *
 * Opens `concurrency` parallel WebSocket connections, generates events
 * matching nostr-bench patterns, sends them, and waits for OK acks.
 *
 * @param {object}   opts
 * @param {string}   opts.url          Relay WebSocket URL
 * @param {number}   opts.count        Number of events to send
 * @param {number}  [opts.concurrency] Parallel connections (default 8)
 * @param {function} [opts.onProgress] Called with (acked_so_far) periodically
 * @returns {Promise<{sent: number, acked: number, errors: number, elapsed_ms: number}>}
 */
export async function seedEvents({ url, count, concurrency = 8, onProgress }) {
  if (count <= 0) return { sent: 0, acked: 0, errors: 0, elapsed_ms: 0 };

  const startMs = Date.now();
  let sent = 0;
  let acked = 0;
  let errors = 0;
  let nextToSend = 0;

  // Claim the next event index atomically (single-threaded, but clear intent).
  function claimNext() {
    if (nextToSend >= count) return -1;
    return nextToSend++;
  }

  async function runWorker() {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      let pendingResolve = null;
      let closed = false;

      ws.on("error", (err) => {
        if (!closed) {
          closed = true;
          reject(err);
        }
      });

      ws.on("close", () => {
        closed = true;
        if (pendingResolve) pendingResolve();
        resolve();
      });

      ws.on("open", () => {
        sendNext();
      });

      ws.on("message", (data) => {
        const msg = data.toString();
        if (msg.includes('"OK"')) {
          if (msg.includes("true")) {
            acked++;
          } else {
            errors++;
          }
          if (onProgress && (acked + errors) % 10000 === 0) {
            onProgress(acked);
          }
          sendNext();
        }
      });

      function sendNext() {
        if (closed) return;
        const idx = claimNext();
        if (idx < 0) {
          closed = true;
          ws.close();
          return;
        }
        const event = generateBenchEvent();
        sent++;
        ws.send(JSON.stringify(["EVENT", event]));
      }
    });
  }

  const workers = [];
  const actualConcurrency = Math.min(concurrency, count);
  for (let i = 0; i < actualConcurrency; i++) {
    workers.push(runWorker());
  }

  await Promise.allSettled(workers);

  return {
    sent,
    acked,
    errors,
    elapsed_ms: Date.now() - startMs,
  };
}

// CLI entrypoint
const isMain =
  process.argv[1] &&
  fileURLToPath(import.meta.url).endsWith(process.argv[1].replace(/^.*\//, ""));

if (isMain) {
  const { values } = parseArgs({
    options: {
      url: { type: "string" },
      count: { type: "string" },
      concurrency: { type: "string", default: "8" },
    },
    strict: false,
  });

  if (!values.url || !values.count) {
    console.error(
      "usage: node scripts/nostr_seed.mjs --url ws://... --count <n> [--concurrency <n>]",
    );
    process.exit(1);
  }

  const count = Number(values.count);
  const concurrency = Number(values.concurrency);

  if (!Number.isInteger(count) || count < 1) {
    console.error("--count must be a positive integer");
    process.exit(1);
  }

  console.log(
    `[seed] seeding ${count} events to ${values.url} (concurrency=${concurrency})`,
  );

  const result = await seedEvents({
    url: values.url,
    count,
    concurrency,
    onProgress: (n) => {
      process.stdout.write(`\r[seed] ${n}/${count} acked`);
    },
  });

  if (count > 500) process.stdout.write("\n");
  console.log(JSON.stringify(result));
}
