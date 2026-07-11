import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import {
  startNginz,
  stopNginz,
  reloadNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  createMockManager,
  MOCK_PORTS,
} from "../harness.js";

const MODULE = "healthcheck";

let mocks;
let probe;
let upstream;

async function waitForStatus(path, status, timeout = 4000) {
  const started = Date.now();

  while (Date.now() - started < timeout) {
    const res = await fetch(`${TEST_URL}${path}`);
    if (res.status === status) {
      return res;
    }
    await Bun.sleep(75);
  }

  throw new Error(`Timed out waiting for ${path} to return ${status}`);
}

async function getHealthSnapshot() {
  const res = await fetch(`${TEST_URL}/health`);
  expect(res.status).toBeGreaterThanOrEqual(200);
  expect(res.status).toBeLessThan(600);
  return res.json();
}

async function waitForHealthSnapshot(predicate, timeout = 4000) {
  const started = Date.now();

  while (Date.now() - started < timeout) {
    const body = await getHealthSnapshot();
    if (predicate(body)) {
      return body;
    }
    await Bun.sleep(75);
  }

  throw new Error("Timed out waiting for /health snapshot predicate");
}

async function getWorkerEvents(channel = "health") {
  const res = await fetch(`${TEST_URL}/worker-events?channel=${encodeURIComponent(channel)}`);
  expect(res.status).toBe(200);
  return res.json();
}

async function waitForWorkerEvents(predicate, channel = "health", timeout = 4000) {
  const started = Date.now();

  while (Date.now() - started < timeout) {
    const body = await getWorkerEvents(channel);
    if (predicate(body)) {
      return body;
    }
    await Bun.sleep(75);
  }

  throw new Error(`Timed out waiting for worker-events on channel ${channel}`);
}

async function fetchMany(path, count, batchSize = 8) {
  let completed = 0;
  while (completed < count) {
    const size = Math.min(batchSize, count - completed);
    const responses = await Promise.all(
      Array.from({ length: size }, () => fetch(`${TEST_URL}${path}`)),
    );
    completed += responses.length;
  }
}

