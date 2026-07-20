import { spawn, spawnSync } from "bun";
import { mkdirSync, rmSync, existsSync, openSync, closeSync, unlinkSync } from "fs";
import { join, isAbsolute } from "path";

let nginzProcess = null;
const NGINZ_BIN = "./zig-out/bin/nginz";
const TEST_PORT = 8888;
export const DEFAULT_PERF_OPTIMIZE = "ReleaseSmall";
const BUILD_LOCK_PATH = join(process.cwd(), ".zig-build.lock");

// Ports nginx itself binds in test configs (not Bun mock servers). Freeing
// mock ports (190xx / 16xxx) here would kill the test process that already
// started createHTTPMock() in beforeAll.
const NGINX_LISTEN_PORTS = [8888, 8889, 8891, 8892, 8895];

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function acquireBuildLock(timeoutMs = 120000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    try {
      const fd = openSync(BUILD_LOCK_PATH, "wx");
      return fd;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      sleepSync(100);
    }
  }
  throw new Error("timed out waiting for zig build lock");
}

// Build nginz before running tests
// For performance-oriented runs, prefer ZIG_OPTIMIZE=ReleaseSmall.
// ReleaseSmall is the project-recommended release-grade mode: it keeps safety
// checks on and avoids the ReleaseSafe LLVM/memory issues documented in the repo.
export function ensureBuild() {
  const lockFd = acquireBuildLock();
  const optimize = process.env.ZIG_OPTIMIZE;
  const args = ["zig", "build"];

  try {
    if (optimize) {
      args.push(`-Doptimize=${optimize}`);
      console.log(`Building nginz with -Doptimize=${optimize}...`);
    } else {
      console.log("Building nginz...");
    }

    const result = spawnSync(args, {
      stdout: "inherit",
      stderr: "inherit",
    });
    if (result.exitCode !== 0) {
      throw new Error("zig build failed");
    }
    console.log("Build successful");
  } finally {
    closeSync(lockFd);
    try {
      unlinkSync(BUILD_LOCK_PATH);
    } catch {}
  }
}

// Create isolated runtime directory for a module
function createRuntimeDir(moduleName) {
  const runtimeDir = join(process.cwd(), "tests", moduleName, "runtime");
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
  mkdirSync(runtimeDir, { recursive: true });
  mkdirSync(join(runtimeDir, "logs"), { recursive: true });
  return runtimeDir;
}

// Start nginz with given config
export async function startNginz(configPath, moduleName) {
  for (const port of NGINX_LISTEN_PORTS) {
    await ensurePortFree(port);
  }
  const runtimeDir = createRuntimeDir(moduleName);
  const absConfig = isAbsolute(configPath)
    ? configPath
    : join(process.cwd(), configPath);

  nginzProcess = spawn([NGINZ_BIN, "-c", absConfig, "-p", runtimeDir], {
    stdout: "inherit",
    stderr: "inherit",
    cwd: process.cwd(),
    env: process.env,
  });

  await waitForPort(TEST_PORT);
  return runtimeDir;
}

// Stop nginz (fast shutdown so open connections from timed-out tests don't block)
export async function stopNginz() {
  const port = TEST_PORT;
  if (nginzProcess) {
    const proc = nginzProcess;
    nginzProcess = null;
    try {
      proc.kill("SIGTERM");
    } catch {}
    const killTimer = setTimeout(() => {
      try {
        proc.kill("SIGKILL");
      } catch {}
    }, 2000);
    try {
      await proc.exited;
    } catch {}
    clearTimeout(killTimer);
  }
  try {
    await waitForPortFree(port, 5000);
  } catch {}
}

export async function reloadNginz() {
  if (!nginzProcess) throw new Error("nginz is not running");
  nginzProcess.kill("SIGHUP");
  // The listening socket remains available throughout reload. Give the new
  // generation time to start while old workers drain in-flight requests.
  await Bun.sleep(200);
  await waitForPort(TEST_PORT);
}

// Wait until nothing is listening on the port (previous nginx fully gone)
export async function waitForPortFree(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      await Bun.connect({
        hostname: "127.0.0.1",
        port,
        socket: { data() {}, open(s) { s.end(); }, close() {}, error() {} },
      });
      // Still accepting connections — wait and retry.
      await Bun.sleep(50);
    } catch {
      return;
    }
  }
  throw new Error(`Timeout waiting for port ${port} to become free`);
}

