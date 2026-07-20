import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  MOCK_PORTS,
  createMockManager,
} from "../harness.js";

const MODULE = "canary";
let mocks;
let stableUpstream;
let canaryUpstream;


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("canary module", () => {
  beforeAll(async () => {
    mocks = createMockManager();

    // Create stable and canary upstream servers
    stableUpstream = mocks.add(
      "stable",
      createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1)
    );
    canaryUpstream = mocks.add(
      "canary",
      createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_2)
    );

    // Configure responses to identify which upstream handled the request
    // Use catch-all pattern to handle all paths
    stableUpstream.get("/*", (req, url) => ({
      body: { version: "stable", path: url.pathname },
    }));

    canaryUpstream.get("/*", (req, url) => ({
      body: { version: "canary", path: url.pathname },
    }));

    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    await mocks.stopAll();
    cleanupRuntime(MODULE);
  });

  describe("percentage-based routing", () => {
    test("routes traffic to both stable and canary", async () => {
      const versions = { stable: 0, canary: 0 };

      // Make 100 requests to get a statistical distribution
      for (let i = 0; i < 100; i++) {
        const res = await fetchClose(`${TEST_URL}/api/test`);
        const body = await res.json();
        versions[body.version]++;
      }

      // With 10% canary, expect roughly 90 stable, 10 canary
      // Allow some variance due to randomness
      expect(versions.stable).toBeGreaterThan(70);
      expect(versions.canary).toBeGreaterThan(2);
      expect(versions.canary).toBeLessThan(30);
    });

    test("maintains statistical distribution over many requests", async () => {
      const versions = { stable: 0, canary: 0 };

      for (let i = 0; i < 200; i++) {
        const res = await fetchClose(`${TEST_URL}/api/test`);
        const body = await res.json();
        versions[body.version]++;
      }

      // Canary percentage should be roughly 10% (allow 3-25% range)
      const canaryPct = (versions.canary / 200) * 100;
      expect(canaryPct).toBeGreaterThan(3);
      expect(canaryPct).toBeLessThan(25);
    });
  });

  describe("header-based routing", () => {
    test("routes to canary when X-Canary header is true", async () => {
      const res = await fetchClose(`${TEST_URL}/api-header/test`, {
        headers: { "X-Canary": "true" },
      });
      const body = await res.json();
      expect(body.version).toBe("canary");
    });

    test("routes to stable when X-Canary header is absent", async () => {
      const res = await fetchClose(`${TEST_URL}/api-header/test`);
      const body = await res.json();
      expect(body.version).toBe("stable");
    });

    test("routes to stable when X-Canary header has wrong value", async () => {
      const res = await fetchClose(`${TEST_URL}/api-header/test`, {
        headers: { "X-Canary": "false" },
      });
      const body = await res.json();
      expect(body.version).toBe("stable");
    });

    test("header matching is case-insensitive", async () => {
      const res = await fetchClose(`${TEST_URL}/api-header/test`, {
        headers: { "x-canary": "TRUE" },
      });
      const body = await res.json();
      expect(body.version).toBe("canary");
    });
  });

  describe("combined header + percentage", () => {
    test("header takes priority over percentage", async () => {
      // With header, should always go to canary
      for (let i = 0; i < 10; i++) {
        const res = await fetchClose(`${TEST_URL}/api-combined/test`, {
          headers: { "X-Canary": "true" },
        });
        const body = await res.json();
        expect(body.version).toBe("canary");
      }
    });

    test("falls back to percentage when header absent", async () => {
      const versions = { stable: 0, canary: 0 };

      for (let i = 0; i < 100; i++) {
        const res = await fetchClose(`${TEST_URL}/api-combined/test`);
        const body = await res.json();
        versions[body.version]++;
      }

      // Should see both versions (percentage fallback working)
      expect(versions.stable).toBeGreaterThan(70);
      expect(versions.canary).toBeGreaterThan(2);
    });

    test("falls back to percentage when header is present but does not match", async () => {
      const versions = { stable: 0, canary: 0 };

      for (let i = 0; i < 100; i++) {
        const res = await fetchClose(`${TEST_URL}/api-combined/test`, {
          headers: { "X-Canary": "false" },
        });
        const body = await res.json();
        versions[body.version]++;
      }

      expect(versions.stable).toBeGreaterThan(70);
      expect(versions.canary).toBeGreaterThan(2);
    });
  });

  describe("percentage boundaries", () => {
    test("0 percent always routes to stable", async () => {
      for (let i = 0; i < 20; i++) {
        const res = await fetchClose(`${TEST_URL}/api-zero/test`);
        const body = await res.json();
        expect(body.version).toBe("stable");
      }
    });

    test("100 percent always routes to canary", async () => {
      for (let i = 0; i < 20; i++) {
        const res = await fetchClose(`${TEST_URL}/api-full/test`);
        const body = await res.json();
        expect(body.version).toBe("canary");
      }
    });
  });

  describe("disabled location", () => {
    test("always routes to stable when canary not enabled", async () => {
      for (let i = 0; i < 20; i++) {
        const res = await fetchClose(`${TEST_URL}/api-disabled/test`);
        const body = await res.json();
        expect(body.version).toBe("stable");
      }
    });
  });

  describe("$ngz_canary variable", () => {
    test("variable returns 0 or 1", async () => {
      const res = await fetchClose(`${TEST_URL}/debug`);
      const body = await res.text();
      expect(body).toMatch(/^canary=[01]\n$/);
    });

    test("variable distribution matches percentage", async () => {
      let canaryCount = 0;

      for (let i = 0; i < 100; i++) {
        const res = await fetchClose(`${TEST_URL}/debug`);
        const body = await res.text();
        if (body === "canary=1\n") {
          canaryCount++;
        }
      }

      // 50% canary, expect roughly 40-60%
      expect(canaryCount).toBeGreaterThan(30);
      expect(canaryCount).toBeLessThan(70);
    });

    test("variable decision is stable within a single request", async () => {
      for (let i = 0; i < 20; i++) {
        const res = await fetchClose(`${TEST_URL}/debug-double`);
        const body = await res.text();
        expect(body).toMatch(/^[01],[01]\n$/);

        const [first, second] = body.trim().split(",");
        expect(second).toBe(first);
      }
    });
  });
});
