import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { parseBenchmarkArgs, printBenchmarkHelp } from "../../common/benchmark_cli.js";
import { ensureBuild, resetRuntimeDir, startNginz, stopNginz } from "../../common/nginz.js";
import { summarizeSamples, printSummary } from "../../common/report.js";
import { getFreePort } from "../../common/system.js";
import { captureCommandArtifact, captureEnvironmentArtifact, copyRuntimeLogs, createRunArtifacts, updateManifest, writeJsonArtifact, writeManifest } from "../../common/artifacts.js";
import { startProfiling, stopProfiling } from "../../common/profiling.js";
import { SCENARIOS, getScenario } from "./scenarios.js";
import { validateRuntime, validateScenario } from "./validate.js";

const MODULE = "dynamic-upstreams";
const PERF_DIR = join(process.cwd(), "perf", MODULE);
const BENCH_DIR = join(PERF_DIR, "benchmark");
const OUTPUT_DIR = join(BENCH_DIR, "output");
const EVENTS_CHANNEL = "milestone2";
const UPSTREAM_NAME = "combo_backend";

let activeArtifacts = null;
let activeRuntime = null;
let backendServers = [];

function buildNginzConfig() {
  const configPath = join(activeArtifacts.runtimeDir, "nginx.conf");
  const [backendA, backendB] = activeRuntime.backends;
  const config = [
    "worker_processes 2;",
    "daemon off;",
    "error_log logs/error.log notice;",
    "pid logs/nginx.pid;",
    "",
    "events {",
    "    worker_connections 256;",
    "}",
    "",
    "http {",
    "    access_log logs/access.log;",
    "    variables_hash_max_size 2048;",
    "    variables_hash_bucket_size 128;",
    "",
    `    upstream ${UPSTREAM_NAME} {`,
    "        upstream_balancer_sticky_cookie route;",
    "        upstream_balancer_fallback next;",
    "",
    "        health_upstream_probe_interval 250ms;",
    "        health_upstream_probe_timeout 100ms;",
    "        health_upstream_probe_fails 1;",
    "        health_upstream_probe_passes 1;",
    "        health_upstream_probe_slow_start 500ms;",
    "",
    `        health_upstream_peer_probe 127.0.0.1:${backendA.port} http://127.0.0.1:${backendA.port}/probe;`,
    `        health_upstream_peer_probe 127.0.0.1:${backendB.port} http://127.0.0.1:${backendB.port}/probe;`,
    "",
    `        server 127.0.0.1:${backendA.port};`,
    "        dynamic_upstreams_managed;",
    "    }",
    "",
    "    server {",
    `        listen ${activeRuntime.nginzPort};`,
    "",
    "        location /app/ {",
    "            cache_tags;",
    `            proxy_pass http://${UPSTREAM_NAME};`,
    "            proxy_pass_header Cache-Tag;",
    "            add_header X-Upstream-Addr $upstream_addr always;",
    "        }",
    "",
    "        location /dynamic-upstreams {",
    "            dynamic_upstreams_api;",
    `            dynamic_upstreams_target ${UPSTREAM_NAME};`,
    "            dynamic_upstreams_source static;",
    `            dynamic_upstreams_worker_events_channel ${EVENTS_CHANNEL};`,
    "        }",
    "",
    "        location /worker-events {",
    "            worker_events_api;",
    "            worker_events_zone milestone2_bus;",
    `            worker_events_channel ${EVENTS_CHANNEL};`,
    "            worker_events_ring_size 256;",
    "        }",
    "",
    "        location /cache-purge {",
    "            cache_purge_api;",
    "            cache_purge_zone default;",
    "            cache_purge_match exact;",
    "            cache_purge_authorize off;",
    "            cache_purge_max_keys 16;",
    `            cache_purge_worker_events_channel ${EVENTS_CHANNEL};`,
    "        }",
    "",
    "        location /health {",
    "            health_status;",
    "        }",
    "    }",
    "}",
  ].join("\n");
  writeFileSync(configPath, `${config}\n`);
  return configPath;
}

function getNginzPid() {
  try {
    const pidPath = join(activeArtifacts.runtimeDir, "logs", "nginx.pid");
    return parseInt(readFileSync(pidPath, "utf8").trim(), 10);
  } catch {
    return null;
  }
}

function createBackendServer(name, port) {
  let healthy = true;
  const server = Bun.serve({
    port,
    hostname: "127.0.0.1",
    fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/probe") {
        return new Response(healthy ? "ok" : "down", {
          status: healthy ? 200 : 503,
          headers: { "Content-Type": "text/plain" },
        });
      }

      const tag = url.searchParams.get("tag") ?? `backend-${name}`;
      const body = JSON.stringify({
        backend: name,
        path: url.pathname,
        tag,
        worker: "mock",
      });
      return new Response(body, {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "Cache-Tag": `${tag}, combo, backend-${name}`,
          "X-Backend-Id": name,
        },
      });
    },
  });

  return {
    name,
    port,
    setHealthy(nextHealthy) {
      healthy = nextHealthy;
    },
    stop() {
      server.stop(true);
    },
  };
}

