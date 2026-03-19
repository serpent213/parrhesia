// cloud_bench_monitoring.mjs — Prometheus + node_exporter setup and metrics collection.
//
// Installs monitoring on ephemeral benchmark VMs, collects all Prometheus
// metrics for a given time window via the HTTP API, and stores them as
// JSON artifacts.

// Generate prometheus.yml scrape config.
export function makePrometheusConfig({ clientIps = [] } = {}) {
  const targets = [
    {
      job_name: "node-server",
      static_configs: [{ targets: ["localhost:9100"] }],
    },
    {
      job_name: "relay",
      metrics_path: "/metrics",
      static_configs: [{ targets: ["localhost:4413"] }],
    },
  ];

  if (clientIps.length > 0) {
    targets.push({
      job_name: "node-clients",
      static_configs: [{ targets: clientIps.map((ip) => `${ip}:9100`) }],
    });
  }

  const config = {
    global: {
      scrape_interval: "5s",
      evaluation_interval: "15s",
    },
    scrape_configs: targets,
  };

  // Produce minimal YAML by hand (avoids adding a yaml dep).
  const lines = [
    "global:",
    "  scrape_interval: 5s",
    "  evaluation_interval: 15s",
    "",
    "scrape_configs:",
  ];

  for (const sc of targets) {
    lines.push(`  - job_name: '${sc.job_name}'`);
    if (sc.metrics_path) {
      lines.push(`    metrics_path: '${sc.metrics_path}'`);
    }
    lines.push("    static_configs:");
    for (const st of sc.static_configs) {
      lines.push("      - targets:");
      for (const t of st.targets) {
        lines.push(`          - '${t}'`);
      }
    }
  }

  return lines.join("\n") + "\n";
}

// Install Prometheus + node_exporter on server, node_exporter on clients.
// `ssh` is an async function matching the sshExec(ip, keyPath, cmd, opts) signature.
export async function installMonitoring({ serverIp, clientIps = [], keyPath, ssh }) {
  const prometheusYml = makePrometheusConfig({ clientIps });

  // Server: install prometheus + node-exporter, write config, start
  console.log("[monitoring] installing prometheus + node-exporter on server");
  await ssh(serverIp, keyPath, [
    "export DEBIAN_FRONTEND=noninteractive",
    "apt-get update -qq",
    "apt-get install -y -qq prometheus prometheus-node-exporter >/dev/null 2>&1",
  ].join(" && "));

  // Write prometheus config
  const escapedYml = prometheusYml.replace(/'/g, "'\\''");
  await ssh(serverIp, keyPath, `cat > /etc/prometheus/prometheus.yml <<'PROMEOF'\n${prometheusYml}PROMEOF`);

  // Restart prometheus with the new config, ensure node-exporter is running
  await ssh(serverIp, keyPath, [
    "systemctl restart prometheus",
    "systemctl enable --now prometheus-node-exporter",
  ].join(" && "));

  // Clients: install node-exporter only (in parallel)
  if (clientIps.length > 0) {
    console.log(`[monitoring] installing node-exporter on ${clientIps.length} client(s)`);
    await Promise.all(
      clientIps.map((ip) =>
        ssh(ip, keyPath, [
          "export DEBIAN_FRONTEND=noninteractive",
          "apt-get update -qq",
          "apt-get install -y -qq prometheus-node-exporter >/dev/null 2>&1",
          "systemctl enable --now prometheus-node-exporter",
        ].join(" && "))
      )
    );
  }

  // Wait for Prometheus to start scraping
  console.log("[monitoring] waiting for Prometheus to initialise");
  await ssh(serverIp, keyPath,
    'for i in $(seq 1 30); do curl -sf http://localhost:9090/api/v1/query?query=up >/dev/null 2>&1 && exit 0; sleep 1; done; echo "prometheus not ready" >&2; exit 1'
  );

  console.log("[monitoring] monitoring active");
}

// Collect all Prometheus metrics for a time window.
// Returns the raw Prometheus API response JSON (matrix result type).
export async function collectMetrics({ serverIp, startTime, endTime, step = 5 }) {
  const params = new URLSearchParams({
    query: '{__name__=~".+"}',
    start: startTime,
    end: endTime,
    step: String(step),
  });

  const url = `http://${serverIp}:9090/api/v1/query_range?${params}`;

  try {
    const resp = await fetch(url, { signal: AbortSignal.timeout(60_000) });
    if (!resp.ok) {
      console.error(`[monitoring] Prometheus query failed: ${resp.status} ${resp.statusText}`);
      return null;
    }
    const body = await resp.json();
    if (body.status !== "success") {
      console.error(`[monitoring] Prometheus query error: ${body.error || "unknown"}`);
      return null;
    }
    return body.data;
  } catch (err) {
    console.error(`[monitoring] metrics collection failed: ${err.message}`);
    return null;
  }
}

// Stop monitoring daemons on server and clients.
export async function stopMonitoring({ serverIp, clientIps = [], keyPath, ssh }) {
  const allIps = [serverIp, ...clientIps];
  await Promise.all(
    allIps.map((ip) =>
      ssh(ip, keyPath, "systemctl stop prometheus prometheus-node-exporter 2>/dev/null; true").catch(() => {})
    )
  );
  console.log("[monitoring] monitoring stopped");
}
