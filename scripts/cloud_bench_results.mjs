// cloud_bench_results.mjs — benchmark output parsing and result aggregation.
//
// Extracted from cloud_bench_orchestrate.mjs to keep the orchestrator focused
// on provisioning and execution flow.

export function parseNostrBenchSections(output) {
  const lines = output.split(/\r?\n/);
  let section = null;
  const parsed = {};

  for (const lineRaw of lines) {
    const line = lineRaw.trim();
    const header = line.match(/^==>\s+nostr-bench\s+(connect|echo|event|req|seed)\s+/);
    if (header) {
      section = header[1];
      continue;
    }

    if (!line.startsWith("{")) continue;

    try {
      const json = JSON.parse(line);
      if (!section) continue;

      if (section === "seed" && json?.type === "seed_final") {
        parsed.seed_final = json;
        continue;
      }

      const existing = parsed[section];
      if (!existing) {
        parsed[section] = json;
        continue;
      }

      if (existing?.type === "final" && json?.type !== "final") {
        continue;
      }

      parsed[section] = json;
    } catch {
      // ignore noisy non-json lines
    }
  }

  return parsed;
}

export function mean(values) {
  const valid = values.filter((v) => Number.isFinite(v));
  if (valid.length === 0) return NaN;
  return valid.reduce((a, b) => a + b, 0) / valid.length;
}

export function sum(values) {
  const valid = values.filter((v) => Number.isFinite(v));
  if (valid.length === 0) return NaN;
  return valid.reduce((a, b) => a + b, 0);
}

export function throughputFromSection(section, options = {}) {
  const { preferAccepted = false } = options;

  const elapsedMs = Number(section?.elapsed ?? NaN);
  const accepted = Number(section?.message_stats?.accepted ?? NaN);
  const complete = Number(section?.message_stats?.complete ?? NaN);
  const effectiveCount =
    preferAccepted && Number.isFinite(accepted)
      ? accepted
      : complete;
  const totalBytes = Number(section?.message_stats?.size ?? NaN);

  const cumulativeTps =
    Number.isFinite(elapsedMs) && elapsedMs > 0 && Number.isFinite(effectiveCount)
      ? effectiveCount / (elapsedMs / 1000)
      : NaN;

  const cumulativeMibs =
    Number.isFinite(elapsedMs) && elapsedMs > 0 && Number.isFinite(totalBytes)
      ? totalBytes / (1024 * 1024) / (elapsedMs / 1000)
      : NaN;

  const sampleTps = Number(
    preferAccepted
      ? section?.accepted_tps ?? section?.tps
      : section?.tps,
  );
  const sampleMibs = Number(section?.size ?? NaN);

  return {
    tps: Number.isFinite(cumulativeTps) ? cumulativeTps : sampleTps,
    mibs: Number.isFinite(cumulativeMibs) ? cumulativeMibs : sampleMibs,
  };
}

function messageCounter(section, field) {
  const value = Number(section?.message_stats?.[field]);
  return Number.isFinite(value) ? value : 0;
}

export function metricFromSections(sections) {
  const connect = sections?.connect?.connect_stats?.success_time || {};
  const echo = throughputFromSection(sections?.echo || {});
  const eventSection = sections?.event || {};
  const event = throughputFromSection(eventSection, { preferAccepted: true });
  const req = throughputFromSection(sections?.req || {});

  return {
    connect_avg_ms: Number(connect.avg ?? NaN),
    connect_max_ms: Number(connect.max ?? NaN),
    echo_tps: echo.tps,
    echo_mibs: echo.mibs,
    event_tps: event.tps,
    event_mibs: event.mibs,
    event_notice: messageCounter(eventSection, "notice"),
    event_auth_challenge: messageCounter(eventSection, "auth_challenge"),
    event_reply_unrecognized: messageCounter(eventSection, "reply_unrecognized"),
    event_ack_timeout: messageCounter(eventSection, "ack_timeout"),
    req_tps: req.tps,
    req_mibs: req.mibs,
  };
}

export function summariseFlatResults(results) {
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
      event_notice: sum(clientSamples.map((s) => s.event_notice)),
      event_auth_challenge: sum(clientSamples.map((s) => s.event_auth_challenge)),
      event_reply_unrecognized: sum(clientSamples.map((s) => s.event_reply_unrecognized)),
      event_ack_timeout: sum(clientSamples.map((s) => s.event_ack_timeout)),
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
    "event_notice",
    "event_auth_challenge",
    "event_reply_unrecognized",
    "event_ack_timeout",
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

export function summarisePhasedResults(results) {
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
    for (const level of ["cold", "warm", "hot"]) {
      const phase = phases[level] || (level === "cold" ? phases.empty : undefined);
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
        sample[`event_${level}_notice`] = sum(eventClients.map((s) => s.event_notice));
        sample[`event_${level}_auth_challenge`] = sum(
          eventClients.map((s) => s.event_auth_challenge),
        );
        sample[`event_${level}_reply_unrecognized`] = sum(
          eventClients.map((s) => s.event_reply_unrecognized),
        );
        sample[`event_${level}_ack_timeout`] = sum(
          eventClients.map((s) => s.event_ack_timeout),
        );
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

export function summariseServersFromResults(results) {
  const isPhased = results.some((r) => r.mode === "phased");
  return isPhased ? summarisePhasedResults(results) : summariseFlatResults(results);
}

// Count events successfully written by event benchmarks across all clients.
export function countEventsWritten(clientResults) {
  let total = 0;
  for (const cr of clientResults) {
    if (cr.status !== "ok") continue;
    const eventSection = cr.sections?.event;
    if (!eventSection?.message_stats) continue;

    const accepted = Number(eventSection.message_stats.accepted);
    if (Number.isFinite(accepted)) {
      total += Math.max(0, accepted);
      continue;
    }

    const complete = Number(eventSection.message_stats.complete) || 0;
    const error = Number(eventSection.message_stats.error) || 0;
    total += Math.max(0, complete - error);
  }
  return total;
}
