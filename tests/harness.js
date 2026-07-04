import { spawn, spawnSync } from "bun";
import { mkdirSync, rmSync, existsSync } from "fs";
import { join, dirname, isAbsolute } from "path";

let nginzProcess = null;
const NGINZ_BIN = "./zig-out/bin/nginz";
const TEST_PORT = 8888;
export const DEFAULT_PERF_OPTIMIZE = "ReleaseSmall";

// Build nginz before running tests
// For performance-oriented runs, prefer ZIG_OPTIMIZE=ReleaseSmall.
// ReleaseSmall is the project-recommended release-grade mode: it keeps safety
// checks on and avoids the ReleaseSafe LLVM/memory issues documented in the repo.
export function ensureBuild() {
  const optimize = process.env.ZIG_OPTIMIZE;
  const args = ["zig", "build"];

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
  await waitForPortFree(TEST_PORT);
  const runtimeDir = createRuntimeDir(moduleName);
  const absConfig = isAbsolute(configPath)
    ? configPath
    : join(process.cwd(), configPath);

  nginzProcess = spawn([NGINZ_BIN, "-c", absConfig, "-p", runtimeDir], {
    stdout: "inherit",
    stderr: "inherit",
    cwd: process.cwd(),
  });

  await waitForPort(TEST_PORT);
  return runtimeDir;
}

// Stop nginz (fast shutdown so open connections from timed-out tests don't block)
export async function stopNginz() {
  if (nginzProcess) {
    nginzProcess.kill("SIGTERM");
    await nginzProcess.exited;
    nginzProcess = null;
  }
}

// Wait until nothing is listening on the port (previous nginx fully gone)
async function waitForPortFree(port, timeout = 5000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const socket = await Bun.connect({
        hostname: "127.0.0.1",
        port,
        socket: { data() {}, open(s) { s.end(); }, close() {}, error() {} },
      });
      await Bun.sleep(50);
    } catch {
      return;
    }
  }
}

// Wait for port to be available
async function waitForPort(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const controller = new AbortController();
      const timeoutId = setTimeout(() => controller.abort(), 100);
      await fetch(`http://localhost:${port}/`, { signal: controller.signal });
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
      const socket = await Bun.connect({
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

// Export mock factories
export { createRedisMock, RedisMock } from "./mocks/redis.js";
export { createPostgresMock, PostgresMock } from "./mocks/postgres.js";
export { createConsulMock, ConsulMock } from "./mocks/consul.js";
export { createOIDCMock, OIDCMock } from "./mocks/oidc.js";
export { createACMEMock, ACMEMock } from "./mocks/acme.js";
export { createMqttMock, MqttMock, buildMqttConnect, parseMqttConnect } from "./mocks/mqtt.js";
export {
  createHTTPMock,
  createStaticMock,
  createProxyMock,
  HTTPMock,
  StaticMock,
  ProxyMock,
} from "./mocks/http.js";

// Default ports for mock servers
export const MOCK_PORTS = {
  REDIS: 16379,
  POSTGRES: 15432,
  CONSUL: 18500,
  OIDC: 19000,
  ACME: 14000,
  MQTT_UPSTREAM_1: 18884,
  MQTT_UPSTREAM_2: 18885,
  HTTP: 19001,
  HTTP_UPSTREAM_1: 19002,
  HTTP_UPSTREAM_2: 19003,
};

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