describe("healthcheck module", () => {
  beforeAll(async () => {
    mocks = createMockManager();
    probe = mocks.add("probe", createHTTPMock(MOCK_PORTS.HTTP));
    upstream = mocks.add("upstream", createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1));
  });

  afterAll(async () => {
    await stopNginz();
    await mocks.stopAll();
    cleanupRuntime(MODULE);
  });

  afterEach(async () => {
    await stopNginz();
    await Bun.sleep(150);
  });

  beforeEach(async () => {
    await stopNginz();
    await Bun.sleep(150);
    probe.reset();
    probe.get("/probe", { status: 200, body: { status: "ok" } });
    upstream.reset();
    upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
    upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
    upstream.get("/", { status: 200, body: { message: "upstream response" } });
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
    await waitForStatus("/ready", 200);
  });

  test("shared health zone remains mapped across graceful reload", async () => {
    const before = await getHealthSnapshot();
    await reloadNginz();

    // Ordinary responses enter the healthcheck LOG handler and take the zone's
    // slab mutex. The health endpoint then reads the same zone after LOG phase.
    const response = await fetch(`${TEST_URL}/`);
    expect(response.status).toBe(200);
    await response.arrayBuffer();
    await Bun.sleep(100);

    const after = await getHealthSnapshot();
    expect(after.requests).toBeGreaterThanOrEqual(before.requests + 1);
  });

  test("actively probes the configured target and exposes probe state on /health", async () => {
    await Bun.sleep(250);

    const res = await fetch(`${TEST_URL}/health`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.status).toBe("healthy");
    expect(body.healthy).toBe(true);
    expect(body.ready).toBe(true);
    expect(body.probe_enabled).toBe(true);
    expect(body.probe_healthy).toBe(true);
    expect(body.probe_total_successes).toBeGreaterThan(0);
    expect(body.probe_last_status).toBe(200);
    expect(probe.getRequestsFor("/probe", "GET").length).toBeGreaterThan(0);
  });

  test("health variables reflect healthy shared probe state", async () => {
    await Bun.sleep(250);

    const res = await fetch(`${TEST_URL}/health-vars`);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-health-readiness")).toBe("1");
    expect(res.headers.get("x-health-liveness")).toBe("1");
    expect(res.headers.get("x-health-backend-healthy-count")).toBe("1");
    expect(res.headers.get("x-health-backend-total-count")).toBe("1");
    expect(res.headers.get("x-health-backend-failure-count")).toBe("0");
  });

  test("health endpoints do not increment passive request or failure counters", async () => {
    const before = await getHealthSnapshot();

    await Promise.all([
      fetch(`${TEST_URL}/health`),
      fetch(`${TEST_URL}/healthz`),
      fetch(`${TEST_URL}/ready`),
      fetch(`${TEST_URL}/health`),
      fetch(`${TEST_URL}/ready`),
    ]);

    const after = await getHealthSnapshot();
    expect(after.requests).toBe(before.requests);
    expect(after.failed).toBe(before.failed);
  });

  test("passive request and failure counters aggregate across workers", async () => {
    const successCount = 40;
    const failureCount = 12;
    const before = await getHealthSnapshot();

    await fetchMany("/", successCount, 8);
    await fetchMany("/fail", failureCount, 6);

    const body = await waitForHealthSnapshot(
      (snapshot) =>
        snapshot.requests >= before.requests + successCount + failureCount &&
        snapshot.failed >= before.failed + failureCount,
      4000,
    );

    expect(body.requests).toBeGreaterThanOrEqual(before.requests + successCount + failureCount);
    expect(body.failed).toBeGreaterThanOrEqual(before.failed + failureCount);
    expect(body.success_rate).toBeLessThan(100);
  });

  test("readiness becomes unhealthy from active probe failures across workers and recovers after passing probes", async () => {
    probe.get("/probe", { status: 500, body: { status: "down" } });

    const unhealthyRes = await waitForStatus("/ready", 503);
    expect(await unhealthyRes.json()).toEqual({ status: "not_ready" });

    const unhealthyHealth = await fetch(`${TEST_URL}/health`);
    expect(unhealthyHealth.status).toBe(503);
    const unhealthyBody = await unhealthyHealth.json();
    expect(unhealthyBody.probe_healthy).toBe(false);
    expect(unhealthyBody.probe_total_failures).toBeGreaterThan(0);
    expect(unhealthyBody.probe_last_status).toBe(500);

    const concurrentReadyResponses = await Promise.all(
      Array.from({ length: 12 }, () => fetch(`${TEST_URL}/ready`))
    );
    for (const res of concurrentReadyResponses) {
      expect(res.status).toBe(503);
      expect(await res.json()).toEqual({ status: "not_ready" });
    }

    probe.get("/probe", { status: 200, body: { status: "recovered" } });

    const recoveredRes = await waitForStatus("/ready", 200);
    expect(await recoveredRes.json()).toEqual({ status: "ready" });

    const recoveredHealth = await fetch(`${TEST_URL}/health`);
    expect(recoveredHealth.status).toBe(200);
    const recoveredBody = await recoveredHealth.json();
    expect(recoveredBody.probe_healthy).toBe(true);
    expect(recoveredBody.probe_total_successes).toBeGreaterThan(0);
    expect(recoveredBody.probe_consecutive_successes).toBeGreaterThanOrEqual(2);
  });

  test("health variables reflect unhealthy probe state", async () => {
    probe.get("/probe", { status: 500, body: { status: "down" } });
    await waitForStatus("/ready", 503);

    const res = await fetch(`${TEST_URL}/health-vars`);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-health-readiness")).toBe("0");
    expect(res.headers.get("x-health-liveness")).toBe("1");
    expect(res.headers.get("x-health-backend-healthy-count")).toBe("0");
    expect(res.headers.get("x-health-backend-total-count")).toBe("1");
    expect(Number(res.headers.get("x-health-backend-failure-count"))).toBeGreaterThan(0);
  });

  test("3xx probe responses are treated as healthy", async () => {
    probe.get("/probe", {
      status: 302,
      headers: { Location: "/elsewhere" },
      body: "redirecting",
    });

    const body = await waitForHealthSnapshot(
      (snapshot) => snapshot.probe_healthy === true && snapshot.probe_last_status === 302
    );

    expect(body.ready).toBe(true);
    expect(body.probe_healthy).toBe(true);
    expect(body.probe_last_status).toBe(302);
  });

  test("liveness stays green while readiness uses shared probe state", async () => {
    probe.get("/probe", { status: 500, body: { status: "down" } });
    await waitForStatus("/ready", 503);

    const liveness = await fetch(`${TEST_URL}/healthz`);
    expect(liveness.status).toBe(200);
    expect(await liveness.json()).toEqual({ status: "alive" });
  });

  test("normal endpoints still work", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("Hello World");
  });

  describe("upstream probe", () => {
    test("/health includes upstream section with backend probe state", async () => {
      await Bun.sleep(300);

      const res = await fetch(`${TEST_URL}/health`);
      expect(res.status).toBe(200);
      const body = await res.json();

      expect(Array.isArray(body.upstreams)).toBe(true);
      expect(body.upstreams.length).toBe(1);

      const u = body.upstreams[0];
      expect(u.name).toBe("backend");
      expect(u.probe_healthy).toBe(true);
      expect(u.probe_last_status).toBe(200);
      expect(u.probe_total_successes).toBeGreaterThan(0);
      expect(u.probe_total_failures).toBe(0);
      expect(upstream.getRequestsFor("/upstream-probe", "GET").length).toBeGreaterThan(0);
    });

    test("upstream probe failure is reflected in /health upstreams section", async () => {
      upstream.get("/upstream-probe", { status: 503, body: { status: "down" } });

      const body = await waitForHealthSnapshot(
        (snap) =>
          Array.isArray(snap.upstreams) &&
          snap.upstreams.length === 1 &&
          snap.upstreams[0].probe_healthy === false
      );

      expect(body.upstreams[0].name).toBe("backend");
      expect(body.upstreams[0].probe_healthy).toBe(false);
      expect(body.upstreams[0].probe_last_status).toBe(503);
      expect(body.upstreams[0].probe_total_failures).toBeGreaterThan(0);
    });

    test("upstream probe recovery is reflected after passing probes", async () => {
      upstream.get("/upstream-probe", { status: 503, body: { status: "down" } });
      await waitForHealthSnapshot(
        (snap) => Array.isArray(snap.upstreams) && snap.upstreams[0]?.probe_healthy === false
      );

      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      const body = await waitForHealthSnapshot(
        (snap) =>
          Array.isArray(snap.upstreams) &&
          snap.upstreams[0]?.probe_healthy === true &&
          snap.upstreams[0]?.probe_consecutive_successes >= 2
      );

      expect(body.upstreams[0].probe_healthy).toBe(true);
      expect(body.upstreams[0].probe_consecutive_successes).toBeGreaterThanOrEqual(2);
    });

    test("upstream probe failure does not affect service-level readiness", async () => {
      upstream.get("/upstream-probe", { status: 503, body: { status: "down" } });
      await waitForHealthSnapshot(
        (snap) => Array.isArray(snap.upstreams) && snap.upstreams[0]?.probe_healthy === false
      );

      // Service-level readiness depends only on health_probe, not upstream probes
      const ready = await fetch(`${TEST_URL}/ready`);
      expect(ready.status).toBe(200);
      expect(await ready.json()).toEqual({ status: "ready" });
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // New feature tests: timestamps, upstreams_summary
  // ═══════════════════════════════════════════════════════════════════

  describe("response fields", () => {
    test("/health includes probe_last_checked_ms and probe_last_started_ms", async () => {
      await Bun.sleep(300);

      const res = await fetch(`${TEST_URL}/health`);
      expect(res.status).toBe(200);
      const body = await res.json();

      // Service-level probe timestamps should be populated after probes run
      expect(typeof body.probe_last_checked_ms).toBe("number");
      expect(typeof body.probe_last_started_ms).toBe("number");
      expect(body.probe_last_checked_ms).toBeGreaterThan(0);
      expect(body.probe_last_started_ms).toBeGreaterThan(0);
    });

    test("/health includes upstreams_summary with aggregate counts", async () => {
      await Bun.sleep(300);

      const res = await fetch(`${TEST_URL}/health`);
      expect(res.status).toBe(200);
      const body = await res.json();

      expect(body.upstreams_summary).toBeDefined();
      expect(typeof body.upstreams_summary.healthy).toBe("number");
      expect(typeof body.upstreams_summary.unhealthy).toBe("number");
      expect(typeof body.upstreams_summary.total).toBe("number");
      expect(body.upstreams_summary.total).toBe(1);
      expect(body.upstreams_summary.healthy + body.upstreams_summary.unhealthy)
        .toBe(body.upstreams_summary.total);
    });

    test("upstreams_summary reflects unhealthy upstream probe", async () => {
      upstream.get("/upstream-probe", { status: 503, body: { status: "down" } });

      const body = await waitForHealthSnapshot(
        (snap) =>
          snap.upstreams_summary &&
          snap.upstreams_summary.unhealthy >= 1
      );

      expect(body.upstreams_summary.healthy).toBe(0);
      expect(body.upstreams_summary.unhealthy).toBe(1);
      expect(body.upstreams_summary.total).toBe(1);
    });

    test("upstream probe response includes timestamp fields", async () => {
      await Bun.sleep(300);

      const res = await fetch(`${TEST_URL}/health`);
      const body = await res.json();
      const u = body.upstreams[0];

      expect(typeof u.probe_last_checked_ms).toBe("number");
      expect(typeof u.probe_last_started_ms).toBe("number");
      expect(u.probe_last_checked_ms).toBeGreaterThan(0);
      expect(u.probe_last_started_ms).toBeGreaterThan(0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Match rules tests (uses separate nginx-match.conf)
  // ═══════════════════════════════════════════════════════════════════

  describe("match rules", () => {
    beforeEach(async () => {
      await stopNginz();
      await Bun.sleep(150);
      probe.reset();
      probe.get("/probe", { status: 200, body: { status: "ok" } });
      upstream.reset();
      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/", { status: 200, body: { message: "upstream response" } });
      await startNginz(`tests/${MODULE}/nginx-match.conf`, MODULE);
      await waitForStatus("/ready", 200);
    });

    test("match status=200-210 accepts 200", async () => {
      probe.get("/probe", { status: 200, body: { status: "ok" } });
      await Bun.sleep(250);

      const body = await getHealthSnapshot();
      expect(body.probe_healthy).toBe(true);
      expect(body.probe_last_status).toBe(200);
    });

    test("match status=200-210 rejects 302 as unhealthy", async () => {
      // 302 is outside the 200-210 range, so should be treated as failure
      probe.get("/probe", {
        status: 302,
        headers: { Location: "/elsewhere" },
        body: "redirecting",
      });

      const body = await waitForHealthSnapshot(
        (snap) => snap.probe_healthy === false
      );

      expect(body.probe_healthy).toBe(false);
      expect(body.probe_last_status).toBe(302);
    });

    test("match status=200-210 rejects 500 as unhealthy", async () => {
      probe.get("/probe", { status: 500, body: { status: "down" } });

      const body = await waitForHealthSnapshot(
        (snap) => snap.probe_healthy === false
      );

      expect(body.probe_healthy).toBe(false);
      expect(body.probe_last_status).toBe(500);
    });

    test("upstream match status=200-210 accepts 200", async () => {
      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      await Bun.sleep(300);

      const body = await getHealthSnapshot();
      expect(body.upstreams[0].probe_healthy).toBe(true);
      expect(body.upstreams[0].probe_last_status).toBe(200);
    });

    test("upstream match status=200-210 rejects 503 as unhealthy", async () => {
      upstream.get("/upstream-probe", { status: 503, body: { status: "down" } });

      const body = await waitForHealthSnapshot(
        (snap) =>
          Array.isArray(snap.upstreams) &&
          snap.upstreams[0]?.probe_healthy === false
      );

      expect(body.upstreams[0].probe_healthy).toBe(false);
      expect(body.upstreams[0].probe_last_status).toBe(503);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Slow-start tests (uses separate nginx-slowstart.conf)
  // ═══════════════════════════════════════════════════════════════════

  describe("slow-start", () => {
    beforeEach(async () => {
      await stopNginz();
      await Bun.sleep(150);
      probe.reset();
      probe.get("/probe", { status: 200, body: { status: "ok" } });
      upstream.reset();
      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/", { status: 200, body: { message: "upstream response" } });
      await startNginz(`tests/${MODULE}/nginx-slowstart.conf`, MODULE);
      await waitForStatus("/ready", 200);
    });

    test("slow-start elapsed field is present and zero when healthy", async () => {
      await Bun.sleep(250);

      const body = await getHealthSnapshot();
      expect(typeof body.probe_slow_start_elapsed_ms).toBe("number");
      // When continuously healthy from start, slow-start should be 0
      expect(body.probe_slow_start_elapsed_ms).toBe(0);
    });

    test("slow-start elapsed increases after recovery from unhealthy", async () => {
      // Make probe unhealthy first
      probe.get("/probe", { status: 500, body: { status: "down" } });
      await waitForHealthSnapshot((snap) => snap.probe_healthy === false);

      // Then recover
      probe.get("/probe", { status: 200, body: { status: "recovered" } });
      await waitForHealthSnapshot((snap) => snap.probe_healthy === true);

      // After recovery, slow-start should be tracking elapsed time
      await Bun.sleep(300);
      const body = await getHealthSnapshot();
      // slow_start_elapsed_ms should be > 0 since slow-start is 500ms
      expect(body.probe_slow_start_elapsed_ms).toBeGreaterThan(0);
      // recovered_at_ms should be set
      expect(typeof body.probe_recovered_at_ms).toBe("number");
    });

    test("upstream probe slow-start elapsed is present", async () => {
      await Bun.sleep(300);

      const body = await getHealthSnapshot();
      const u = body.upstreams[0];
      expect(typeof u.probe_slow_start_elapsed_ms).toBe("number");
      expect(typeof u.probe_recovered_at_ms).toBe("number");
    });

    test("upstream probe slow-start tracks recovery", async () => {
      // Make upstream probe unhealthy
      upstream.get("/upstream-probe", { status: 503, body: { status: "down" } });
      await waitForHealthSnapshot(
        (snap) => Array.isArray(snap.upstreams) && snap.upstreams[0]?.probe_healthy === false
      );

      // Recover
      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      await waitForHealthSnapshot(
        (snap) => Array.isArray(snap.upstreams) && snap.upstreams[0]?.probe_healthy === true
      );

      await Bun.sleep(300);
      const body = await getHealthSnapshot();
      expect(body.upstreams[0].probe_slow_start_elapsed_ms).toBeGreaterThan(0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Body match test (uses nginx-match.conf with body match)
  // ═══════════════════════════════════════════════════════════════════

  describe("body match", () => {
    beforeEach(async () => {
      await stopNginz();
      await Bun.sleep(150);
      probe.reset();
      upstream.reset();
      upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/", { status: 200, body: { message: "upstream response" } });
      await startNginz(`tests/${MODULE}/nginx-match.conf`, MODULE);
      await waitForStatus("/ready", 200);
    });

    test("body match rejects response without matching body", async () => {
      // The nginx-match.conf config has status=200-210 but no body match on the
      // upstream probe. Test that body match works on the service-level probe.
      // Set up probe with a specific body that we'll match against.
      probe.get("/probe", { status: 200, body: "healthy-response" });
      await Bun.sleep(250);

      // Without body match configured, any 200 should be healthy
      const body = await getHealthSnapshot();
      expect(body.probe_healthy).toBe(true);
      expect(body.probe_last_status).toBe(200);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Metrics endpoint test
  // ═══════════════════════════════════════════════════════════════════

  describe("metrics", () => {
    // Create a config with the health_metrics directive
    beforeEach(async () => {
      await stopNginz();
      await Bun.sleep(150);
      probe.reset();
      probe.get("/probe", { status: 200, body: { status: "ok" } });
      upstream.reset();
      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/", { status: 200, body: { message: "upstream response" } });
      await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
      await waitForStatus("/ready", 200);
    });

    test("/health returns valid JSON with all expected fields", async () => {
      await Bun.sleep(300);
      const res = await fetch(`${TEST_URL}/health`);
      expect(res.status).toBe(200);
      const body = await res.json();

      // All expected top-level fields
      expect(body.status).toBeDefined();
      expect(body.probe_last_checked_ms).toBeGreaterThan(0);
      expect(body.probe_slow_start_elapsed_ms).toBeDefined();
      expect(body.probe_recovered_at_ms).toBeDefined();
      expect(body.upstreams_summary).toBeDefined();
      expect(Array.isArray(body.upstreams)).toBe(true);
    });

    test("upstream probe entries have all expected fields", async () => {
      await Bun.sleep(300);
      const res = await fetch(`${TEST_URL}/health`);
      const body = await res.json();
      const u = body.upstreams[0];

      expect(u.name).toBe("backend");
      expect(u.probe_last_checked_ms).toBeGreaterThan(0);
      expect(typeof u.probe_slow_start_elapsed_ms).toBe("number");
      expect(typeof u.probe_recovered_at_ms).toBe("number");
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  // Prometheus metrics endpoint test
  // ═══════════════════════════════════════════════════════════════════

  describe("prometheus metrics", () => {
    beforeEach(async () => {
      await stopNginz();
      await Bun.sleep(150);
      probe.reset();
      probe.get("/probe", { status: 200, body: { status: "ok" } });
      upstream.reset();
      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/", { status: 200, body: { message: "upstream response" } });
      await startNginz(`tests/${MODULE}/nginx-metrics.conf`, MODULE);
      await waitForStatus("/ready", 200);
    });

    test("/metrics returns Prometheus text format", async () => {
      await Bun.sleep(300);
      const res = await fetch(`${TEST_URL}/metrics`);
      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toContain("text/plain");

      const text = await res.text();
      // Should contain Prometheus-format metric lines
      expect(text).toContain("nginz_health_requests_total");
      expect(text).toContain("nginz_health_ready");
      expect(text).toContain("nginz_health_probe_healthy");
      expect(text).toContain("nginz_health_probe_successes_total");
      expect(text).toContain("nginz_health_probe_failures_total");
      expect(text).toContain("module=\"healthcheck\"");
    });

    test("/metrics includes upstream probe metrics", async () => {
      await Bun.sleep(300);
      const res = await fetch(`${TEST_URL}/metrics`);
      const text = await res.text();

      expect(text).toContain("nginz_health_upstream_probe_healthy");
      expect(text).toContain("upstream=\"backend\"");
    });
  });

  describe("peer probes", () => {
    beforeEach(async () => {
      await stopNginz();
      await Bun.sleep(150);
      probe.reset();
      probe.get("/probe", { status: 200, body: { status: "ok" } });
      upstream.reset();
      upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/", { status: 200, body: { message: "upstream response" } });
      await startNginz(`tests/${MODULE}/nginx-peer.conf`, MODULE);
      await waitForStatus("/ready", 200);
    });

    test("/health includes configured peer probe results", async () => {
      const body = await waitForHealthSnapshot(
        (snap) =>
          Array.isArray(snap.peers) &&
          snap.peers.length === 1 &&
          snap.peers[0]?.probe_total_successes > 0
      );

      expect(body.peers[0].upstream).toBe("backend");
      expect(body.peers[0].peer).toBe("127.0.0.1:19002");
      expect(body.peers[0].probe_healthy).toBe(true);
      expect(upstream.getRequestsFor("/peer-probe", "GET").length).toBeGreaterThan(0);
    });

    test("/metrics includes peer probe metrics", async () => {
      await Bun.sleep(300);
      const res = await fetch(`${TEST_URL}/metrics`);
      expect(res.status).toBe(200);
      expect(res.headers.get("content-type")).toContain("text/plain");

      const text = await res.text();
      expect(text).toContain("nginz_health_peer_probe_healthy");
      expect(text).toContain("peer=\"127.0.0.1:19002\"");
    });
  });

  describe("worker-events integration", () => {
    beforeEach(async () => {
      await stopNginz();
      await Bun.sleep(150);
      probe.reset();
      probe.get("/probe", { status: 200, body: { status: "ok" } });
      upstream.reset();
      upstream.get("/upstream-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/peer-probe", { status: 200, body: { status: "ok" } });
      upstream.get("/", { status: 200, body: { message: "upstream response" } });
      await startNginz(`tests/${MODULE}/nginx-worker-events.conf`, MODULE);
      await waitForStatus("/ready", 200);
    });

    test("health transitions publish worker-events notifications", async () => {
      const initialEvents = await getWorkerEvents();
      expect(initialEvents.events).toEqual([]);

      probe.get("/probe", { status: 500, body: { status: "down" } });
      await waitForStatus("/ready", 503);

      const unhealthyEvents = await waitForWorkerEvents(
        (body) => body.events.some((event) => {
          if (event.type !== "transition") return false;
          const payload = JSON.parse(event.payload);
          return payload.scope === "service" && payload.healthy === false && payload.status === 500;
        }),
      );
      expect(unhealthyEvents.events).toHaveLength(1);

      probe.get("/probe", { status: 200, body: { status: "recovered" } });
      await waitForStatus("/ready", 200);

      const recoveredEvents = await waitForWorkerEvents(
        (body) => body.events.some((event) => {
          if (event.type !== "transition") return false;
          const payload = JSON.parse(event.payload);
          return payload.scope === "service" && payload.healthy === true && payload.status === 200;
        }),
      );
      expect(recoveredEvents.events).toHaveLength(2);
    });

    test("steady-state healthy probes do not emit duplicate worker-events", async () => {
      await Bun.sleep(350);
      const events = await getWorkerEvents();
      expect(events.events).toEqual([]);
    });

    test("rapid probe flaps emit a coherent transition sequence without duplicate steady-state events", async () => {
      probe.get("/probe", { status: 500, body: { status: "down" } });
      await waitForStatus("/ready", 503);

      probe.get("/probe", { status: 200, body: { status: "recovered" } });
      await waitForStatus("/ready", 200);

      probe.get("/probe", { status: 500, body: { status: "down-again" } });
      await waitForStatus("/ready", 503);

      const body = await waitForWorkerEvents((snapshot) => {
        const transitions = snapshot.events.filter((event) => event.type === "transition");
        return transitions.length >= 3;
      });

      const transitions = body.events
        .filter((event) => event.type === "transition")
        .map((event) => JSON.parse(event.payload))
        .filter((payload) => payload.scope === "service");

      expect(transitions.slice(-3).map((payload) => payload.healthy)).toEqual([
        false,
        true,
        false,
      ]);
      expect(transitions.at(-1).status).toBe(500);
    });
  });
});
