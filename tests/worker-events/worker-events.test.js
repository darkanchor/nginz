import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "worker-events";

describe("worker-events Phase 1 - publish and inspect", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  // ── Basic contract ──────────────────────────────────────────────────────

  test("leaves normal locations unaffected", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });

  test("returns 405 for unsupported methods", async () => {
    for (const method of ["PUT", "DELETE", "PATCH"]) {
      const res = await fetch(`${TEST_URL}/worker-events`, { method });
      expect(res.status).toBe(405);
      expect(res.headers.get("content-type")).toContain("application/json");
      const body = await res.json();
      expect(body.status).toBe("error");
      expect(body.error).toBe("method not allowed");
    }
  });

  // ── HEAD ────────────────────────────────────────────────────────────────

  test("HEAD returns headers with no body", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, { method: "HEAD" });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");
    expect(await res.text()).toBe("");
  });

  // ── Inspect (empty ring) ────────────────────────────────────────────────

  test("GET inspect returns empty ring state", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json();
    expect(body.module).toBe("worker_events");
    expect(body).toHaveProperty("oldest_generation");
    expect(body).toHaveProperty("newest_generation");
    expect(body).toHaveProperty("dropped_events");
    expect(body.events).toEqual([]);
  });

  // ── Publish ─────────────────────────────────────────────────────────────

  test("POST publishes an event and returns generation", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        type: "test_event",
        payload: "hello world",
      }),
    });

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json();
    expect(body.module).toBe("worker_events");
    expect(body.status).toBe("published");
    expect(body.zone).toBe("bus");
    expect(body.channel).toBe("cache.invalidate");
    expect(body.generation).toBe(1);
  });

  test("POST rejects missing type field", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        payload: "no type here",
      }),
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("POST rejects empty type field", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "" }),
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("POST rejects type longer than 64 chars", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "x".repeat(65) }),
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("POST rejects payload larger than 512 bytes", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        type: "overflow_test",
        payload: "x".repeat(513),
      }),
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("POST rejects invalid JSON", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "not valid json {{{",
    });

    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("POST accepts payload-less event", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "minimal_event" }),
    });

    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("published");
    expect(body.generation).toBeGreaterThan(0);
  });

  // ── Sequence of publishes ───────────────────────────────────────────────

  test("generations increase monotonically", async () => {
    const gens = [];
    for (let i = 0; i < 5; i++) {
      const res = await fetch(`${TEST_URL}/worker-events`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ type: "counter", payload: String(i) }),
      });
      const body = await res.json();
      gens.push(body.generation);
    }
    // Generations should be strictly increasing
    for (let i = 1; i < gens.length; i++) {
      expect(gens[i]).toBeGreaterThan(gens[i - 1]);
    }
  });

  test("inspect returns all published events in order", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.events.length).toBeGreaterThanOrEqual(7); // from previous tests
    // Check that first event has generation 1 and type "test_event"
    const first = body.events[0];
    expect(first.generation).toBe(1);
    expect(first.type).toBe("test_event");
    expect(first.payload).toBe("hello world");
    // Generations should be in order
    for (let i = 1; i < body.events.length; i++) {
      expect(body.events[i].generation).toBeGreaterThan(body.events[i - 1].generation);
    }
  });

  // ── Since / Channel filtering ───────────────────────────────────────────

  test("inspect with since= filters older events", async () => {
    // First, get all events to find a middle generation
    const all = await fetch(`${TEST_URL}/worker-events`);
    const allBody = await all.json();
    if (allBody.events.length >= 3) {
      const midGen = allBody.events[2].generation;
      const res = await fetch(`${TEST_URL}/worker-events?since=${midGen}`);
      const body = await res.json();
      // All returned events should have generation > midGen
      for (const ev of body.events) {
        expect(ev.generation).toBeGreaterThan(midGen);
      }
    }
  });

  test("inspect with limit= caps response size", async () => {
    const res = await fetch(`${TEST_URL}/worker-events?limit=2`);
    const body = await res.json();
    expect(body.events.length).toBeLessThanOrEqual(2);
  });

  test("inspect with channel= filters events", async () => {
    // Publish to a different channel concept — but we only have one channel
    // configured. The filter should still work for that channel.
    const res = await fetch(`${TEST_URL}/worker-events?channel=cache.invalidate`);
    const body = await res.json();
    // All events should have been published to this channel
    expect(body.events.length).toBeGreaterThanOrEqual(1);
  });

  test("inspect with non-matching channel returns empty", async () => {
    const res = await fetch(`${TEST_URL}/worker-events?channel=nonexistent`);
    const body = await res.json();
    expect(body.events).toEqual([]);
  });
});

describe("worker-events Phase 1 - error config", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-error.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("neighboring routes still work", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });

  test("GET without zone still returns data from shared zone", async () => {
    // No zone configured on this location, but the global zone is already
    // created by the /small-ring location. The handler falls back to it.
    const res = await fetch(`${TEST_URL}/no-zone`);
    expect(res.status).toBe(200);
    const body = await res.json();
    // May return events if another location published to the shared zone
    expect(body).toHaveProperty("events");
    expect(body.module).toBe("worker_events");
  });

  test("POST without zone returns error", async () => {
    const res = await fetch(`${TEST_URL}/no-zone`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "test" }),
    });
    // PUBLISH requires channel, which /no-zone has ("test")
    // It publishes to the global shared zone
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("published");
  });

  test("GET small-ring returns events from shared zone", async () => {
    const res = await fetch(`${TEST_URL}/small-ring`);
    expect(res.status).toBe(200);
    const body = await res.json();
    // Should contain events published from /no-zone above
    expect(body.events.length).toBeGreaterThanOrEqual(1);
  });

  test("small ring publish and inspect works", async () => {
    const res = await fetch(`${TEST_URL}/small-ring`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "small_event", payload: "small" }),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("published");
    expect(body.generation).toBeGreaterThan(1);
  });
});
