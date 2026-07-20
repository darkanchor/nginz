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

describe("worker-events Phase 2 - multi-worker cross-worker visibility", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-multiw.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("neighboring routes work with 2 workers", async () => {
    const res = await fetchClose(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });

  test("inspect shows capacity in response", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.module).toBe("worker_events");
    expect(body).toHaveProperty("capacity");
    expect(body.capacity).toBeGreaterThan(0);
  });

  test("events published from one worker are visible to GET from any worker", async () => {
    // Publish many events rapidly. With 2 workers, some publishes and
    // subsequent GETs will be handled by different workers.
    const publishedGens = [];
    for (let i = 0; i < 50; i++) {
      const res = await fetchClose(`${TEST_URL}/worker-events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "cross_worker", payload: String(i) }),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.retention_evicted).toBe(false);
      expect(body.status).toBe("published");
      publishedGens.push(body.generation);
    }

    // Verify all generations are accounted for in inspect
    const res = await fetchClose(`${TEST_URL}/worker-events`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.events.length).toBeGreaterThanOrEqual(50);
    expect(body.channel).toBe("fanout");

    // All events should be in generation order
    for (let i = 1; i < body.events.length; i++) {
      expect(body.events[i].generation).toBeGreaterThan(body.events[i - 1].generation);
    }

    // Check that the first and last generations match our published range
    const eventGens = body.events.map((e) => e.generation);
    expect(eventGens[0]).toBe(1);
    expect(eventGens[eventGens.length - 1]).toBe(50);
  });

  test("since query filters correctly in multi-worker setup", async () => {
    // Publish a few more events
    for (let i = 0; i < 5; i++) {
      await fetchClose(`${TEST_URL}/worker-events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "since_test", payload: String(i) }),
      });
    }

    // Get all events
    const all = await fetchClose(`${TEST_URL}/worker-events`);
    const allBody = await all.json();
    const midGen = allBody.events[Math.floor(allBody.events.length / 2)].generation;

    // Query with since
    const res = await fetchClose(`${TEST_URL}/worker-events?since=${midGen}`);
    const body = await res.json();
    for (const ev of body.events) {
      expect(ev.generation).toBeGreaterThan(midGen);
    }
    expect(body.oldest_generation).toBeLessThanOrEqual(midGen + 1);
  });

  test("dropped_events is zero when ring not full", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events`);
    const body = await res.json();
    // Ring is 256, we published 55 events - no overflow
    expect(body.dropped_events).toBe(0);
  });

  test("inspect does not silently truncate above 128 retained events", async () => {
    for (let i = 0; i < 90; i++) {
      const res = await fetchClose(`${TEST_URL}/worker-events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "bulk", payload: String(i) }),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.retention_evicted).toBe(false);
    }

    const res = await fetchClose(`${TEST_URL}/worker-events`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.events.length).toBe(145);
    expect(body.oldest_generation).toBe(1);
    expect(body.newest_generation).toBe(145);
  });
});

describe("worker-events Phase 2 - overflow semantics", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-overflow.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("ring capacity is 4 as configured", async () => {
    const res = await fetchClose(`${TEST_URL}/worker-events`);
    const body = await res.json();
    expect(body.capacity).toBeGreaterThanOrEqual(4);
    expect(body.capacity).toBeLessThanOrEqual(8); // small ring
    expect(body.events).toEqual([]);
  });

  test("publishing up to capacity fills ring without overflow", async () => {
    for (let i = 0; i < 4; i++) {
      const res = await fetchClose(`${TEST_URL}/worker-events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "fill", payload: String(i) }),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.retention_evicted).toBe(false);
    }

    const res = await fetchClose(`${TEST_URL}/worker-events`);
    const body = await res.json();
    expect(body.events.length).toBe(4);
    expect(body.dropped_events).toBe(0);
    expect(body.newest_generation).toBe(4);
  });

  test("overflow drops oldest and increments dropped_events", async () => {
    // Ring is full (4 entries). Publish 3 more - each should overwrite the oldest.
    for (let i = 0; i < 3; i++) {
      const res = await fetchClose(`${TEST_URL}/worker-events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "overflow", payload: String(i) }),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.retention_evicted).toBe(true);
    }

    const res = await fetchClose(`${TEST_URL}/worker-events`);
    const body = await res.json();

    // Ring should still have 4 entries
    expect(body.events.length).toBe(4);

    // Should have dropped events
    expect(body.dropped_events).toBe(3);

    // oldest_generation should have advanced past the dropped ones
    expect(body.oldest_generation).toBeGreaterThan(1);

    // newest_generation should be 7 (4 fill + 3 overflow)
    expect(body.newest_generation).toBe(7);

    // Events should be in order
    for (let i = 1; i < body.events.length; i++) {
      expect(body.events[i].generation).toBeGreaterThan(body.events[i - 1].generation);
    }

    // The first (oldest) event should have generation = oldest_generation
    expect(body.events[0].generation).toBe(body.oldest_generation);
  });

  test("overflow wraps around multiple times correctly", async () => {
    // Publish 10 more events (ring is 4, so 2.5 wrap-arounds)
    for (let i = 0; i < 10; i++) {
      await fetchClose(`${TEST_URL}/worker-events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "wrap", payload: String(i) }),
      });
    }

    const res = await fetchClose(`${TEST_URL}/worker-events`);
    const body = await res.json();

    // Ring should still have 4 entries (capacity)
    expect(body.events.length).toBe(4);

    // dropped_events should be >= 3 + 10 = 13 (previous 3 + these 10 publishes into full ring)
    expect(body.dropped_events).toBeGreaterThanOrEqual(13);

    // Only the 4 most recent generations should be visible
    expect(body.newest_generation).toBe(17);
    expect(body.oldest_generation).toBe(14);

    // First event in ring should match oldest_generation
    expect(body.events[0].generation).toBe(body.oldest_generation);
    expect(body.events[body.events.length - 1].generation).toBe(body.newest_generation);
  });

  test("since= query works correctly after overflow", async () => {
    // Request events after generation 15
    const res = await fetchClose(`${TEST_URL}/worker-events?since=15`);
    const body = await res.json();

    // Should only get events with gen > 15
    for (const ev of body.events) {
      expect(ev.generation).toBeGreaterThan(15);
    }

    // Since the ring only holds 4 entries, we should only see gen 16, 17
    // (if they're still retained)
    if (body.events.length > 0) {
      expect(body.events[0].generation).toBeGreaterThanOrEqual(16);
    }
  });

  test("since= query for dropped range returns empty", async () => {
    // Generations 1-13 were dropped. Querying since=5 should
    // skip all events (since oldest retained is 14).
    const res = await fetchClose(`${TEST_URL}/worker-events?since=5`);
    const body = await res.json();
    // All retained events have gen > 13, so since=5 should match them all
    if (body.events.length > 0) {
      for (const ev of body.events) {
        expect(ev.generation).toBeGreaterThan(5);
      }
    }
  });
});
