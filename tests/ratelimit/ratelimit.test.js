import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  reloadNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "ratelimit";


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

// Wait until `offsetMs` into the next wall-clock second. Used by the capacity
// test so a ~200ms concurrent fill does not straddle the fixed 1s window.
function sleepUntilNextSecondPlus(offsetMs = 30) {
  const into = Date.now() % 1000;
  return Bun.sleep(1000 - into + offsetMs);
}

describe("ratelimit module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  describe("non-rate-limited endpoints", () => {
    test("allows unlimited requests to non-rate-limited endpoint", async () => {
      // Make many requests - should all succeed
      for (let i = 0; i < 20; i++) {
        const res = await fetchClose(`${TEST_URL}/`);
        expect(res.status).toBe(200);
      }
    });
  });

  describe("rate limiting", () => {
    test("allows requests under the limit", async () => {
      // Wait for any previous window to expire
      await Bun.sleep(1100);

      // /api has 5r/s limit - make 3 requests, should all succeed
      for (let i = 0; i < 3; i++) {
        const res = await fetchClose(`${TEST_URL}/api`);
        expect(res.status).toBe(200);
      }
    });

    test("returns 429 when limit exceeded", async () => {
      // Wait for window to reset
      await Bun.sleep(1100);

      // /strict has 2r/s limit
      const results = [];
      for (let i = 0; i < 5; i++) {
        const res = await fetchClose(`${TEST_URL}/strict`);
        results.push(res.status);
      }

      // First 2 should succeed, rest should be 429
      expect(results.filter((s) => s === 200).length).toBe(2);
      expect(results.filter((s) => s === 429).length).toBe(3);
    });

    test("resets after window expires", async () => {
      // Wait for window to reset
      await Bun.sleep(1100);

      // Exhaust the limit
      for (let i = 0; i < 3; i++) {
        await fetchClose(`${TEST_URL}/strict`);
      }

      // Should be rate limited now
      const limitedRes = await fetchClose(`${TEST_URL}/strict`);
      expect(limitedRes.status).toBe(429);

      // Wait for window to reset (1 second)
      await Bun.sleep(1100);

      // Should be allowed again
      const resetRes = await fetchClose(`${TEST_URL}/strict`);
      expect(resetRes.status).toBe(200);
    });
  });

  describe("burst handling", () => {
    test("allows burst requests up to burst limit", async () => {
      // Wait for window to reset
      await Bun.sleep(1100);

      // /burst has 3r/s + 2 burst = 5 total per window
      const results = [];
      for (let i = 0; i < 7; i++) {
        const res = await fetchClose(`${TEST_URL}/burst`);
        results.push(res.status);
      }

      // First 5 should succeed (3 rate + 2 burst), rest should be 429
      expect(results.filter((s) => s === 200).length).toBe(5);
      expect(results.filter((s) => s === 429).length).toBe(2);
    });

    test("shared counters enforce the fixed window across multiple workers", async () => {
      await Bun.sleep(1100);

      const statuses = await Promise.all(
        Array.from({ length: 6 }, () => fetchClose(`${TEST_URL}/api`).then((res) => res.status))
      );

      expect(statuses.filter((s) => s === 200).length).toBe(5);
      expect(statuses.filter((s) => s === 429).length).toBe(1);
    });
  });

  describe("rate limit isolation", () => {
    test("different endpoints keep separate counters", async () => {
      // Wait for window to reset
      await Bun.sleep(1100);

      // Exhaust /strict limit (2r/s)
      await fetchClose(`${TEST_URL}/strict`);
      await fetchClose(`${TEST_URL}/strict`);

      // /strict should be limited
      const strictRes = await fetchClose(`${TEST_URL}/strict`);
      expect(strictRes.status).toBe(429);

      // /api should still work because it has its own per-location limit window
      const apiRes = await fetchClose(`${TEST_URL}/api`);
      expect(apiRes.status).toBe(200);
    });

    test("plain numeric ratelimit syntax is enforced", async () => {
      await Bun.sleep(1100);

      const results = [];
      for (let i = 0; i < 6; i++) {
        const res = await fetchClose(`${TEST_URL}/plain`);
        results.push(res.status);
      }

      expect(results.filter((s) => s === 200).length).toBe(4);
      expect(results.filter((s) => s === 429).length).toBe(2);
    });
  });

  describe("generic variable inputs", () => {
    test("shared ratelimit_key can make multiple requests in one location consume the same budget", async () => {
      await Bun.sleep(1100);

      const statuses = [];
      statuses.push((await fetchClose(`${TEST_URL}/shared-a`)).status);
      statuses.push((await fetchClose(`${TEST_URL}/shared-a`)).status);
      statuses.push((await fetchClose(`${TEST_URL}/shared-a`)).status);

      expect(statuses).toEqual([200, 200, 429]);
    });

    test("same ratelimit_key in different locations still keeps separate location-scoped budgets", async () => {
      await Bun.sleep(1100);

      await fetchClose(`${TEST_URL}/shared-parent-a`);
      await fetchClose(`${TEST_URL}/shared-parent-a`);

      const otherLocation = await fetchClose(`${TEST_URL}/shared-parent-b`);
      expect(otherLocation.status).toBe(200);
    });

    test("ratelimit_cost variable can consume more than one token per request", async () => {
      await Bun.sleep(1100);

      const [first, second] = await Promise.all([
        fetchClose(`${TEST_URL}/costly`),
        fetchClose(`${TEST_URL}/costly`),
      ]);

      const responses = [first, second];
      const allowed = responses.filter((res) => res.status === 200);
      const denied = responses.filter((res) => res.status === 429);

      expect(allowed).toHaveLength(1);
      expect(denied).toHaveLength(1);
      expect(allowed[0].headers.get("x-ratelimit-cost")).toBe("2");
      expect(allowed[0].headers.get("x-ratelimit-source")).toBe("ip");
      expect(allowed[0].headers.get("x-ratelimit-result")).toBe("allow");
    });

    test("ratelimit_skip variable bypasses enforcement while still exposing allow result", async () => {
      await Bun.sleep(1100);

      for (let i = 0; i < 5; i++) {
        const res = await fetchClose(`${TEST_URL}/skip`);
        expect(res.status).toBe(200);
        expect(res.headers.get("x-ratelimit-result")).toBe("allow");
      }
    });
  });

  describe("ratelimit observability variables", () => {
    test("default path exposes IP-derived key, source, cost, and decision", async () => {
      await Bun.sleep(1100);

      const res = await fetchClose(`${TEST_URL}/observed`);

      expect(res.status).toBe(200);
      expect(res.headers.get("x-ratelimit-cost")).toBe("1");
      expect(res.headers.get("x-ratelimit-source")).toBe("ip");
      expect(res.headers.get("x-ratelimit-result")).toBe("allow");
      expect(res.headers.get("x-ratelimit-key")).toBeTruthy();
    });
  });

  describe("config inheritance", () => {
    test("child explicit ratelimit_rate 10 does not inherit a parent non-10 rate", async () => {
      await Bun.sleep(1100);

      const statuses = [];
      for (let i = 0; i < 11; i++) {
        statuses.push((await fetchClose(`${TEST_URL}/inherit-parent/child-rate-10`)).status);
      }

      expect(statuses.filter((s) => s === 200).length).toBe(10);
      expect(statuses.filter((s) => s === 429).length).toBe(1);
    });
  });

  test("reports full-table rejection and preserves counters across two-worker reload", async () => {
    await stopNginz();
    await startNginz(`tests/${MODULE}/nginx-capacity-reload.conf`, MODULE);

    try {
      // Fixed windows are whole wall-clock seconds. A concurrent 1024-key fill
      // takes ~200ms; if it straddles a second boundary, early entries become
      // reclaimable and overflow gets 200 instead of capacity-reject 429.
      // Align to the start of a second so fill + overflow stay in one window.
      await sleepUntilNextSecondPlus(30);

      const fills = await Promise.all(
        Array.from({ length: 1024 }, (_, index) =>
          fetchClose(`${TEST_URL}/fill?k=key-${index}`).then((res) => res.status),
        ),
      );
      expect(fills.every((status) => status === 200)).toBe(true);

      const overflow = await fetchClose(`${TEST_URL}/fill?k=overflow`);
      expect(overflow.status).toBe(429);

      let metrics = await fetchClose(`${TEST_URL}/metrics`);
      expect(metrics.status).toBe(200);
      expect(metrics.headers.get("x-ratelimit-entries")).toBe("1024");
      expect(metrics.headers.get("x-ratelimit-capacity-rejected")).toBe("1");
      expect(metrics.headers.get("x-ratelimit-reclaimed")).toBe("0");

      await reloadNginz();

      metrics = await fetchClose(`${TEST_URL}/metrics`);
      expect(metrics.status).toBe(200);
      expect(metrics.headers.get("x-ratelimit-entries")).toBe("1024");
      expect(metrics.headers.get("x-ratelimit-capacity-rejected")).toBe("1");
      expect(metrics.headers.get("x-ratelimit-reclaimed")).toBe("0");
    } finally {
      await stopNginz();
      await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
    }
  }, 15000);
});
