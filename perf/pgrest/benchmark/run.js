import { existsSync, readFileSync, rmSync, writeFileSync } from "fs";
import { join } from "path";
import { spawn } from "bun";
import { parseBenchmarkArgs, printBenchmarkHelp } from "../../common/benchmark_cli.js";
import { ensureBuild, resetRuntimeDir, startNginz, stopNginz } from "../../common/nginz.js";
import { summarizeSamples, printSummary } from "../../common/report.js";
import { getFreePort, run, runResult, ensureDockerContainerRunning, ensureHostPortOpen, waitForHttp } from "../../common/system.js";
import { captureCommandArtifact, captureEnvironmentArtifact, copyRuntimeLogs, createRunArtifacts, sanitizeArtifactTag, updateManifest, writeJsonArtifact, writeManifest } from "../../common/artifacts.js";
import { captureSnapshotSummary, startProfiling, stopProfiling, writeSnapshotSummary } from "../../common/profiling.js";
import { SCENARIOS, getScenario } from "./scenarios.js";
import { validateScenarioPair } from "./validate.js";

const MODULE = "pgrest";
const PG_CONTAINER = process.env.PGREST_BENCH_PG_CONTAINER || "pg18";
const PG_USER = "nginz_test";
const PG_PASSWORD = "nginz_test_pass";
const PERF_DIR = join(process.cwd(), "perf", "pgrest");
const BENCH_DIR = join(PERF_DIR, "benchmark");
const OUTPUT_DIR = join(BENCH_DIR, "output");
const FIXTURES_SQL = readFileSync(join(BENCH_DIR, "fixtures.sql"), "utf8");

function psqlAdmin(sql) {
  run(["sudo", "docker", "exec", "-i", PG_CONTAINER, "psql", "-U", "postgres"], Buffer.from(sql));
}

function psqlDb(sql) {
  run(["sudo", "docker", "exec", "-i", PG_CONTAINER, "psql", "-U", PG_USER, "-d", activeRuntime.database], Buffer.from(sql));
}

function ensureBenchmarkDatabase() {
  psqlAdmin(`DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_USER}') THEN CREATE USER ${PG_USER} WITH PASSWORD '${PG_PASSWORD}'; END IF; END $$;`);
  run(["sudo", "docker", "exec", PG_CONTAINER, "dropdb", "-U", "postgres", "--if-exists", activeRuntime.database]);
  run(["sudo", "docker", "exec", PG_CONTAINER, "createdb", "-U", "postgres", `--owner=${PG_USER}`, activeRuntime.database]);
  psqlDb(FIXTURES_SQL);
}

function cleanupBenchmarkDatabase() {
  if (process.env.PGREST_BENCH_KEEP_DB) return;
  try {
    run(["sudo", "docker", "exec", PG_CONTAINER, "dropdb", "-U", "postgres", "--if-exists", activeRuntime.database]);
  } catch {
    // ignore cleanup failure
  }
}

function resolvePostgrestBin() {
  return process.env.POSTGREST_BIN || "postgrest";
}

function buildPgrestBaseUrl() {
  return `http://127.0.0.1:${activeRuntime.nginzPort}/api`;
}

function buildPostgrestBaseUrl() {
  return `http://127.0.0.1:${activeRuntime.postgrestPort}`;
}

function buildPostgrestAdminBaseUrl() {
  return `http://127.0.0.1:${activeRuntime.postgrestAdminPort}`;
}

function buildNginzConfig() {
  const configPath = join(activeArtifacts.runtimeDir, "nginx.conf");
  const config = `daemon off;\nerror_log logs/error.log notice;\npid logs/nginx.pid;\n\nevents {\n    worker_connections 256;\n}\n\nhttp {\n    access_log logs/access.log;\n\n    server {\n        listen ${activeRuntime.nginzPort};\n\n        location /api/ {\n            pgrest_pass \"host=127.0.0.1 port=5432 dbname=${activeRuntime.database} user=${PG_USER} password=${PG_PASSWORD}\";\n            pgrest_schemas \"public\";\n            pgrest_pool_size 32;\n        }\n    }\n}\n`;
  writeFileSync(configPath, config);
  return configPath;
}

function buildPostgrestConfig() {
  const configPath = join(activeArtifacts.runtimeDir, "postgrest.conf");
  const config = [
    `db-uri = "postgresql://${PG_USER}:${PG_PASSWORD}@127.0.0.1:5432/${activeRuntime.database}"`,
    `db-schemas = "public"`,
    `db-anon-role = "${PG_USER}"`,
    `server-host = "127.0.0.1"`,
    `server-port = ${activeRuntime.postgrestPort}`,
    `admin-server-port = ${activeRuntime.postgrestAdminPort}`,
    `log-level = "warn"`,
  ].join("\n");
  writeFileSync(configPath, `${config}\n`);
  return configPath;
}

let activeArtifacts = null;
let activeRuntime = null;

