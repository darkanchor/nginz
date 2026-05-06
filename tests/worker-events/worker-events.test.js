import { spawnSync } from "bun";
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "worker-events";

function createConfigTestRuntime(name) {
  const runtimeDir = join(process.cwd(), "tests", MODULE, `runtime-${name}`);
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
  mkdirSync(join(runtimeDir, "logs"), { recursive: true });
  return runtimeDir;
}

function cleanupConfigTestRuntime(name) {
  const runtimeDir = join(process.cwd(), "tests", MODULE, `runtime-${name}`);
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
}

function expectConfigTestFailure(configName, expectedMessage) {
  const runtimeName = `config-${configName.replace(/[^a-z0-9]/gi, "-")}`;
  const runtimeDir = createConfigTestRuntime(runtimeName);

  try {
    const result = spawnSync({
      cmd: [
        "./zig-out/bin/nginz",
        "-t",
        "-c",
        join(process.cwd(), "tests", MODULE, configName),
        "-p",
        runtimeDir,
      ],
      cwd: process.cwd(),
      stdout: "pipe",
      stderr: "pipe",
    });

    const stderr = new TextDecoder().decode(result.stderr ?? new Uint8Array());
    const stdout = new TextDecoder().decode(result.stdout ?? new Uint8Array());
    const output = `${stdout}\n${stderr}`;
    expect(output).toContain("test failed");
    expect(output).toContain(expectedMessage);
  } finally {
    cleanupConfigTestRuntime(runtimeName);
  }
}

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
    expect(body.channel).toBe("cache.invalidate");
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

  test("POST rejects non-JSON content-type", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "text/plain" },
      body: JSON.stringify({ type: "wrong_media_type" }),
    });

    expect(res.status).toBe(415);
    const body = await res.json();
    expect(body.status).toBe("error");
    expect(body.error).toBe("content-type must be application/json");
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
    expect(body.channel).toBe("cache.invalidate");
  });

  test("inspect with non-matching channel returns empty", async () => {
    const res = await fetch(`${TEST_URL}/worker-events?channel=nonexistent`);
    const body = await res.json();
    expect(body.channel).toBe("nonexistent");
    expect(body.events).toEqual([]);
  });

  test("event types are JSON-escaped in inspect output", async () => {
    const specialType = 'quote"slash\\newline\n';
    const res = await fetch(`${TEST_URL}/worker-events`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: specialType, payload: "ok" }),
    });
    expect(res.status).toBe(200);

    const inspect = await fetch(`${TEST_URL}/worker-events`);
    expect(inspect.status).toBe(200);
    const body = await inspect.json();
    expect(body.events.some((e) => e.type === specialType)).toBe(true);
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

  test("small ring publish and inspect works as an independent zone", async () => {
    const res = await fetch(`${TEST_URL}/small-ring`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "small_event", payload: "small" }),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("published");
    expect(body.generation).toBe(1);

    const inspect = await fetch(`${TEST_URL}/small-ring`);
    expect(inspect.status).toBe(200);
    const state = await inspect.json();
    expect(state.zone).toBe("small");
    expect(state.channel).toBe("test");
    expect(state.events).toHaveLength(1);
    expect(state.events[0].type).toBe("small_event");
  });
});

describe("worker-events Phase 1 - config load validation", () => {
  test("worker_events_api requires worker_events_zone", () => {
    expectConfigTestFailure(
      "nginx-missing-zone.conf",
      "worker_events_api requires worker_events_zone",
    );
  });

  test("worker_events_api requires worker_events_channel", () => {
    expectConfigTestFailure(
      "nginx-missing-channel.conf",
      "worker_events_api requires worker_events_channel",
    );
  });

  test("shared zones reject conflicting ring sizes at config load", () => {
    expectConfigTestFailure(
      "nginx-zone-size-conflict.conf",
      'conflicts with already declared size',
    );
  });
});

describe("worker-events Phase 1 - multi-zone isolation", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-multizone.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("separate zones keep separate generation counters and events", async () => {
    const aPub = await fetch(`${TEST_URL}/zone-a`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "a1", payload: "from-a" }),
    });
    const aBody = await aPub.json();
    expect(aPub.status).toBe(200);
    expect(aBody.generation).toBe(1);

    const bPub = await fetch(`${TEST_URL}/zone-b`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ type: "b1", payload: "from-b" }),
    });
    const bBody = await bPub.json();
    expect(bPub.status).toBe(200);
    expect(bBody.generation).toBe(1);

    const aInspect = await fetch(`${TEST_URL}/zone-a`);
    const aState = await aInspect.json();
    expect(aState.zone).toBe("zone_a");
    expect(aState.channel).toBe("shared");
    expect(aState.capacity).toBe(4);
    expect(aState.events).toHaveLength(1);
    expect(aState.events[0].type).toBe("a1");

    const bInspect = await fetch(`${TEST_URL}/zone-b`);
    const bState = await bInspect.json();
    expect(bState.zone).toBe("zone_b");
    expect(bState.channel).toBe("shared");
    expect(bState.capacity).toBe(16);
    expect(bState.events).toHaveLength(1);
    expect(bState.events[0].type).toBe("b1");
  });
});
