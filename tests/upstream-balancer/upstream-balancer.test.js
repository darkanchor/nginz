import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { spawnSync } from "bun";
import { join } from "path";
import { mkdirSync, rmSync } from "fs";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  createHTTPMock,
  MOCK_PORTS,
  TEST_URL,
} from "../harness.js";

const MODULE = "upstream-balancer";

describe("upstream-balancer", () => {
  let backend1;
  let backend2;

  beforeAll(async () => {
    // backend1 on 19002 — identifies itself so sticky tests can tell servers apart
    backend1 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1);
    backend1.setDefault({ status: 200, body: { server: "backend1" } });

    // backend2 on 19003 — needed for /sticky determinism tests (two-server upstream)
    backend2 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_2);
    backend2.setDefault({ status: 200, body: { server: "backend2" } });

    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend1.stop();
    backend2.stop();
    cleanupRuntime(MODULE);
  });

  // --- Phase 1: Config parsing and basic proxying ---

  test("plain upstream (no sticky directives) proxies normally", async () => {
    const res = await fetch(`${TEST_URL}/plain`);
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend1");
  });

  test("cookie upstream accepts config and proxies without a cookie (fallback next)", async () => {
    const res = await fetch(`${TEST_URL}/cookie`);
    expect(res.status).toBe(200);
  });

  test("header upstream accepts config and proxies without the sticky header (fallback next)", async () => {
    const res = await fetch(`${TEST_URL}/header`);
    expect(res.status).toBe(200);
  });

  // --- Phase 2: Sticky selection ---

  test("cookie affinity: same key routes to same backend across repeated requests", async () => {
    const servers = new Set();
    for (let i = 0; i < 5; i++) {
      const res = await fetch(`${TEST_URL}/sticky`, {
        headers: { Cookie: "route=stable-session-a" },
      });
      expect(res.status).toBe(200);
      servers.add((await res.json()).server);
    }
    // All 5 requests with the same cookie must land on the same server.
    expect(servers.size).toBe(1);
  });

  test("cookie affinity: different key is independently stable", async () => {
    const fetchServer = async (cookieVal) => {
      const res = await fetch(`${TEST_URL}/sticky`, {
        headers: { Cookie: `route=${cookieVal}` },
      });
      expect(res.status).toBe(200);
      return (await res.json()).server;
    };

    // Establish which backend each key maps to.
    const serverAlpha = await fetchServer("key-alpha");
    const serverBeta = await fetchServer("key-beta");

    // Verify each key is stable on subsequent calls.
    expect(await fetchServer("key-alpha")).toBe(serverAlpha);
    expect(await fetchServer("key-beta")).toBe(serverBeta);
  });

  test("header affinity: same key proxies successfully on repeated requests", async () => {
    for (let i = 0; i < 3; i++) {
      const res = await fetch(`${TEST_URL}/header`, {
        headers: { "X-Sticky-Key": "client-session-42" },
      });
      expect(res.status).toBe(200);
    }
  });

  test("cookie present: proxies to the chosen backend (200)", async () => {
    const res = await fetch(`${TEST_URL}/cookie`, {
      headers: { Cookie: "route=explicit-user" },
    });
    expect(res.status).toBe(200);
  });

  test("cookie absent, fallback next: proxies to a backend (200)", async () => {
    // /cookie uses backend_cookie (fallback next) — missing cookie falls through to round-robin.
    const res = await fetch(`${TEST_URL}/cookie`);
    expect(res.status).toBe(200);
  });

  test("cookie absent, fallback off: returns 502", async () => {
    // /fallback-off uses backend_fallback_off (fallback off) — missing cookie must fail cleanly.
    const res = await fetch(`${TEST_URL}/fallback-off`);
    expect(res.status).toBe(502);
  });
});

describe("upstream-balancer config validation", () => {
  test("cookie and header sticky directives in same upstream block are rejected at parse time", () => {
    const configPath = join(
      process.cwd(),
      `tests/${MODULE}/nginx-invalid.conf`
    );
    const runtimeDir = join(
      process.cwd(),
      `tests/${MODULE}/runtime-invalid`
    );
    mkdirSync(join(runtimeDir, "logs"), { recursive: true });

    try {
      const result = spawnSync(
        [
          "./zig-out/bin/nginz",
          "-t",
          "-c",
          configPath,
          "-p",
          runtimeDir,
        ],
        { stdout: "pipe", stderr: "pipe" }
      );
      // nginx prints "test failed" to stderr when a config error is detected.
      // (nginz wraps main_nginx as void, so the integer return value is not
      // propagated to the process exit code; check the output text instead.)
      const stderr = result.stderr.toString();
      expect(stderr).toContain("test failed");
    } finally {
      rmSync(runtimeDir, { recursive: true, force: true });
    }
  });
});

// Phase 3: multi-worker consistency.
// nginx runs with 2 worker processes. Each worker independently computes
// CRC32(key) % eligible_peer_count from the same config-time peer list
// (identical across workers since they fork after config parsing).
// The result must be the same regardless of which worker handles the request.
describe("upstream-balancer multi-worker consistency", () => {
  let backend1;
  let backend2;

  beforeAll(async () => {
    backend1 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1);
    backend1.setDefault({ status: 200, body: { server: "backend1" } });

    backend2 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_2);
    backend2.setDefault({ status: 200, body: { server: "backend2" } });

    await startNginz(`tests/${MODULE}/nginx-multiworker.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend1.stop();
    backend2.stop();
    cleanupRuntime(MODULE);
  });

  test("same cookie key resolves to the same backend across all workers (20 requests)", async () => {
    const servers = new Set();
    for (let i = 0; i < 20; i++) {
      const res = await fetch(`${TEST_URL}/`, {
        headers: { Cookie: "route=cross-worker-stable" },
      });
      expect(res.status).toBe(200);
      servers.add((await res.json()).server);
    }
    // 20 requests spread across 2 workers — all must land on the same backend.
    expect(servers.size).toBe(1);
  });

  test("each distinct key is independently stable across workers", async () => {
    const fetchServer = async (key) => {
      const res = await fetch(`${TEST_URL}/`, {
        headers: { Cookie: `route=${key}` },
      });
      expect(res.status).toBe(200);
      return (await res.json()).server;
    };

    // Establish which peer each key maps to.
    const serverX = await fetchServer("worker-key-x");
    const serverY = await fetchServer("worker-key-y");

    // Each key must remain stable over subsequent requests (different workers).
    for (let i = 0; i < 6; i++) {
      expect(await fetchServer("worker-key-x")).toBe(serverX);
      expect(await fetchServer("worker-key-y")).toBe(serverY);
    }
  });
});
