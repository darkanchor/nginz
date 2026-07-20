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

async function sampleUpstreamVersions(path, n, init = {}) {
  const versions = { stable: 0, canary: 0 };
  for (let i = 0; i < n; i++) {
    const res = await fetchClose(`${TEST_URL}${path}`, init);
    const body = await res.json();
    if (body.version in versions) versions[body.version]++;
  }
  return versions;
}

// 10% canary is binomial noise at small n (Bin(100,0.1) hits ≤2 ~0.2% of the time).
// Sample enough that "both sides seen" / loose band checks stop flaking.
const PCT_SAMPLES = 300;

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
      const versions = await sampleUpstreamVersions("/api/test", PCT_SAMPLES);

      // With 10% canary, expect roughly 90/10; wide band for CSPRNG noise.
      expect(versions.stable).toBeGreaterThan(PCT_SAMPLES * 0.7);
      expect(versions.canary).toBeGreaterThan(PCT_SAMPLES * 0.02);
      expect(versions.canary).toBeLessThan(PCT_SAMPLES * 0.3);
    });

    test("maintains statistical distribution over many requests", async () => {
      const n = 400;
      const versions = await sampleUpstreamVersions("/api/test", n);

      // Canary percentage should be roughly 10% (allow ~2-25% range)
      const canaryPct = (versions.canary / n) * 100;
      expect(canaryPct).toBeGreaterThan(2);
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
      const versions = await sampleUpstreamVersions("/api-combined/test", PCT_SAMPLES);

      // Percentage fallback (10%): both sides must appear; avoid tight floors
      // that flake under Bin(n, 0.1) tails (e.g. canary === 2 with n=100).
      expect(versions.stable).toBeGreaterThan(PCT_SAMPLES * 0.7);
      expect(versions.canary).toBeGreaterThan(PCT_SAMPLES * 0.02);
    });

    test("falls back to percentage when header is present but does not match", async () => {
      const versions = await sampleUpstreamVersions("/api-combined/test", PCT_SAMPLES, {
        headers: { "X-Canary": "false" },
      });

      expect(versions.stable).toBeGreaterThan(PCT_SAMPLES * 0.7);
      expect(versions.canary).toBeGreaterThan(PCT_SAMPLES * 0.02);
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
      const n = 200;

      for (let i = 0; i < n; i++) {
        const res = await fetchClose(`${TEST_URL}/debug`);
        const body = await res.text();
        if (body === "canary=1\n") {
          canaryCount++;
        }
      }

      // 50% canary; wider band than 30-70@n=100 to absorb CSPRNG tails
      expect(canaryCount).toBeGreaterThan(n * 0.3);
      expect(canaryCount).toBeLessThan(n * 0.7);
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
