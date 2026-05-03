import { existsSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { parseBenchmarkArgs, printBenchmarkHelp } from "../../common/benchmark_cli.js";
import { resetRuntimeDir, startNginz, stopNginz, getNginzPid } from "../../common/nginz.js";
import { summarizeSamples, printSummary } from "../../common/report.js";
import { getFreePort, run } from "../../common/system.js";
import {
  captureCommandArtifact,
  captureEnvironmentArtifact,
  copyRuntimeLogs,
  createRunArtifacts,
  writeJsonArtifact,
  writeManifest,
} from "../../common/artifacts.js";
import { startProfiling, stopProfiling } from "../../common/profiling.js";
import { SCENARIOS, getScenario } from "./scenarios.js";
import { validateScenario } from "./validate.js";
import { createHTTPMock } from "../../../tests/harness.js";

const MODULE = "upstream-balancer";
const PERF_DIR = join(process.cwd(), "perf", MODULE);
const BENCH_DIR = join(PERF_DIR, "benchmark");
const OUTPUT_DIR = join(BENCH_DIR, "output");

let activeRuntime = {};
let activeArtifacts = {};
let httpMock = null;

function buildNginzConfig(port, backendPort) {
  const configPath = join(activeArtifacts.runtimeDir, "nginx.conf");
  const config = [
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
    "    upstream backend {",
    "        upstream_balancer_sticky_cookie route;",
    "        upstream_balancer_sticky_header X-Sticky-Key;",
    "        upstream_balancer_fallback next;",
    "",
    "        server 127.0.0.1:" + backendPort + ";",
    "    }",
    "",
    "    server {",
    "        listen " + port + ";",
    "",
    "        location /bench/balancer {",
    "            proxy_pass http://backend;",
    "        }",
    "",
    "        location /bench/direct {",
    "            proxy_pass http://backend;",
    "        }",
    "",
    "        location / {",
    "            echozn healthy;",
    "        }",
    "    }",
    "}",
  ].join("\n");
  writeFileSync(configPath, config + "\n");
  return configPath;
}

// ── measurement ─────────────────────────────────────────────────────────

async function measureSamples({ url, init, requests, concurrency, warmup }) {
  if (warmup > 0) {
    const perWorker = Math.ceil(warmup / concurrency);
    const fns = Array(concurrency).fill(null).map(() => async () => {
      for (let i = 0; i < perWorker; i++) {
        try { await fetch(url, init); } catch {}
      }
    });
    await Promise.all(fns.map((fn) => fn()));
  }

  const samples = [];
  const perWorker = Math.ceil(requests / concurrency);
  const t0 = performance.now();

  const fns = Array(concurrency).fill(null).map(() => async () => {
    for (let i = 0; i < perWorker; i++) {
      const t1 = performance.now();
      let status = 0, bodyLen = 0;
      try {
        const res = await fetch(url, init);
        const buf = await res.arrayBuffer();
        status = res.status;
        bodyLen = buf.byteLength;
      } catch {}
      samples.push({ latencyMs: performance.now() - t1, payloadBytes: bodyLen, status });
    }
  });
  await Promise.all(fns.map((fn) => fn()));

  return summarizeSamples(samples, performance.now() - t0);
}

// ── main ────────────────────────────────────────────────────────────────

async function main() {
  if (process.argv.includes("--help")) {
    printBenchmarkHelp(import.meta.path, "nginz upstream-balancer module");
    process.exit(0);
  }

  const options = parseBenchmarkArgs(process.argv.slice(2));
  const scenarios = options.scenario
    ? [getScenario(options.scenario)].filter(Boolean)
    : SCENARIOS;
  if (scenarios.length === 0) { console.error("No scenarios"); process.exit(1); }
  const concurrencies = options.concurrency;

  // Build ReleaseSmall for perf
  console.log("Building nginz with -Doptimize=ReleaseSmall...");
  run(["zig", "build", "-Doptimize=ReleaseSmall"]);
  console.log("Build successful");

  // Start HTTP mock backend
  const backendPort = 19002;
  httpMock = createHTTPMock(backendPort);
  httpMock.get("/", {
    status: 200,
    body: { upstream: "ok", module: MODULE },
  });

  const optimizeMode = "ReleaseSmall";
  activeArtifacts = createRunArtifacts(OUTPUT_DIR, MODULE, optimizeMode, options.artifactTag);
  activeRuntime.nginzPort = await getFreePort();
  activeRuntime.dir = activeArtifacts.runtimeDir;

  resetRuntimeDir(activeArtifacts.runtimeDir);
  const configPath = buildNginzConfig(activeRuntime.nginzPort, backendPort);
  await startNginz(configPath, activeArtifacts.runtimeDir, activeRuntime.nginzPort, { resetRuntime: false });
  const nginzPid = getNginzPid();

  const baseUrl = `http://127.0.0.1:${activeRuntime.nginzPort}`;
  const results = [];

  console.log("Validating scenarios...");
  let allValid = true;
  for (const s of scenarios) {
    const v = await validateScenario(baseUrl, s);
    if (!v.ok) { console.error(`  FAIL ${s.name}: ${v.error}`); allValid = false; }
  }
  if (!allValid) { console.error("Validation failed"); process.exit(1); }
  console.log("  all scenarios valid");

  for (const scenario of scenarios) {
    for (const c of concurrencies) {
      console.log(`\n  ${scenario.name} c=${c}...`);
      const url = `${baseUrl}${scenario.path}`;
      const init = { method: scenario.method || "GET" };
      if (scenario.headers && Object.keys(scenario.headers).length > 0) {
        init.headers = scenario.headers;
      }

      try { await fetch(url, init); } catch {}

      const profilingSession = await startProfiling({
        mode: options.profile,
        pids: nginzPid ? [nginzPid] : [],
        profilingDir: activeArtifacts.profilingDir,
      });

      const summary = await measureSamples({
        url, init,
        requests: options.requests,
        concurrency: c,
        warmup: options.warmup,
      });

      results.push({ service: "nginz-upstream-balancer", scenario: scenario.name, concurrency: c, summary });

      await stopProfiling(profilingSession, activeArtifacts.profilingDir);
    }
  }

  writeJsonArtifact(activeArtifacts.benchmarkPath, results);
  writeJsonArtifact(activeArtifacts.environmentPath, captureEnvironmentArtifact(MODULE, { optimizeMode }));
  writeJsonArtifact(activeArtifacts.commandPath, captureCommandArtifact("perf/upstream-balancer/benchmark/run.js", options));
  copyRuntimeLogs(activeArtifacts.runtimeDir, activeArtifacts.logsDir);
  writeManifest(activeArtifacts, {});

  await stopNginz();
  httpMock.stop();

  if (!options.keepRuntime && existsSync(activeArtifacts.runtimeDir)) {
    rmSync(activeArtifacts.runtimeDir, { recursive: true, force: true });
  }

  // Restore debug build
  console.log("Restoring debug build...");
  run(["zig", "build"]);

  printSummary(results);
  console.log(`\nResults written to ${activeArtifacts.runDir}`);
}

main().catch((err) => { console.error(err); process.exit(1); });
