import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { existsSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";
import { startNginz, stopNginz, cleanupRuntime as cleanupHarnessRuntime, TEST_URL } from "../harness.js";

const MODULE = "acme";
const DOMAIN = "live-acme.test";
const PEBBLE_IMAGE = "ghcr.io/letsencrypt/pebble:latest";
const CHALLTESTSRV_IMAGE = "ghcr.io/letsencrypt/pebble-challtestsrv:latest";
const PEBBLE_CONTAINER = `nginz-acme-pebble-${Date.now()}`;
const CHALLTESTSRV_CONTAINER = `nginz-acme-challtestsrv-${Date.now()}`;
const PEBBLE_CONFIG_HOST = join(process.cwd(), "tests", MODULE, "pebble-config.json");
const PEBBLE_CONFIG = "/test/pebble-config.json";
const PEBBLE_CA_HOST = join(process.cwd(), "tests", MODULE, "pebble.minica.pem");
const STORAGE_DIR = join(process.cwd(), "tests", MODULE, "runtime", "acme");
const ERROR_LOG = join(process.cwd(), "tests", MODULE, "runtime", "logs", "error.log");

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

function assertContainerRunning(name) {
  const result = runResult(["sudo", "docker", "inspect", "--format", "{{.State.Running}}", name]);
  if (result.exitCode !== 0) {
    throw new Error(`Container ${name} is not inspectable.\n${result.stdout}${result.stderr}`.trim());
  }
  if (!result.stdout.trim().includes("true")) {
    const logs = runResult(["sudo", "docker", "logs", name]);
    throw new Error(`Container ${name} exited before becoming ready.\n${logs.stdout}${logs.stderr}`.trim());
  }
}

function startChalltestsrv() {
  docker(
    "run",
    "--pull=never",
    "--rm",
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
    "--rm",
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
  assertContainerRunning(PEBBLE_CONTAINER);
  docker("cp", `${PEBBLE_CONTAINER}:/test/certs/pebble.minica.pem`, PEBBLE_CA_HOST);
}

function stopContainer(name) {
  try {
    docker("rm", "-f", name);
  } catch {
    // best-effort
  }
}

function triggerAcmeFlow() {
  return fetch(`${TEST_URL}/.well-known/acme-trigger`).then(async (res) => {
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
      const res = await fetch(`${TEST_URL}/ready`);
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

async function waitForPebbleReady(timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    assertContainerRunning(PEBBLE_CONTAINER);
    try {
      const res = run(["curl", "-sk", "https://127.0.0.1:14000/dir"]);
      if (res.stdout.includes('"newOrder"')) {
        return;
      }
    } catch {
      // still starting
    }
    await Bun.sleep(100);
  }
  throw new Error("Timeout waiting for Pebble");
}

async function triggerUntilIssued({ maxSteps = 24 } = {}) {
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
    await Bun.sleep(50);
    if (issuedArtifactsReady({ accountKeyPath, certPath, keyPath })) {
      return last;
    }
  }
  return last;
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

describe("acme module live Pebble integration", () => {
  beforeAll(async () => {
    await stopNginz();
    ensureDockerAvailable();
    ensureDockerImageAvailable(CHALLTESTSRV_IMAGE);
    ensureDockerImageAvailable(PEBBLE_IMAGE);
    startChalltestsrv();
    startPebble();
    await waitForPebbleReady();
    await startNginz(`tests/${MODULE}/nginx.live.conf`, MODULE);
    await waitForRunnerReady();
  }, 300000);

  afterAll(async () => {
    await stopNginz();
    stopContainer(PEBBLE_CONTAINER);
    stopContainer(CHALLTESTSRV_CONTAINER);
    try { unlinkSync(PEBBLE_CA_HOST); } catch {}
    cleanupHarnessRuntime(MODULE);
  }, 30000);

  test("trigger-driven flow completes real HTTP-01 validation and stores artifacts", async () => {
    const accountKeyPath = join(STORAGE_DIR, "account.key");
    const certPath = join(STORAGE_DIR, "certs", DOMAIN, "fullchain.pem");
    const keyPath = join(STORAGE_DIR, "certs", DOMAIN, "privkey.pem");

    const final = await triggerUntilIssued({ maxSteps: 32 });

    if (!issuedArtifactsReady({ accountKeyPath, certPath, keyPath })) {
      expect(["complete", "started"]).toContain(final.status);
    }
    expect(existsSync(accountKeyPath)).toBe(true);
    expect(existsSync(certPath)).toBe(true);
    expect(existsSync(keyPath)).toBe(true);

    expect(issuedArtifactsReady({ accountKeyPath, certPath, keyPath })).toBe(true);

    const errorLog = readRunnerLog(join(process.cwd(), "tests", MODULE, "runtime", "logs", "error.log"));
    expect(errorLog).not.toContain("header already sent");
  });
});