function killListenersOnPort(port) {
  // Only kill LISTEN-side processes (ss -ltnp). Do NOT use `fuser -k`:
  // fuser also targets clients connected to the port, which would SIGKILL
  // the bun test process itself while it still has sockets open to nginx.
  try {
    const ss = spawnSync(["ss", "-ltnp", `sport = :${port}`], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const raw = ss.stdout;
    const text = raw == null
      ? ""
      : typeof raw === "string"
        ? raw
        : Buffer.from(raw).toString();
    for (const match of text.matchAll(/pid=(\d+)/g)) {
      const pid = Number(match[1]);
      if (pid > 0 && pid !== process.pid) {
        try {
          process.kill(pid, "SIGKILL");
        } catch {}
      }
    }
  } catch {}
}

// Free a TCP port for reuse. Soft-wait first; if something is still bound,
// kill listeners on that port (test-only harness) and wait again.
export async function ensurePortFree(port, timeout = 10000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    try {
      await waitForPortFree(port, 150);
      return;
    } catch {}
    killListenersOnPort(port);
    await Bun.sleep(50);
  }
  throw new Error(`Timeout waiting for port ${port} to become free`);
}

// Wait for port to be available
async function waitForPort(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 100);
      await fetch(`http://localhost:${port}/`, {
        signal: controller.signal,
        headers: { Connection: "close" },
      });
      clearTimeout(timeoutId);
      return;
    } catch {
      await Bun.sleep(50);
    }
  }
  throw new Error(`Timeout waiting for port ${port}`);
}

// Wait for a TCP port to be listening
export async function waitForTCPPort(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      await Bun.connect({
        hostname: "127.0.0.1",
        port,
        socket: {
          data() {},
          open(socket) {
            socket.end();
          },
          close() {},
          error() {},
        },
      });
      return;
    } catch {
      await Bun.sleep(50);
    }
  }
  throw new Error(`Timeout waiting for TCP port ${port}`);
}

// Clean up runtime directory
// Set KEEP_LOGS=1 to preserve runtime dir for debugging failed tests
export function cleanupRuntime(moduleName) {
  if (process.env.KEEP_LOGS) return;
  const runtimeDir = join(process.cwd(), "tests", moduleName, "runtime");
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
}

// Default ports for mock servers
export const MOCK_PORTS = {
  REDIS: 16379,
  POSTGRES: 15432,
  CONSUL: 18500,
  OIDC: 19000,
  ACME: 14000,
  HTTP: 19001,
  HTTP_UPSTREAM_1: 19002,
  HTTP_UPSTREAM_2: 19003,
};

// Free mock listen ports before bind. njs/subrequest suites all share these
// fixed ports across many test files; a slow Bun.serve stop leaves EADDRINUSE.
export async function prepareMockPorts(...ports) {
  for (const port of ports) {
    await ensurePortFree(port, 5000);
  }
}

// Ordered teardown for modules that own nginz + Bun mocks on fixed ports.
// Stop nginz first (drops upstream sockets), then mocks, then free ports so
// the next suite's create*Mock can bind immediately.
export async function teardownModule(moduleName, mocks = [], ports = []) {
  await stopNginz();
  for (const mock of mocks) {
    try {
      mock?.stop?.();
    } catch {}
  }
  for (const port of ports) {
    try {
      await ensurePortFree(port, 3000);
    } catch {}
  }
  cleanupRuntime(moduleName);
}

// Bun keep-alive pool can race nginx FIN after non-2xx access/content
// responses ("socket connection was closed unexpectedly"). Always send
// Connection: close and retry a couple of times on reset/refused.
export async function stableFetch(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  let lastError = null;
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      return await fetch(url, { ...init, headers });
    } catch (error) {
      lastError = error;
      const msg = String(error?.message || error);
      if (!/closed unexpectedly|ECONNRESET|ECONNREFUSED|socket/i.test(msg)) {
        throw error;
      }
      await Bun.sleep(40 * (attempt + 1));
    }
  }
  throw lastError;
}

// Convenience: stableFetch against the active TEST_URL.
export async function testFetch(path, init = {}) {
  const url = path.startsWith("http") ? path : `${TEST_URL}${path}`;
  return stableFetch(url, init);
}

// Export mock factories
export { createRedisMock, RedisMock } from "./mocks/redis.js";
export { createPostgresMock, PostgresMock } from "./mocks/postgres.js";
export { createConsulMock, ConsulMock } from "./mocks/consul.js";
export { createOIDCMock, OIDCMock } from "./mocks/oidc.js";
export { createACMEMock, ACMEMock } from "./mocks/acme.js";
export {
  createHTTPMock,
  createStaticMock,
  createProxyMock,
  HTTPMock,
  StaticMock,
  ProxyMock,
} from "./mocks/http.js";

// Mock server manager - helps manage multiple mock servers
export class MockManager {
  constructor() {
    this.mocks = new Map();
  }

  add(name, mock) {
    this.mocks.set(name, mock);
    return mock;
  }

  get(name) {
    return this.mocks.get(name);
  }

  async stopAll() {
    for (const [name, mock] of this.mocks) {
      try {
        if (mock.stop) {
          mock.stop();
        }
      } catch (err) {
        console.error(`Error stopping mock ${name}:`, err);
      }
    }
    this.mocks.clear();
  }
}

// Create a new mock manager
export function createMockManager() {
  return new MockManager();
}

export const TEST_PORT_NUM = TEST_PORT;
export const TEST_URL = `http://localhost:${TEST_PORT}`;
