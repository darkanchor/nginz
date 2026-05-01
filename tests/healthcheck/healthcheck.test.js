import { describe, test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  createMockManager,
  MOCK_PORTS,
} from "../harness.js";

const MODULE = "healthcheck";

let mocks;
let probe;

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

describe("healthcheck module", () => {
  beforeAll(async () => {
    mocks = createMockManager();
    probe = mocks.add("probe", createHTTPMock(MOCK_PORTS.HTTP));
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
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
    await waitForStatus("/ready", 200);
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

    await Promise.all(
      Array.from({ length: successCount }, () => fetch(`${TEST_URL}/`))
    );

    await Promise.all(
      Array.from({ length: failureCount }, () => fetch(`${TEST_URL}/fail`))
    );

    const res = await fetch(`${TEST_URL}/health`);
    expect(res.status).toBe(200);
    const body = await res.json();

    expect(body.requests).toBeGreaterThanOrEqual(successCount + failureCount);
    expect(body.failed).toBeGreaterThanOrEqual(failureCount);
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
});
