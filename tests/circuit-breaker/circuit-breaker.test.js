import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import {
  startNginz,
  reloadNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  MOCK_PORTS,
  createMockManager,
} from "../harness.js";

const MODULE = "circuit-breaker";
let mocks;
let upstream;

function configureDefaultUpstream() {
  upstream.get("/", { body: { status: "ok" }, status: 200 });
  upstream.get("/*", { body: { status: "ok" }, status: 200 });
}


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("circuit-breaker module", () => {
  beforeAll(async () => {
    mocks = createMockManager();

    // Create upstream server on port 19002
    upstream = mocks.add("upstream", createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1));
  });

  afterAll(async () => {
    await stopNginz();
    await mocks.stopAll();
    cleanupRuntime(MODULE);
  });

  beforeEach(async () => {
    await stopNginz();
    upstream.reset();
    configureDefaultUpstream();
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  describe("closed state", () => {
    test("allows requests when circuit is closed", async () => {
      const res = await fetchClose(`${TEST_URL}/protected`);
      expect(res.status).toBe(200);
      expect(res.headers.get("X-Circuit-Admission")).toBe("allow");
      expect(res.headers.get("X-Circuit-Entries")).toBe("1");
      expect(res.headers.get("X-Circuit-Capacity")).toBe("64");
    });

    test("forwards requests to upstream", async () => {
      await fetchClose(`${TEST_URL}/protected`);
      const requests = upstream.getRequests();
      expect(requests.length).toBeGreaterThanOrEqual(1);
    });

    test("successful requests reset the failure streak in closed state", async () => {
      let requestNumber = 0;

      upstream.get("/protected", (req, url, logEntry) => {
        requestNumber += 1;

        if (requestNumber === 1 || requestNumber === 3 || requestNumber === 4) {
          return { status: 500, body: { status: "error", requestNumber } };
        }

        return { status: 200, body: { status: "ok", requestNumber } };
      });

      const res1 = await fetchClose(`${TEST_URL}/protected`);
      expect(res1.status).toBe(500);

      const res2 = await fetchClose(`${TEST_URL}/protected`);
      expect(res2.status).toBe(200);

      const res3 = await fetchClose(`${TEST_URL}/protected`);
      expect(res3.status).toBe(500);

      upstream.clearLog();
      const res4 = await fetchClose(`${TEST_URL}/protected`);
      expect(res4.status).toBe(500);
      expect(upstream.getRequests().length).toBe(1);

      upstream.clearLog();
      const res5 = await fetchClose(`${TEST_URL}/protected`);
      expect(res5.status).toBe(200);
      expect(upstream.getRequests().length).toBe(1);
    });

    test("non-5xx upstream responses do not count as failures", async () => {
      upstream.get("/protected", { status: 404, body: { status: "missing" } });

      for (let i = 0; i < 5; i++) {
        const res = await fetchClose(`${TEST_URL}/protected`);
        expect(res.status).toBe(404);
      }

      upstream.clearLog();
      const res = await fetchClose(`${TEST_URL}/protected`);
      expect(res.status).toBe(404);
      expect(upstream.getRequests().length).toBe(1);
    });
  });

  describe("open state", () => {
    test("opens circuit after threshold failures", async () => {
      // Set upstream to return 500 errors
      upstream.setFailureRate(1.0);

      // Trigger failures to open circuit (threshold = 3 for /protected)
      for (let i = 0; i < 4; i++) {
        await fetchClose(`${TEST_URL}/protected`);
      }

      // Circuit should be open now, returning 503 without hitting upstream
      upstream.clearLog();
      const res = await fetchClose(`${TEST_URL}/protected`);
      expect(res.status).toBe(503);

      // Verify no request reached upstream (circuit breaker blocked it)
      const requests = upstream.getRequests();
      expect(requests.length).toBe(0);
    });

    test("returns 503 when circuit is open", async () => {
      // Open the circuit using /fast endpoint (threshold = 2)
      upstream.setFailureRate(1.0);

      for (let i = 0; i < 3; i++) {
        await fetchClose(`${TEST_URL}/fast`);
      }

      upstream.setFailureRate(0);
      upstream.clearLog();

      // Should return 503 immediately
      const res = await fetchClose(`${TEST_URL}/fast`);
      expect(res.status).toBe(503);
    });

    test("open circuit state is enforced across workers", async () => {
      upstream.setFailureRate(1.0);

      await Promise.all(
        Array.from({ length: 8 }, () => fetchClose(`${TEST_URL}/protected`))
      );

      upstream.setFailureRate(0);
      upstream.clearLog();

      const blockedResponses = await Promise.all(
        Array.from({ length: 12 }, () => fetchClose(`${TEST_URL}/protected`))
      );

      for (const res of blockedResponses) {
        expect(res.status).toBe(503);
        expect(res.headers.get("X-Circuit-State")).toBe("open");
      }

      expect(upstream.getRequests().length).toBe(0);
    });

    test("preserves an open two-worker circuit across graceful reload", async () => {
      upstream.setFailureRate(1.0);
      for (let i = 0; i < 3; i += 1) {
        const res = await fetchClose(`${TEST_URL}/protected`);
        expect(res.status).toBe(500);
      }

      await reloadNginz();
      upstream.setFailureRate(0);
      upstream.clearLog();

      const blocked = await fetchClose(`${TEST_URL}/protected`);
      expect(blocked.status).toBe(503);
      expect(blocked.headers.get("X-Circuit-State")).toBe("open");
      expect(upstream.getRequests()).toHaveLength(0);
    });
  });

  describe("half-open state", () => {
    test("transitions to half-open after timeout", async () => {
      // Open the circuit using /fast endpoint (timeout = 1s)
      upstream.setFailureRate(1.0);

      for (let i = 0; i < 3; i++) {
        await fetchClose(`${TEST_URL}/fast`);
      }

      // Verify circuit is open
      upstream.setFailureRate(0);
      upstream.clearLog();

      const openRes = await fetchClose(`${TEST_URL}/fast`);
      expect(openRes.status).toBe(503);

      // Wait for timeout (1s + buffer)
      await Bun.sleep(1200);

      // Circuit should be half-open, allowing a test request
      const halfOpenRes = await fetchClose(`${TEST_URL}/fast`);
      expect(halfOpenRes.status).toBe(200);
    });

    test("closes circuit after successful requests in half-open", async () => {
      // Open the circuit
      upstream.setFailureRate(1.0);

      for (let i = 0; i < 3; i++) {
        await fetchClose(`${TEST_URL}/fast`);
      }

      upstream.setFailureRate(0);

      // Wait for timeout
      await Bun.sleep(1200);

      // Send successful request (half-open allows 1)
      const res1 = await fetchClose(`${TEST_URL}/fast`);
      expect(res1.status).toBe(200);

      // Circuit should be closed now (success_threshold = 1 for /fast)
      // Next request should also succeed
      const res2 = await fetchClose(`${TEST_URL}/fast`);
      expect(res2.status).toBe(200);
    });

    test("admits only one concurrent half-open recovery probe", async () => {
      upstream.setFailureRate(1.0);
      for (let i = 0; i < 3; i += 1) {
        await fetchClose(`${TEST_URL}/fast`);
      }

      await Bun.sleep(1200);
      upstream.setFailureRate(0);
      upstream.setLatency(250);
      upstream.clearLog();

      const responses = await Promise.all(
        Array.from({ length: 12 }, () => fetchClose(`${TEST_URL}/fast`)),
      );
      const statuses = responses.map((response) => response.status);
      expect(statuses.filter((status) => status === 200)).toHaveLength(1);
      expect(statuses.filter((status) => status === 503)).toHaveLength(11);
      expect(upstream.getRequests()).toHaveLength(1);
    });

    test("re-opens circuit on failure in half-open state", async () => {
      // Open the circuit
      upstream.setFailureRate(1.0);

      for (let i = 0; i < 3; i++) {
        await fetchClose(`${TEST_URL}/fast`);
      }

      // Wait for timeout
      await Bun.sleep(1200);

      // Still failing - this should re-open the circuit immediately
      const halfOpenRes = await fetchClose(`${TEST_URL}/fast`);
      expect(halfOpenRes.status).toBe(500); // Upstream error

      // Circuit should be open again
      upstream.setFailureRate(0);
      upstream.clearLog();

      const openRes = await fetchClose(`${TEST_URL}/fast`);
      expect(openRes.status).toBe(503);
    });

    test("raw millisecond timeout transitions to half-open", async () => {
      upstream.setFailureRate(1.0);

      const failureRes = await fetchClose(`${TEST_URL}/millis`);
      expect(failureRes.status).toBe(500);

      upstream.setFailureRate(0);
      upstream.clearLog();

      const openRes = await fetchClose(`${TEST_URL}/millis`);
      expect(openRes.status).toBe(503);

      await Bun.sleep(350);

      const recoveredRes = await fetchClose(`${TEST_URL}/millis`);
      expect(recoveredRes.status).toBe(200);
    });
  });

  describe("circuit state variable", () => {
    test("exposes $ngz_circuit_state variable", async () => {
      const res = await fetchClose(`${TEST_URL}/state`);
      expect(res.status).toBe(200);

      const body = await res.text();
      expect(body).toContain("state:");
    });

    test("shows closed state initially", async () => {
      const res = await fetchClose(`${TEST_URL}/state`);
      const body = await res.text();
      expect(body).toContain("closed");
    });

    test("sets X-Circuit-State header", async () => {
      const res = await fetchClose(`${TEST_URL}/state`);
      const state = res.headers.get("X-Circuit-State");
      expect(state).toBe("closed");
    });

    test("state variable reports open after threshold failures", async () => {
      upstream.setFailureRate(1.0);

      for (let i = 0; i < 3; i++) {
        await fetchClose(`${TEST_URL}/protected`);
      }

      const res = await fetchClose(`${TEST_URL}/protected`);
      expect(res.status).toBe(503);
      expect(res.headers.get("X-Circuit-State")).toBe("open");
    });
  });

  describe("non-circuit-breaker endpoints", () => {
    test("regular endpoints work normally", async () => {
      const res = await fetchClose(`${TEST_URL}/`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("ok\n");
    });
  });

});
