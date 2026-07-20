import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { existsSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";
import {
  startNginz,
  stopNginz,
  cleanupRuntime as cleanupHarnessRuntime,
  ensurePortFree,
  TEST_URL,
} from "../harness.js";

const MODULE = "acme";
const DOMAIN = "live-acme.test";
const PEBBLE_IMAGE = "ghcr.io/letsencrypt/pebble:latest";
const CHALLTESTSRV_IMAGE = "ghcr.io/letsencrypt/pebble-challtestsrv:latest";
// Stable names so a crashed prior run can be force-removed before rebinding
// host-network ports (timestamped names left orphans holding :14000 forever).
const PEBBLE_CONTAINER = "nginz-acme-pebble";
const CHALLTESTSRV_CONTAINER = "nginz-acme-challtestsrv";
const PEBBLE_CONFIG_HOST = join(process.cwd(), "tests", MODULE, "pebble-config.json");
const PEBBLE_CONFIG = "/test/pebble-config.json";
const PEBBLE_CA_HOST = join(process.cwd(), "tests", MODULE, "pebble.minica.pem");
const STORAGE_DIR = join(process.cwd(), "tests", MODULE, "runtime", "acme");
const ERROR_LOG = join(process.cwd(), "tests", MODULE, "runtime", "logs", "error.log");
// Pebble ACME :14000, management :15000, challtestsrv DNS :8053
const PEBBLE_PORTS = [14000, 15000, 8053];

function runResult(command, options = {}) {
  const result = Bun.spawnSync(command, {
    stdout: options.capture === false ? "inherit" : "pipe",
    stderr: options.capture === false ? "inherit" : "pipe",
    cwd: process.cwd(),
    env: process.env,
  });

  return {
    exitCode: result.exitCode,
    stdout: result.stdout ? Buffer.from(result.stdout).toString() : "",
    stderr: result.stderr ? Buffer.from(result.stderr).toString() : "",
  };
}

function run(command, options = {}) {
  const result = runResult(command, options);

  if (result.exitCode !== 0) {
    throw new Error(`${command.join(" ")} failed\n${result.stdout}${result.stderr}`.trim());
  }

  return result;
}

function docker(...args) {
  return run(["sudo", "docker", ...args]);
}

function ensureDockerAvailable() {
  const result = runResult(["sudo", "docker", "info"]);
  if (result.exitCode !== 0) {
    throw new Error(`Docker is required for ACME live tests but is not available.\n${result.stdout}${result.stderr}`.trim());
  }
}

function ensureDockerImageAvailable(image) {
  const result = runResult(["sudo", "docker", "image", "inspect", image]);
  if (result.exitCode !== 0) {
    throw new Error(
      `Required Docker image is not available locally: ${image}\nPull it first, then rerun the test.\n${result.stdout}${result.stderr}`.trim()
    );
  }
}

function containerDiagnostics(name) {
  const inspect = runResult([
    "sudo",
    "docker",
    "inspect",
    "--format",
    "Running={{.State.Running}} Status={{.State.Status}} ExitCode={{.State.ExitCode}} Error={{.State.Error}}",
    name,
  ]);
  const logs = runResult(["sudo", "docker", "logs", "--tail", "80", name]);
  return [
    `inspect: ${inspect.stdout}${inspect.stderr}`.trim(),
    `logs:\n${logs.stdout}${logs.stderr}`.trim(),
  ].join("\n");
}

function assertContainerRunning(name) {
  const result = runResult(["sudo", "docker", "inspect", "--format", "{{.State.Running}}", name]);
  if (result.exitCode !== 0) {
    throw new Error(`Container ${name} is not inspectable.\n${result.stdout}${result.stderr}`.trim());
  }
  if (!result.stdout.trim().includes("true")) {
    throw new Error(`Container ${name} exited before becoming ready.\n${containerDiagnostics(name)}`);
  }
}

// Remove known + legacy timestamped nginz-acme-* containers so host ports
// can be rebound. No --rm on run: crashed containers stay inspectable.
function stopAllAcmeContainers() {
  for (const name of [PEBBLE_CONTAINER, CHALLTESTSRV_CONTAINER]) {
    runResult(["sudo", "docker", "rm", "-f", name]);
  }
  const listed = runResult(["sudo", "docker", "ps", "-aq", "--filter", "name=nginz-acme-"]);
  for (const id of listed.stdout.trim().split(/\s+/).filter(Boolean)) {
    runResult(["sudo", "docker", "rm", "-f", id]);
  }
}

async function freePebblePorts() {
  for (const port of PEBBLE_PORTS) {
    await ensurePortFree(port);
  }
}

function startChalltestsrv() {
  docker(
    "run",
    "--pull=never",
    "-d",
    "--name",
    CHALLTESTSRV_CONTAINER,
    "--network",
    "host",
    CHALLTESTSRV_IMAGE,
    "-defaultIPv6",
    "",
    "-defaultIPv4",
    "127.0.0.1"
  );
  assertContainerRunning(CHALLTESTSRV_CONTAINER);
}

function startPebble() {
  docker(
    "run",
    "--pull=never",
    "-d",
    "--name",
    PEBBLE_CONTAINER,
    "--network",
    "host",
    "-v",
    `${PEBBLE_CONFIG_HOST}:${PEBBLE_CONFIG}:ro`,
    "-e",
    "PEBBLE_VA_NOSLEEP=1",
    "-e",
    "PEBBLE_VA_ALWAYS_VALID=0",
    "-e",
    "PEBBLE_WFE_NONCEREJECT=0",
    PEBBLE_IMAGE,
    "-config",
    PEBBLE_CONFIG,
    "-dnsserver",
    "127.0.0.1:8053"
  );
  // Brief grace: bind failures exit almost immediately; healthy start stays up.
  const deadline = Date.now() + 2000;
  while (Date.now() < deadline) {
    const running = runResult([
      "sudo",
      "docker",
      "inspect",
      "--format",
      "{{.State.Running}}",
      PEBBLE_CONTAINER,
    ]);
    if (running.exitCode === 0 && running.stdout.trim().includes("true")) {
      break;
    }
    if (running.exitCode === 0 && running.stdout.trim().includes("false")) {
      throw new Error(`Pebble container exited on start.\n${containerDiagnostics(PEBBLE_CONTAINER)}`);
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 50);
  }
  assertContainerRunning(PEBBLE_CONTAINER);
  docker("cp", `${PEBBLE_CONTAINER}:/test/certs/pebble.minica.pem`, PEBBLE_CA_HOST);
}

function stopContainer(name) {
  try {
    runResult(["sudo", "docker", "rm", "-f", name]);
  } catch {
    // best-effort
  }
}

function triggerAcmeFlow() {
  return fetchClose(`${TEST_URL}/.well-known/acme-trigger`, {
    headers: { Connection: "close" },
  }).then(async (res) => {
    const body = await res.text();
    try {
      return JSON.parse(body);
    } catch {
      const nginxLog = existsSync(ERROR_LOG) ? readFileSync(ERROR_LOG, "utf8") : "<error log unavailable>";
      throw new Error(`Failed to parse ACME trigger response as JSON. Status=${res.status}. Raw response:\n${body}\nnginx error log:\n${nginxLog}`);
    }
  });
}

async function waitForRunnerReady(timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const res = await fetchClose(`${TEST_URL}/ready`, {
        headers: { Connection: "close" },
      });
      if (res.status === 200 && (await res.text()).includes("ready ok")) {
        return;
      }
    } catch {
      // still starting
    }
    await Bun.sleep(100);
  }
  throw new Error("Timeout waiting for containerized ACME runner");
}