function scenarioRequestHeaders(headers = {}) {
  return {
    Accept: "application/json",
    ...headers,
  };
}

async function fetchText(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  return { response, text };
}

async function putSnapshot(peers) {
  const { response, text } = await fetchText(`${activeRuntime.baseUrl}/dynamic-upstreams`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ peers }),
  });
  if (response.status !== 200) {
    throw new Error(`snapshot activation failed: HTTP ${response.status}\n${text}`);
  }
  return text.length === 0 ? null : JSON.parse(text);
}

async function seedInitialSnapshot() {
  const peers = activeRuntime.backends.map((backend) => ({
    address: `127.0.0.1:${backend.port}`,
    weight: 1,
  }));
  await putSnapshot(peers);
}

function buildScenarioExecutors(baseScenario) {
  if (baseScenario.kind === "proxy-read") {
    return {
      ...baseScenario,
      async execute(context) {
        const started = performance.now();
        const { response, text } = await fetchText(`${context.baseUrl}${baseScenario.path}`, {
          headers: scenarioRequestHeaders(baseScenario.headers),
        });
        return {
          status: response.status,
          payloadBytes: Buffer.byteLength(text),
          latencyMs: performance.now() - started,
        };
      },
    };
  }

  if (baseScenario.kind === "capture-and-purge") {
    return {
      ...baseScenario,
      async execute(context, iteration) {
        const token = `bench-${Date.now()}-${iteration}`;
        const captureUrl = `${context.baseUrl}/app/cacheable?tag=${encodeURIComponent(token)}`;
        const started = performance.now();

        const capture = await fetchText(captureUrl, {
          headers: scenarioRequestHeaders(baseScenario.headers),
        });
        if (capture.response.status !== 200) {
          return {
            status: capture.response.status,
            payloadBytes: Buffer.byteLength(capture.text),
            latencyMs: performance.now() - started,
          };
        }

        const purge = await fetchText(`${context.baseUrl}/cache-purge`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            ...scenarioRequestHeaders(baseScenario.headers),
          },
          body: JSON.stringify({ targets: [token] }),
        });

        let purgeStatus = purge.response.status;
        try {
          const body = purge.text.length === 0 ? null : JSON.parse(purge.text);
          if (purge.response.status === 200 && body?.results?.[0]?.purged > 0) {
            purgeStatus = 200;
          } else if (purge.response.status === 200) {
            purgeStatus = 500;
          }
        } catch {
          purgeStatus = 500;
        }

        return {
          status: purgeStatus,
          payloadBytes: Buffer.byteLength(capture.text) + Buffer.byteLength(purge.text),
          latencyMs: performance.now() - started,
        };
      },
    };
  }

  throw new Error(`Unknown scenario kind: ${baseScenario.kind}`);
}

function resolveScenarios(requestedScenarioName) {
  const baseScenarios = requestedScenarioName
    ? [getScenario(requestedScenarioName)].filter(Boolean)
    : SCENARIOS;
  return baseScenarios.map(buildScenarioExecutors);
}

function sliceSlug(scenarioName, concurrency) {
  return `${scenarioName.replace(/[^a-z0-9._-]+/gi, "-").toLowerCase()}-c${concurrency}`;
}

function startSnapshotChurn() {
  let stopped = false;
  const payloads = [
    activeRuntime.backends.map((backend, index) => ({
      address: `127.0.0.1:${backend.port}`,
      weight: index === 0 ? 1 : 1,
    })),
    activeRuntime.backends.map((backend, index) => ({
      address: `127.0.0.1:${backend.port}`,
      weight: index === 0 ? 2 : 1,
    })),
  ];

  const task = (async () => {
    let index = 0;
    while (!stopped) {
      try {
        await putSnapshot(payloads[index % payloads.length]);
      } catch {
        // Keep churn best-effort so a single control-plane failure does not leak the loop.
      }
      index += 1;
      await Bun.sleep(200);
    }
  })();

  return async () => {
    stopped = true;
    await task;
  };
}

