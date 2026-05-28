import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { spawnSync } from "bun";
import { join } from "path";
import { mkdirSync, readFileSync, rmSync } from "fs";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  createHTTPMock,
  MOCK_PORTS,
  TEST_URL,
} from "../harness.js";

const MODULE = "upstream-balancer";
const CRC32_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let crc = i;
    for (let j = 0; j < 8; j++) {
      crc = (crc & 1) !== 0 ? (crc >>> 1) ^ 0xedb88320 : crc >>> 1;
    }
    table[i] = crc >>> 0;
  }
  return table;
})();

function crc32IsoHdlc(input) {
  const bytes = new TextEncoder().encode(input);
  let crc = 0xffffffff;
  for (const byte of bytes) {
    crc = (crc >>> 8) ^ CRC32_TABLE[(crc ^ byte) & 0xff];
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function stickyKeyForPeer(peerIndex, peerCount = 2, prefix = "sticky-key") {
  for (let i = 0; i < 4096; i++) {
    const key = `${prefix}-${i}`;
    if (crc32IsoHdlc(key) % peerCount === peerIndex) {
      return key;
    }
  }
  throw new Error(`failed to find sticky key for peer ${peerIndex}`);
}

function stickyKeyStableAcrossCounts(peerIndex, beforeCount, afterCount, prefix = "stable-key") {
  for (let i = 0; i < 16384; i++) {
    const key = `${prefix}-${i}`;
    if (crc32IsoHdlc(key) % beforeCount === peerIndex && crc32IsoHdlc(key) % afterCount === peerIndex) {
      return key;
    }
  }
  throw new Error(
    `failed to find sticky key for peer ${peerIndex} stable across ${beforeCount}->${afterCount}`
  );
}

function countOccurrences(haystack, needle) {
  if (needle.length === 0) return 0;
  return haystack.split(needle).length - 1;
}

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

  test("weighted sticky distribution favors the higher-weight peer", async () => {
    const counts = { backend1: 0, backend2: 0 };
    for (let i = 0; i < 64; i++) {
      const res = await fetch(`${TEST_URL}/weighted`, {
        headers: { Cookie: `route=weighted-key-${i}` },
      });
      expect(res.status).toBe(200);
      counts[(await res.json()).server] += 1;
    }
    expect(counts.backend1).toBeGreaterThan(counts.backend2 * 2);
  });

  test("module can issue a sticky cookie and reuse it on the next request", async () => {
    const first = await fetch(`${TEST_URL}/issue-cookie`);
    expect(first.status).toBe(200);
    const firstBody = await first.json();
    const setCookie = first.headers.get("set-cookie");
    expect(setCookie).toContain("route=peer:");

    const issuedCookie = setCookie.split(";")[0];
    const second = await fetch(`${TEST_URL}/issue-cookie`, {
      headers: { Cookie: issuedCookie },
    });
    expect(second.status).toBe(200);
    expect((await second.json()).server).toBe(firstBody.server);
  });

  test("module rotates an invalid direct-peer cookie onto a live peer", async () => {
    const res = await fetch(`${TEST_URL}/issue-cookie`, {
      headers: { Cookie: "route=peer:127.0.0.1:19999" },
    });
    expect(res.status).toBe(200);
    const setCookie = res.headers.get("set-cookie");
    expect(setCookie).toContain("route=peer:");
    expect(setCookie).not.toContain("127.0.0.1:19999");
  });

  test("module respects custom cookie attributes when issuing affinity cookies", async () => {
    const res = await fetch(`${TEST_URL}/issue-cookie-custom`);
    expect(res.status).toBe(200);
    const setCookie = res.headers.get("set-cookie");
    expect(setCookie).toContain("route=peer:");
    expect(setCookie).toContain("Path=/issue-cookie-custom");
    expect(setCookie).toContain("Max-Age=60");
    expect(setCookie).toContain("SameSite=Strict");
  });

  test("status endpoint exposes balancer counters", async () => {
    await fetch(`${TEST_URL}/issue-cookie`);
    await fetch(`${TEST_URL}/issue-cookie`, {
      headers: { Cookie: "route=peer:127.0.0.1:19999" },
    });
    await fetch(`${TEST_URL}/weighted`, {
      headers: { Cookie: "route=status-key" },
    });
    await fetch(`${TEST_URL}/header`, {
      headers: { "X-Sticky-Key": "status-header-key" },
    });

    const res = await fetch(`${TEST_URL}/balancer-status`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.module).toBe("upstream_balancer");
    expect(body.status).toBe("ok");
    expect(body.requests_total).toBeGreaterThan(0);
    expect(body.sticky_cookie_requests_total).toBeGreaterThan(0);
    expect(body.sticky_header_requests_total).toBeGreaterThan(0);
    expect(body.hash_hits).toBeGreaterThan(0);
    expect(body.cookies_issued_total).toBeGreaterThan(0);
    expect(body.cookies_rotated_total).toBeGreaterThan(0);
    expect(body.direct_peer_misses).toBeGreaterThan(0);
    expect(typeof body.peer_rejections_tried_total).toBe("number");
    expect(typeof body.peer_rejections_unhealthy_total).toBe("number");
    expect(typeof body.peer_rejections_fail_window_total).toBe("number");
    expect(typeof body.peer_rejections_max_conns_total).toBe("number");
    expect(body.runtime_peer_source_requests_total).toBe(0);
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

describe("upstream-balancer round-robin state preservation", () => {
  let backend1;
  let backend2;

  beforeAll(async () => {
    backend1 = createHTTPMock(19102);
    backend1.setLatency(350);
    backend1.setDefault({ status: 200, body: { server: "backend1" } });

    backend2 = createHTTPMock(19103);
    backend2.setDefault({ status: 200, body: { server: "backend2" } });

    await startNginz(`tests/${MODULE}/nginx-runtime-semantics.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend1.stop();
    backend2.stop();
    cleanupRuntime(MODULE);
  });

  test("sticky path still respects max_conns and falls through to another peer", async () => {
    const key = stickyKeyForPeer(0, 2, "max-conns");

    const firstRequest = fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${key}` },
    });

    await Bun.sleep(75);

    const secondStartedAt = Date.now();
    const secondRes = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${key}` },
    });
    const secondElapsedMs = Date.now() - secondStartedAt;
    const secondBody = await secondRes.json();

    expect(secondRes.status).toBe(200);
    expect(secondBody.server).toBe("backend2");
    expect(secondElapsedMs).toBeLessThan(250);

    const firstRes = await firstRequest;
    expect(firstRes.status).toBe(200);
    expect((await firstRes.json()).server).toBe("backend1");
  });
});

describe("upstream-balancer backup peer semantics", () => {
  let backend1;
  let backend2;

  beforeAll(async () => {
    backend1 = createHTTPMock(19112);
    backend1.setDefault(async (req) => {
      if ((req.headers.get("cookie") || "").includes("route=backup-contract")) {
        await Bun.sleep(350);
      }
      return { status: 200, body: { server: "primary" } };
    });

    backend2 = createHTTPMock(19113);
    backend2.setDefault({ status: 200, body: { server: "backup" } });

    await startNginz(`tests/${MODULE}/nginx-backup.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend1.stop();
    backend2.stop();
    cleanupRuntime(MODULE);
  });

  test("sticky maps only over primaries; fallback next may route to backup when primaries are unavailable", async () => {
    const firstRequest = fetch(`${TEST_URL}/`, {
      headers: { Cookie: "route=backup-contract" },
    });

    await Bun.sleep(75);

    const secondStartedAt = Date.now();
    const secondRes = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: "route=backup-contract" },
    });
    const secondElapsedMs = Date.now() - secondStartedAt;
    const secondBody = await secondRes.json();

    expect(secondRes.status).toBe(200);
    expect(secondBody.server).toBe("backup");
    expect(secondElapsedMs).toBeLessThan(250);

    const firstRes = await firstRequest;
    expect(firstRes.status).toBe(200);
    expect((await firstRes.json()).server).toBe("primary");
  });
});