async function waitForPebbleReady(timeout = 15000) {
  const start = Date.now();
  let lastCurl = "";
  while (Date.now() - start < timeout) {
    const running = runResult([
      "sudo",
      "docker",
      "inspect",
      "--format",
      "{{.State.Running}}",
      PEBBLE_CONTAINER,
    ]);
    if (running.exitCode !== 0 || !running.stdout.trim().includes("true")) {
      throw new Error(
        `Pebble container exited while waiting for readiness.\n${containerDiagnostics(PEBBLE_CONTAINER)}`,
      );
    }
    try {
      const res = run(["curl", "-sk", "https://127.0.0.1:14000/dir"]);
      if (res.stdout.includes('"newOrder"')) {
        return;
      }
      lastCurl = res.stdout.slice(0, 200);
    } catch (error) {
      lastCurl = String(error?.message || error);
    }
    await Bun.sleep(100);
  }
  throw new Error(
    `Timeout waiting for Pebble directory endpoint.\nlast=${lastCurl}\n${containerDiagnostics(PEBBLE_CONTAINER)}`,
  );
}

async function triggerUntilIssued({ maxSteps = 48, stepDelayMs = 100 } = {}) {
  const accountKeyPath = join(STORAGE_DIR, "account.key");
  const certPath = join(STORAGE_DIR, "certs", DOMAIN, "fullchain.pem");
  const keyPath = join(STORAGE_DIR, "certs", DOMAIN, "privkey.pem");

  let last;
  for (let i = 0; i < maxSteps; i++) {
    last = await triggerAcmeFlow();
    if (last.status === "complete") {
      return last;
    }
    if (issuedArtifactsReady({ accountKeyPath, certPath, keyPath })) {
      return last;
    }
    await Bun.sleep(stepDelayMs);
    if (issuedArtifactsReady({ accountKeyPath, certPath, keyPath })) {
      return last;
    }
  }
  return last;
}