async function measureSamples({ scenario, requests, concurrency, warmup, context }) {
  for (let i = 0; i < warmup; i += 1) {
    await scenario.execute(context, i);
  }

  let nextIndex = 0;
  const samples = [];
  const started = performance.now();

  async function worker() {
    while (true) {
      const current = nextIndex;
      nextIndex += 1;
      if (current >= requests) {
        return;
      }
      samples.push(await scenario.execute(context, current));
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  return summarizeSamples(samples, performance.now() - started);
}

async function stopBackends() {
  for (const backend of backendServers) {
    try {
      backend.stop();
    } catch {
      // ignore shutdown failure
    }
  }
  backendServers = [];
}

async function main() {
  const options = parseBenchmarkArgs(process.argv.slice(2));
  if (options.help) {
    printBenchmarkHelp(import.meta.path);
    process.exit(0);
  }

  const scenarios = resolveScenarios(options.scenario);
  if (scenarios.length === 0) {
    throw new Error("No benchmark scenarios selected");
  }

  ensureBuild();

  const optimizeMode = process.env.ZIG_OPTIMIZE || "ReleaseSmall";
  activeArtifacts = createRunArtifacts(OUTPUT_DIR, MODULE, optimizeMode, options.artifactTag);
  writeManifest(activeArtifacts, { status: "initializing" });

  const nginzPort = await getFreePort();
  const backendPorts = [await getFreePort(), await getFreePort()];
  backendServers = [
    createBackendServer("a", backendPorts[0]),
    createBackendServer("b", backendPorts[1]),
  ];

  activeRuntime = {
    nginzPort,
    backends: backendServers,
    baseUrl: `http://127.0.0.1:${nginzPort}`,
    eventsChannel: EVENTS_CHANNEL,
    upstreamName: UPSTREAM_NAME,
  };

  let nginzStarted = false;
  try {
    resetRuntimeDir(activeArtifacts.runtimeDir);
    const configPath = buildNginzConfig();
    await startNginz(configPath, activeArtifacts.runtimeDir, nginzPort, { resetRuntime: false });
    nginzStarted = true;

    await seedInitialSnapshot();

    const runtimeValidation = await validateRuntime(activeRuntime);
    if (!runtimeValidation.ok) {
      throw new Error(`Runtime validation failed: ${runtimeValidation.error}`);
    }

    for (const scenario of scenarios) {
      const validation = await validateScenario(activeRuntime, scenario);
      if (!validation.ok) {
        throw new Error(`Scenario validation failed for ${scenario.name}: ${validation.error}`);
      }
    }

    const nginzPid = getNginzPid();
    const results = [];

    for (const scenario of scenarios) {
      for (const concurrency of options.concurrency) {
        let stopChurn = null;
        if (scenario.withChurn) {
          stopChurn = startSnapshotChurn();
        }

        const profilingDir = join(activeArtifacts.profilingDir, sliceSlug(scenario.name, concurrency));
        mkdirSync(profilingDir, { recursive: true });
        const profilingSession = await startProfiling({
          mode: options.profile,
          pids: nginzPid ? [nginzPid] : [],
          profilingDir,
        });
        const profilingPath = join("profiling", sliceSlug(scenario.name, concurrency));

        try {
          const summary = await measureSamples({
            scenario,
            requests: options.requests,
            concurrency,
            warmup: options.warmup,
            context: activeRuntime,
          });
          results.push({
            service: "milestone2-combo",
            scenario: scenario.name,
            concurrency,
            profiling_path: profilingPath,
            summary,
          });
        } finally {
          await stopProfiling(profilingSession, profilingDir);
          if (stopChurn) {
            await stopChurn();
          }
        }
      }
    }

    writeJsonArtifact(activeArtifacts.benchmarkPath, results);
    writeJsonArtifact(activeArtifacts.environmentPath, captureEnvironmentArtifact(MODULE, { optimizeMode }));
    writeJsonArtifact(activeArtifacts.commandPath, captureCommandArtifact("perf/dynamic-upstreams/benchmark/run.js", options));
    copyRuntimeLogs(activeArtifacts.runtimeDir, activeArtifacts.logsDir);
    updateManifest(activeArtifacts, { status: "completed" });

    printSummary(results);
    console.log(`\nResults written to ${activeArtifacts.runDir}`);
  } catch (error) {
    if (activeArtifacts?.runtimeDir && activeArtifacts?.logsDir) {
      copyRuntimeLogs(activeArtifacts.runtimeDir, activeArtifacts.logsDir);
    }
    writeJsonArtifact(activeArtifacts.failurePath, {
      generated_at: new Date().toISOString(),
      message: error instanceof Error ? error.message : String(error),
    });
    updateManifest(activeArtifacts, { status: "failed" });
    throw error;
  } finally {
    if (nginzStarted) {
      await stopNginz();
    }
    await stopBackends();

    if (!options.keepRuntime && activeArtifacts?.runtimeDir && existsSync(activeArtifacts.runtimeDir)) {
      rmSync(activeArtifacts.runtimeDir, { recursive: true, force: true });
    }
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