async function startPostgrest() {
  const bin = resolvePostgrestBin();
  const preflight = runResult([bin, "--help"]);
  if (preflight.exitCode !== 0) {
    throw new Error(`PostgREST executable is not runnable: ${bin}\n${preflight.stdout}${preflight.stderr}`.trim());
  }

  const configPath = buildPostgrestConfig();
  const processRef = spawn([bin, configPath], {
    stdout: "inherit",
    stderr: "inherit",
    cwd: process.cwd(),
    env: process.env,
  });
  await waitForPostgrestReady(processRef);
  return processRef;
}

async function waitForPostgrestReady(processRef, timeout = 10000) {
  const start = Date.now();
  const readyUrl = `${buildPostgrestAdminBaseUrl()}/ready`;
  const probeUrl = `${buildPostgrestBaseUrl()}/bench_users?select=id,org_id,name,email,status,created_at&order=id.asc&limit=1`;

  while (Date.now() - start < timeout) {
    if (processRef.exitCode != null) {
      throw new Error(`PostgREST exited before readiness completed (exit ${processRef.exitCode})`);
    }

    const ready = await fetchIfHttp200(readyUrl);
    if (ready.ok) {
      const probe = await fetchIfHttp200(probeUrl);
      if (probe.ok) {
        return;
      }
    }

    await Bun.sleep(50);
  }

  throw new Error(`Timeout waiting for PostgREST readiness via ${readyUrl} and ${probeUrl}`);
}

async function fetchIfHttp200(url) {
  try {
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 200);
    const response = await fetch(url, { signal: controller.signal });
    clearTimeout(timeoutId);
    return { ok: response.status === 200, status: response.status };
  } catch {
    return { ok: false, status: null };
  }
}

async function stopProcess(processRef) {
  if (!processRef) return;
  processRef.kill("SIGTERM");
  try {
    await processRef.exited;
  } catch {
    // ignore
  }
}

function serviceBaseUrl(service) {
  return service === "pgrest" ? buildPgrestBaseUrl() : buildPostgrestBaseUrl();
}

function buildScenarioUrl(service, scenario) {
  return `${serviceBaseUrl(service)}${scenario.path}`;
}

async function fetchScenario(service, scenario) {
  const url = buildScenarioUrl(service, scenario);
  const started = performance.now();
  const response = await fetch(url, { headers: scenario.headers });
  const text = await response.text();
  const latencyMs = performance.now() - started;
  let json;
  try {
    json = text.length === 0 ? null : JSON.parse(text);
  } catch (error) {
    throw new Error(`Failed to parse JSON for ${service} ${scenario.name}: ${error.message}\n${text.slice(0, 200)}`);
  }
  return {
    status: response.status,
    text,
    json,
    payloadBytes: Buffer.byteLength(text),
    latencyMs,
  };
}

async function warmupService(service, scenario, warmupCount) {
  for (let i = 0; i < warmupCount; i += 1) {
    const result = await fetchScenario(service, scenario);
    if (result.status !== 200) {
      throw new Error(`Warmup failed for ${service} ${scenario.name}: HTTP ${result.status}`);
    }
  }
}

async function benchmarkScenario(service, scenario, requests, concurrency) {
  let nextIndex = 0;
  const samples = [];

  const started = performance.now();
  async function worker() {
    while (true) {
      const current = nextIndex;
      nextIndex += 1;
      if (current >= requests) return;
      const result = await fetchScenario(service, scenario);
      samples.push({
        status: result.status,
        latencyMs: result.latencyMs,
        payloadBytes: result.payloadBytes,
      });
    }
  }

  await Promise.all(Array.from({ length: concurrency }, () => worker()));
  const wallTimeMs = performance.now() - started;
  return {
    summary: summarizeSamples(samples, wallTimeMs),
    wallTimeMs,
  };
}

async function validateScenario(scenario, enabledServices) {
  if (enabledServices.length < 2) return;
  const [leftService, rightService] = enabledServices;
  const left = await fetchScenario(leftService, scenario);
  const right = await fetchScenario(rightService, scenario);
  validateScenarioPair(scenario, left, right);
}