async function assertTlsRejected(configName) {
  await stopNginz();
  await startNginz(`tests/${MODULE}/${configName}`, MODULE);
  await waitForRunnerReady();

  // First call initializes the durable ACME session; subsequent calls attempt
  // the verified TLS connection. A transport failure may be rendered as JSON
  // or terminate the upstream request, so accept either client manifestation.
  await triggerAcmeFlow();
  for (let i = 0; i < 2; i++) {
    try { await triggerAcmeFlow(); } catch {}
  }
  await Bun.sleep(100);

  const certPath = join(STORAGE_DIR, "certs", DOMAIN, "fullchain.pem");
  expect(existsSync(certPath)).toBe(false);
  const errorLog = readRunnerLog(ERROR_LOG);
  expect(errorLog).toMatch(/certificate verify|certificate does not match|upstream SSL/i);
}

function readRunnerLog(path) {
  return readFileSync(path, "utf8");
}

function fileContains(path, needle) {
  if (!existsSync(path)) {
    return false;
  }
  return readFileSync(path, "utf8").includes(needle);
}

function issuedArtifactsReady({ accountKeyPath, certPath, keyPath }) {
  return (
    fileContains(accountKeyPath, "-----BEGIN ") &&
    fileContains(certPath, "-----BEGIN CERTIFICATE-----") &&
    fileContains(keyPath, "-----BEGIN ")
  );
}


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("acme module live Pebble integration", () => {
  beforeAll(async () => {
    await stopNginz();
    ensureDockerAvailable();
    ensureDockerImageAvailable(CHALLTESTSRV_IMAGE);
    ensureDockerImageAvailable(PEBBLE_IMAGE);
    // Drop orphans from prior runs, then free host ports held by unit mock /
    // leftover pebble (root-owned listeners need ensurePortFree's sudo kill).
    stopAllAcmeContainers();
    await freePebblePorts();
    startChalltestsrv();
    startPebble();
    await waitForPebbleReady();
    await startNginz(`tests/${MODULE}/nginx.live.conf`, MODULE);
    await waitForRunnerReady();
  }, 300000);

  afterAll(async () => {
    await stopNginz();
    stopAllAcmeContainers();
    try { unlinkSync(PEBBLE_CA_HOST); } catch {}
    for (const port of PEBBLE_PORTS) {
      try { await ensurePortFree(port, 3000); } catch {}
    }
    cleanupHarnessRuntime(MODULE);
  }, 30000);

  test("trigger-driven flow completes real HTTP-01 validation and stores artifacts", async () => {
    const accountKeyPath = join(STORAGE_DIR, "account.key");
    const certPath = join(STORAGE_DIR, "certs", DOMAIN, "fullchain.pem");
    const keyPath = join(STORAGE_DIR, "certs", DOMAIN, "privkey.pem");

    const final = await triggerUntilIssued({ maxSteps: 48, stepDelayMs: 100 });

    if (!issuedArtifactsReady({ accountKeyPath, certPath, keyPath })) {
      expect(["complete", "started"]).toContain(final.status);
    }
    expect(existsSync(accountKeyPath)).toBe(true);
    expect(existsSync(certPath)).toBe(true);
    expect(existsSync(keyPath)).toBe(true);

    expect(issuedArtifactsReady({ accountKeyPath, certPath, keyPath })).toBe(true);

    const errorLog = readRunnerLog(join(process.cwd(), "tests", MODULE, "runtime", "logs", "error.log"));
    expect(errorLog).not.toContain("header already sent");
  }, 60000);

  test("rejects Pebble when its private CA is not explicitly trusted", async () => {
    await assertTlsRejected("nginx.live-untrusted.conf");
  }, 30000);

  test("rejects a trusted certificate when the ACME hostname does not match", async () => {
    await assertTlsRejected("nginx.live-hostname-mismatch.conf");
  }, 30000);

  test("rejects malformed trust material during configuration", async () => {
    // Prior tests leave a live nginz on the shared runtime prefix; -t against
    // the same -p can stall on pid/lock files under load.
    await stopNginz();
    const result = runResult([
      "./zig-out/bin/nginz",
      "-t",
      "-p",
      join(process.cwd(), "tests", MODULE, "runtime"),
      "-c",
      join(process.cwd(), "tests", MODULE, "nginx.live-malformed-trust.conf"),
    ]);
    expect(result.exitCode).not.toBe(0);
    const diagnostic = `${result.stdout}${result.stderr}${existsSync(ERROR_LOG) ? readFileSync(ERROR_LOG, "utf8") : ""}`;
    expect(diagnostic).toMatch(/certificate|PEM|SSL/i);
  }, 15000);
});
