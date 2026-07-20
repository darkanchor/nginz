import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "worker-events";


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("worker-events Phase 3 - publish authorization", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-phase3.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("neighboring routes work", async () => {
    const res = await fetchClose(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });

  test("inspect (GET) does not require auth", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.module).toBe("worker_events");
  });

  test("publish without key returns 401", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "no_auth" }),
    });
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.status).toBe("error");
    expect(body.error).toContain("unauthorized");
  });

  test("publish with wrong key returns 401", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events?key=wrongkey`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "bad_key" }),
    });
    expect(res.status).toBe(401);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("publish with correct key succeeds", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events?key=secret123`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "authorized", payload: "ok" }),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("published");
    expect(body.generation).toBe(1);
  });

  test("published event is visible via inspect", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events`);
    const body = await res.json();
    expect(body.events.length).toBeGreaterThanOrEqual(1);
    expect(body.events[0].type).toBe("authorized");
    expect(body.last_publish_msec).toBeGreaterThan(0);
  });

  test("key comparison is exact (substring fails)", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events?key=secret1234`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "long_key" }),
    });
    expect(res.status).toBe(401);
  });
});

describe("worker-events Phase 3 - introspection fields", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-phase3.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("inspect returns all observable fields", async () => {
    // Publish first
    await fetchClose(`${TEST_URL}/worker-events?key=secret123`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "obs", payload: "test" }),
    });

    const res = await fetchClose(`${TEST_URL}/worker-events`);
    const body = await res.json();

    // Verify all expected fields are present
    expect(body).toHaveProperty("module");
    expect(body).toHaveProperty("zone");
    expect(body).toHaveProperty("capacity");
    expect(body).toHaveProperty("oldest_generation");
    expect(body).toHaveProperty("newest_generation");
    expect(body).toHaveProperty("dropped_events");
    expect(body).toHaveProperty("last_publish_msec");
    expect(body).toHaveProperty("events");

    // Verify fields have reasonable values
    expect(body.oldest_generation).toBeGreaterThan(0);
    expect(body.newest_generation).toBeGreaterThan(0);
    expect(body.dropped_events).toBe(0);
    expect(body.last_publish_msec).toBeGreaterThan(0);
    expect(Array.isArray(body.events)).toBe(true);
  });

  test("last_publish_msec updates after each publish", async () => {
    const before = await fetchClose(`${TEST_URL}/worker-events`);
    const beforeBody = await before.json();
    const beforeTime = beforeBody.last_publish_msec;

    // Small delay
    await Bun.sleep(10);

    await fetchClose(`${TEST_URL}/worker-events?key=secret123`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "time_test" }),
    });

    const after = await fetchClose(`${TEST_URL}/worker-events`);
    const afterBody = await after.json();

    expect(afterBody.last_publish_msec).toBeGreaterThanOrEqual(beforeTime);
  });
});