describe("upstream-balancer retry and failure accounting", () => {
  let backend2;
  let runtimeDir;

  beforeAll(async () => {
    backend2 = createHTTPMock(19123);
    backend2.setDefault({ status: 200, body: { server: "backend2" } });

    runtimeDir = await startNginz(`tests/${MODULE}/nginx-retry-failure.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend2.stop();
    cleanupRuntime(MODULE);
  });

  test("failed sticky-selected peer is retried once, then suppressed by nginx fail counters on the next request", async () => {
    const key = stickyKeyForPeer(0, 2, "retry-failure");
    const errorLogPath = join(runtimeDir, "logs", "error.log");

    const firstRes = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${key}` },
    });
    expect(firstRes.status).toBe(200);
    expect((await firstRes.json()).server).toBe("backend2");

    const afterFirst = readFileSync(errorLogPath, "utf8");
    const firstConnectErrors = countOccurrences(afterFirst, "connect() failed");
    expect(firstConnectErrors).toBe(1);

    const secondRes = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${key}` },
    });
    expect(secondRes.status).toBe(200);
    expect((await secondRes.json()).server).toBe("backend2");

    const afterSecond = readFileSync(errorLogPath, "utf8");
    const secondConnectErrors = countOccurrences(afterSecond, "connect() failed");
    expect(secondConnectErrors).toBe(1);
  });
});

// Phase 4: healthcheck integration.
// When a peer probe marks a backend unhealthy, the balancer must exclude it
// from sticky selection. Fail-open: peers with no probe always stay eligible.
describe("upstream-balancer healthcheck integration", () => {
  let backend1;
  let backend2;

  beforeAll(async () => {
    backend1 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1);
    backend1.get("/probe", { status: 200, body: { status: "ok" } });
    backend1.setDefault({ status: 200, body: { server: "backend1" } });

    backend2 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_2);
    backend2.get("/probe", { status: 200, body: { status: "ok" } });
    backend2.setDefault({ status: 200, body: { server: "backend2" } });

    await startNginz(`tests/${MODULE}/nginx-healthcheck-balancer.conf`, MODULE);
    // Give both probes time to fire once and mark backends healthy.
    await Bun.sleep(400);
  });

  afterAll(async () => {
    await stopNginz();
    backend1.stop();
    backend2.stop();
    cleanupRuntime(MODULE);
  });

  test("both backends are reachable when both probes pass", async () => {
    const servers = new Set();
    // Use different keys to hit both peers via CRC32 % 2 distribution.
    for (const key of ["hc-key-a", "hc-key-b", "hc-key-c", "hc-key-d"]) {
      const res = await fetch(`${TEST_URL}/`, {
        headers: { Cookie: `route=${key}` },
      });
      expect(res.status).toBe(200);
      servers.add((await res.json()).server);
    }
    // With 4 distinct keys across 2 backends we should see both.
    expect(servers.size).toBe(2);
  });

  test("unhealthy backend is excluded: all traffic shifts to the healthy peer", async () => {
    // Make backend2's probe fail → should become ineligible.
    backend2.get("/probe", { status: 500, body: { status: "fail" } });

    // Wait for the probe to fire and detect the failure (interval=100ms, fails=1).
    await Bun.sleep(400);

    // With only 1 eligible peer, every key maps to backend1.
    const servers = new Set();
    for (let i = 0; i < 8; i++) {
      const res = await fetch(`${TEST_URL}/`, {
        headers: { Cookie: `route=hc-key-${i}` },
      });
      expect(res.status).toBe(200);
      servers.add((await res.json()).server);
    }
    expect(servers).toEqual(new Set(["backend1"]));

    // Restore backend2 so subsequent tests aren't affected.
    backend2.get("/probe", { status: 200, body: { status: "ok" } });
  });

  test("recovering backend stays out of rotation during slow-start", async () => {
    // backend2 probe already restored above; probe succeeds quickly, but
    // slow-start should keep it out of sticky selection for a short window.
    await Bun.sleep(150);

    const servers = new Set();
    for (let i = 0; i < 8; i++) {
      const res = await fetch(`${TEST_URL}/`, {
        headers: { Cookie: `route=hc-recovering-${i}` },
      });
      expect(res.status).toBe(200);
      servers.add((await res.json()).server);
    }
    expect(servers).toEqual(new Set(["backend1"]));
  });

  test("backend returns after slow-start completes", async () => {
    await Bun.sleep(350);

    const servers = new Set();
    for (const key of ["hc-key-a", "hc-key-b", "hc-key-c", "hc-key-d"]) {
      const res = await fetch(`${TEST_URL}/`, {
        headers: { Cookie: `route=${key}` },
      });
      expect(res.status).toBe(200);
      servers.add((await res.json()).server);
    }
    expect(servers.size).toBe(2);
  });

  test("undrain does not bypass unhealthy or slow-start gating", async () => {
    const peer2Key = stickyKeyForPeer(1, 2, "hc-drain-peer2");

    let res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer2Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend2");

    res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19003" }),
    });
    expect(res.status).toBe(200);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer2Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend1");

    backend2.get("/probe", { status: 500, body: { status: "fail" } });
    await Bun.sleep(400);

    res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ undrain: "127.0.0.1:19003" }),
    });
    expect(res.status).toBe(200);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer2Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend1");

    backend2.get("/probe", { status: 200, body: { status: "ok" } });
    await Bun.sleep(150);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer2Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend1");

    await Bun.sleep(350);
    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer2Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend2");
  });
});

describe("upstream-balancer partial-mutation affinity regressions", () => {
  let backend1;
  let backend2;
  let backend3;

  beforeAll(async () => {
    backend1 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1);
    backend1.setDefault({ status: 200, body: { server: "backend1" } });

    backend2 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_2);
    backend2.setDefault({ status: 200, body: { server: "backend2" } });

    backend3 = createHTTPMock(19004);
    backend3.setDefault({ status: 200, body: { server: "backend3" } });

    await startNginz(`tests/${MODULE}/nginx-dynamic-partial.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend1.stop();
    backend2.stop();
    backend3.stop();
    cleanupRuntime(MODULE);
  });

  test("PATCH add appends a new peer without disturbing stable keys for unchanged order", async () => {
    await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 1 },
          { address: "127.0.0.1:19003", weight: 1 },
        ],
      }),
    });

    const stableKey = stickyKeyStableAcrossCounts(1, 2, 3, "append-stable-backend2");
    let res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${stableKey}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend2");

    res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        add: [{ address: "127.0.0.1:19004", weight: 1 }],
      }),
    });
    expect(res.status).toBe(200);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${stableKey}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend2");

    const newPeerKey = stickyKeyForPeer(2, 3, "append-backend3");
    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${newPeerKey}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend3");
  });

  test("removed direct-peer cookies are treated as stale and rotated onto a live peer", async () => {
    await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 1 },
          { address: "127.0.0.1:19003", weight: 1 },
          { address: "127.0.0.1:19004", weight: 1 },
        ],
      }),
    });
    let res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ remove: ["127.0.0.1:19002"] }),
    });
    expect(res.status).toBe(200);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: "route=peer:127.0.0.1:19002" },
    });
    expect(res.status).toBe(200);
    expect(["backend2", "backend3"]).toContain((await res.json()).server);
    expect(res.headers.get("set-cookie")).toContain("route=peer:");
    expect(res.headers.get("set-cookie")).not.toContain("127.0.0.1:19002");
  });

  test("draining direct-peer cookies are treated as stale and rotated onto a non-draining peer", async () => {
    await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 1 },
          { address: "127.0.0.1:19003", weight: 1 },
        ],
      }),
    });
    let res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: "route=peer:127.0.0.1:19002" },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend2");
    expect(res.headers.get("set-cookie")).toContain("route=peer:127.0.0.1:19003");
  });

  test("draining and undraining a hashed sticky target remaps and restores deterministic selection", async () => {
    await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 1 },
          { address: "127.0.0.1:19003", weight: 1 },
        ],
      }),
    });

    const peer1Key = stickyKeyForPeer(0, 2, "drain-remap-peer1");

    let res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer1Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend1");

    res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer1Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend2");

    res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ undrain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);

    res = await fetch(`${TEST_URL}/`, {
      headers: { Cookie: `route=${peer1Key}` },
    });
    expect(res.status).toBe(200);
    expect((await res.json()).server).toBe("backend1");
  });
});