async function main() {
  const options = parseBenchmarkArgs(process.argv.slice(2));
  if (options.help) {
    printBenchmarkHelp("perf/pgrest/benchmark/run.js");
    return;
  }

  const scenarios = options.scenario ? [getScenario(options.scenario)] : SCENARIOS;
  if (scenarios.some((scenario) => scenario == null)) {
    throw new Error(`Unknown scenario: ${options.scenario}`);
  }
  if (!["both", "pgrest", "postgrest"].includes(options.service)) {
    throw new Error(`Unsupported --service value: ${options.service}`);
  }

  const enabledServices = options.service === "both" ? ["pgrest", "postgrest"] : [options.service];
  const optimizeMode = process.env.ZIG_OPTIMIZE || "ReleaseSmall";
  let currentPhase = "setup";
  let currentScenario = null;
  let currentService = null;
  let currentConcurrency = null;
  let runStatus = "initialized";
  const results = [];

  ensureDockerContainerRunning(PG_CONTAINER);
  ensureHostPortOpen("127.0.0.1", 5432);
  ensureBuild();
  activeArtifacts = createRunArtifacts(OUTPUT_DIR, MODULE, optimizeMode, options.artifactTag);
  resetRuntimeDir(activeArtifacts.runtimeDir);
  const derivedDb = process.env.PGREST_BENCH_DB || `nginz_bench_${sanitizeArtifactTag(activeArtifacts.runId.toLowerCase())}`;
  const nginzPort = Number(process.env.PGREST_BENCH_PORT || await getFreePort());
  const postgrestPort = Number(process.env.POSTGREST_PORT || await getFreePort());
  const postgrestAdminPort = Number(process.env.POSTGREST_ADMIN_PORT || await getFreePort());
  activeRuntime = {
    database: derivedDb,
    nginzPort,
    postgrestPort,
    postgrestAdminPort,
  };
  writeJsonArtifact(activeArtifacts.environmentPath, captureEnvironmentArtifact(MODULE, { optimizeMode }));
  writeJsonArtifact(activeArtifacts.commandPath, captureCommandArtifact("perf/pgrest/benchmark/run.js", options));
  writeManifest(activeArtifacts, {
    module: MODULE,
    profiling_mode: options.profile,
    status: runStatus,
    runtime: activeRuntime,
  });
  ensureBenchmarkDatabase();

  let postgrestProcess = null;
  let nginzRuntime = null;
  try {
    currentPhase = "runtime-start";
    const nginzConfigPath = buildNginzConfig();
    nginzRuntime = await startNginz(nginzConfigPath, activeArtifacts.runtimeDir, activeRuntime.nginzPort, { resetRuntime: false });
    if (enabledServices.includes("postgrest")) {
      postgrestProcess = await startPostgrest();
    }

    currentPhase = "validation";
    for (const scenario of scenarios) {
      currentScenario = scenario.name;
      await validateScenario(scenario, enabledServices);
      currentPhase = "warmup";
      for (const service of enabledServices) {
        currentService = service;
        await warmupService(service, scenario, options.warmup);
      }
    }

    currentPhase = "timed-run";
    const profilingSession = await startProfiling({
      mode: options.profile,
      pids: [nginzRuntime?.pid, postgrestProcess?.pid],
      profilingDir: activeArtifacts.profilingDir,
    });

    try {
      for (const scenario of scenarios) {
        currentScenario = scenario.name;
        for (const concurrency of options.concurrency) {
          currentConcurrency = concurrency;
          for (const service of enabledServices) {
            currentService = service;
            const runResultData = await benchmarkScenario(service, scenario, options.requests, concurrency);
            results.push({
              service,
              scenario: scenario.name,
              description: scenario.description,
              query: scenario.path,
              concurrency,
              duration_ms: runResultData.wallTimeMs,
              summary: runResultData.summary,
            });
          }
        }
      }
    } finally {
      await stopProfiling(profilingSession, activeArtifacts.profilingDir);
    }

    writeJsonArtifact(activeArtifacts.benchmarkPath, {
      generated_at: new Date().toISOString(),
      module: MODULE,
      database: activeRuntime.database,
      runtime: activeRuntime,
      services: enabledServices,
      requests: options.requests,
      warmup: options.warmup,
      concurrency: options.concurrency,
      results,
    });
    runStatus = "completed";
    updateManifest(activeArtifacts, {
      status: runStatus,
      completed_at: new Date().toISOString(),
      result_count: results.length,
    });

    console.log(`Benchmark results written to ${activeArtifacts.runDir}`);
    printSummary(results);
  } catch (error) {
    runStatus = results.length > 0 ? "partial" : "failed";
    if (!existsSync(join(activeArtifacts.profilingDir, "summary.json"))) {
      const snapshot = captureSnapshotSummary({
        mode: options.profile,
        pids: [nginzRuntime?.pid, postgrestProcess?.pid],
        reason: `captured during ${currentPhase} failure`,
      });
      writeSnapshotSummary(activeArtifacts.profilingDir, snapshot);
    }
    writeJsonArtifact(activeArtifacts.failurePath, {
      generated_at: new Date().toISOString(),
      module: MODULE,
      status: runStatus,
      phase: currentPhase,
      scenario: currentScenario,
      service: currentService,
      concurrency: currentConcurrency,
      message: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack ?? null : null,
      partial_results_count: results.length,
      partial_results: results,
    });
    updateManifest(activeArtifacts, {
      status: runStatus,
      failed_at: new Date().toISOString(),
      failure_phase: currentPhase,
      result_count: results.length,
      runtime: activeRuntime,
    });
    throw error;
  } finally {
    await stopProcess(postgrestProcess);
    copyRuntimeLogs(activeArtifacts.runtimeDir, activeArtifacts.logsDir);
    await stopNginz();
    if (!options.keepRuntime && existsSync(activeArtifacts.runtimeDir)) {
      rmSync(activeArtifacts.runtimeDir, { recursive: true, force: true });
    }
    cleanupBenchmarkDatabase();
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
