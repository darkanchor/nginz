import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { existsSync, rmSync, writeFileSync } from "fs";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  createConsulMock,
  MOCK_PORTS,
} from "../harness.js";

const MODULE = "dynamic-upstreams";
const REFRESH_SOURCE_FILE = "/tmp/nginz-dynamic-upstreams-source.json";
const CONSUL_LIVENESS_SOURCE_FILE = "/tmp/nginz-dynamic-upstreams-consul-liveness.json";

async function getWorkerEvents(channel = "upstreams", since = null) {
  const params = new URLSearchParams({ channel });
  if (since != null) {
    params.set("since", String(since));
  }
  const res = await fetch(`${TEST_URL}/worker-events?${params.toString()}`);
  expect(res.status).toBe(200);
  return res.json();
}

async function waitForWorkerEvents(predicate, channel = "upstreams", timeout = 4000, since = null) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const body = await getWorkerEvents(channel, since);
    if (predicate(body)) {
      return body;
    }
    await Bun.sleep(75);
  }
  throw new Error(`Timed out waiting for worker-events on channel ${channel}`);
}

async function waitForDynamicState(predicate, timeout = 4000) {
  return waitForDynamicRouteState("/dynamic-upstreams", predicate, timeout);
}

async function waitForDynamicRouteState(route, predicate, timeout = 4000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const res = await fetch(`${TEST_URL}${route}`);
    expect(res.status).toBe(200);
    const body = await res.json();
    if (predicate(body)) {
      return body;
    }
    await Bun.sleep(75);
  }
  throw new Error("Timed out waiting for dynamic-upstreams state");
}

describe("dynamic-upstreams Phase 1 — read-only introspection", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("GET returns real JSON for static upstream peers", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json();
    expect(body.module).toBe("dynamic_upstreams");
    expect(body.target).toBe("api_backend");
    expect(body.source).toBe("static");
    expect(typeof body.generation).toBe("number");
    expect(typeof body.peer_count).toBe("number");
    expect(body.peer_count).toBeGreaterThanOrEqual(1);
    expect(Array.isArray(body.peers)).toBe(true);
    expect(body.peers.length).toBe(body.peer_count);
    expect(body.peers[0]).toHaveProperty("address");
    expect(body.peers[0]).toHaveProperty("weight");
    expect(body.writable).toBe(true);
    expect(body.generation).toBe(0); // no PUT yet
  });

  test("HEAD returns consistent headers without body", async () => {
    const get_res = await fetch(`${TEST_URL}/dynamic-upstreams`);
    const head_res = await fetch(`${TEST_URL}/dynamic-upstreams`, { method: "HEAD" });
    expect(head_res.status).toBe(200);
    expect(head_res.headers.get("content-type")).toContain("application/json");
    expect(await head_res.text()).toBe("");
    expect(head_res.headers.get("content-length")).toBe(
      get_res.headers.get("content-length")
    );
  });

  test("unsupported methods return 405", async () => {
    const post_res = await fetch(`${TEST_URL}/dynamic-upstreams`, { method: "POST", body: "{}" });
    expect(post_res.status).toBe(405);
    const delete_res = await fetch(`${TEST_URL}/dynamic-upstreams`, { method: "DELETE" });
    expect(delete_res.status).toBe(405);
  });

  test("keeps neighboring routes working normally", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});

describe("dynamic-upstreams Phase 2 — snapshot replacement", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("PUT activates a new peer snapshot", async () => {
    const payload = {
      peers: [
        { address: "127.0.0.1:19002", weight: 2 },
        { address: "127.0.0.1:19003", weight: 1 },
      ],
    };
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
    expect(body.generation).toBe(1);
    expect(body.peer_count).toBe(2);
  });

  test("GET returns active snapshot after PUT", async () => {
    const put_payload = { peers: [{ address: "127.0.0.1:19004", weight: 1 }] };
    await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(put_payload),
    });

    const get_res = await fetch(`${TEST_URL}/dynamic-upstreams`);
    expect(get_res.status).toBe(200);
    const body = await get_res.json();
    expect(body.generation).toBeGreaterThan(0);
    expect(body.peers.length).toBe(1);
    expect(body.peers[0].address).toBe("127.0.0.1:19004");
  });

  test("PUT with invalid JSON returns 400 and preserves snapshot", async () => {
    // First set a known state
    await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ peers: [{ address: "127.0.0.1:19002", weight: 1 }] }),
    });
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();

    // Try invalid JSON
    const bad_res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: "not json",
    });
    expect(bad_res.status).toBe(400);

    // Snapshot unchanged
    const after = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(after.generation).toBe(before.generation);
    expect(after.peer_count).toBe(before.peer_count);
  });

  test("PUT with empty peers array returns 400", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ peers: [] }),
    });
    expect(res.status).toBe(400);
  });

  test("PUT with hostname address (not IP) returns 400", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ peers: [{ address: "localhost:8080" }] }),
    });
    expect(res.status).toBe(400);
  });

  test("PUT with duplicate peer addresses returns 400", async () => {
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();

    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 1 },
          { address: "127.0.0.1:19002", weight: 2 },
        ],
      }),
    });
    expect(res.status).toBe(400);

    const after = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(after.generation).toBe(before.generation);
    expect(after.peer_count).toBe(before.peer_count);
  });
});

describe("dynamic-upstreams Phase 3 — operational fields and worker-events fanout", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-phase3.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("GET exposes operational timestamp/error fields", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.last_error_code).toBe(0);
    expect(body.last_error_at_msec).toBe(0);
    expect(body.last_success_at_msec).toBe(0);
  });

  test("PUT without application/json content-type returns 415 and records last error", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      body: JSON.stringify({ peers: [{ address: "127.0.0.1:19002" }] }),
    });
    expect(res.status).toBe(415);

    const body = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(body.last_error_code).toBe(415);
    expect(body.last_error_at_msec).toBeGreaterThan(0);
    expect(body.last_success_at_msec).toBe(0);
  });

  test("successful PUT updates success metadata and emits worker-events notification across workers", async () => {
    const before = await getWorkerEvents();

    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 2 },
          { address: "127.0.0.1:19003", weight: 1 },
        ],
      }),
    });
    expect(res.status).toBe(200);
    const putBody = await res.json();
    expect(putBody.status).toBe("ok");

    const state = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(state.generation).toBeGreaterThan(0);
    expect(state.peer_count).toBe(2);
    expect(state.last_error_code).toBe(0);
    expect(state.last_success_at_msec).toBeGreaterThan(0);

    const events = await waitForWorkerEvents(
      (snapshot) => snapshot.events.length === 1,
      "upstreams",
      4000,
      before.newest_generation,
    );
    expect(events.events[0].type).toBe("snapshot_activated");
    const payload = JSON.parse(events.events[0].payload);
    expect(payload).toEqual({
      target: "api_backend",
      source: "static",
      generation: state.generation,
      peer_count: 2,
    });
  });

  test("invalid JSON records last failure without replacing the active snapshot", async () => {
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();

    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: "{not-json",
    });
    expect(res.status).toBe(400);

    const after = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(after.generation).toBe(before.generation);
    expect(after.peer_count).toBe(before.peer_count);
    expect(after.last_error_code).toBe(4001);
    expect(after.last_error_at_msec).toBeGreaterThanOrEqual(after.last_success_at_msec);
  });
});

describe("dynamic-upstreams Phase 3 — static source polling", () => {
  beforeAll(async () => {
    writeFileSync(
      REFRESH_SOURCE_FILE,
      JSON.stringify({ peers: [{ address: "127.0.0.1:19002", weight: 1 }] }),
    );
    await startNginz(`tests/${MODULE}/nginx-refresh.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    if (existsSync(REFRESH_SOURCE_FILE)) {
      rmSync(REFRESH_SOURCE_FILE);
    }
  });

  test("timer-driven refresh activates the file snapshot and does not churn unchanged generations", async () => {
    const state = await waitForDynamicState((body) => body.generation > 0);
    expect(state.peers).toHaveLength(1);
    expect(state.peers[0].address).toBe("127.0.0.1:19002");
    expect(state.last_success_at_msec).toBeGreaterThan(0);

    await Bun.sleep(400);
    const after = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(after.generation).toBe(state.generation);
    expect(after.peers[0].address).toBe("127.0.0.1:19002");
  });

  test("changing the source file activates a new generation and emits a worker-events notification", async () => {
    const beforeState = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    const beforeEvents = await getWorkerEvents();

    writeFileSync(
      REFRESH_SOURCE_FILE,
      JSON.stringify({
        peers: [
          { address: "127.0.0.1:19003", weight: 2 },
          { address: "127.0.0.1:19002", weight: 1 },
        ],
      }),
    );

    const state = await waitForDynamicState((body) => body.generation > beforeState.generation);
    expect(state.peers).toHaveLength(2);
    expect(state.peers[0].address).toBe("127.0.0.1:19003");

    const events = await waitForWorkerEvents(
      (snapshot) => snapshot.events.length >= 1,
      "upstreams",
      4000,
      beforeEvents.newest_generation,
    );
    const payload = JSON.parse(events.events[0].payload);
    expect(payload).toEqual({
      target: "api_backend",
      source: "static",
      generation: state.generation,
      peer_count: 2,
    });
  });

  test("invalid source JSON preserves the last good snapshot and records the refresh error", async () => {
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    writeFileSync(REFRESH_SOURCE_FILE, "{bad-json");

    const after = await waitForDynamicState(
      (body) =>
        body.last_error_code === 4001 &&
        body.generation === before.generation,
      4000,
    );
    expect(after.peer_count).toBe(before.peer_count);
    expect(after.peers).toEqual(before.peers);
  });

  test("invalid source file emits refresh_failed event with error_code", async () => {
    const beforeEvents = await getWorkerEvents();
    writeFileSync(REFRESH_SOURCE_FILE, "{bad-json");

    const events = await waitForWorkerEvents(
      (snapshot) => snapshot.events.some((e) => e.type === "refresh_failed"),
      "upstreams",
      4000,
      beforeEvents.newest_generation,
    );
    const ev = events.events.find((e) => e.type === "refresh_failed");
    const payload = JSON.parse(ev.payload);
    expect(payload.target).toBe("api_backend");
    expect(payload.source).toBe("static");
    expect(typeof payload.error_code).toBe("number");
    expect(payload.error_code).toBeGreaterThan(0);
  });
});

describe("dynamic-upstreams Phase 3 — health-aware activation", () => {
  let backend1;
  let backend2;

  beforeAll(async () => {
    backend1 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1);
    backend1.get("/probe", { status: 200, body: { status: "ok" } });
    backend1.setDefault({ status: 200, body: { server: "backend1" } });

    backend2 = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_2);
    backend2.get("/probe", { status: 500, body: { status: "fail" } });
    backend2.setDefault({ status: 200, body: { server: "backend2" } });

    await startNginz(`tests/${MODULE}/nginx-health-aware.conf`, MODULE);
    await Bun.sleep(400);
  });

  afterAll(async () => {
    await stopNginz();
    backend1.stop();
    backend2.stop();
    cleanupRuntime(MODULE);
  });

  test("PUT activates only the currently healthy subset", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 1 },
          { address: "127.0.0.1:19003", weight: 1 },
        ],
      }),
    });
    expect(res.status).toBe(200);

    const body = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(body.peer_count).toBe(1);
    expect(body.peers).toEqual([{ address: "127.0.0.1:19002", weight: 1 }]);
    expect(body.last_error_code).toBe(0);
  });

  test("recovered peer is re-included on the next full activation", async () => {
    backend2.get("/probe", { status: 200, body: { status: "ok" } });
    await Bun.sleep(500);

    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 1 },
          { address: "127.0.0.1:19003", weight: 1 },
        ],
      }),
    });
    expect(res.status).toBe(200);

    const body = await waitForDynamicState((state) => state.peer_count === 2, 2000);
    expect(body.peers).toEqual([
      { address: "127.0.0.1:19002", weight: 1 },
      { address: "127.0.0.1:19003", weight: 1 },
    ]);
  });
});

describe("dynamic-upstreams Phase 3 — consul source", () => {
  let consulMock;

  beforeAll(async () => {
    writeFileSync(
      CONSUL_LIVENESS_SOURCE_FILE,
      JSON.stringify({ peers: [{ address: "127.0.0.1:19002", weight: 1 }] }),
    );
    consulMock = createConsulMock(MOCK_PORTS.CONSUL);
    consulMock.addService("api-backend", [
      { id: "api-1", address: "127.0.0.1", port: 19002, tags: ["primary"] },
      { id: "api-2", address: "127.0.0.1", port: 19003, tags: ["primary"] },
    ]);

    await startNginz(`tests/${MODULE}/nginx-consul.conf`, MODULE);
    // Wait for at least one refresh cycle (150ms interval + startup)
    await Bun.sleep(500);
  });

  afterAll(async () => {
    await stopNginz();
    consulMock.stop();
    cleanupRuntime(MODULE);
    if (existsSync(CONSUL_LIVENESS_SOURCE_FILE)) {
      rmSync(CONSUL_LIVENESS_SOURCE_FILE);
    }
  });

  test("consul source populates upstream from service catalog", async () => {
    const body = await waitForDynamicState((s) => s.peer_count === 2, 3000);
    expect(body.source).toBe("consul");
    expect(body.generation).toBeGreaterThan(0);
    expect(body.last_error_code).toBe(0);
    expect(body.peers).toContainEqual({ address: "127.0.0.1:19002", weight: 1 });
    expect(body.peers).toContainEqual({ address: "127.0.0.1:19003", weight: 1 });
  });

  test("consul source forwards tag, dc, and token metadata to the health query", async () => {
    consulMock.clearLog();
    await Bun.sleep(250);

    const requests = consulMock.getRequests();
    expect(requests.length).toBeGreaterThan(0);

    const lastRequest = requests.at(-1);
    expect(lastRequest.path).toBe("/v1/health/service/api-backend");
    expect(lastRequest.query.passing).toBe("true");
    expect(lastRequest.query.tag).toBe("primary");
    expect(lastRequest.query.dc).toBe("dc-west");
    expect(lastRequest.headers["x-consul-token"]).toBe("test-token-123");
  });

  test("only worker 0 owns the async polling loop while all workers observe the activated generation", async () => {
    const stable = await waitForDynamicState((s) => s.generation > 0 && s.peer_count === 2, 3000);
    consulMock.clearLog();
    await Bun.sleep(450);

    const requests = consulMock.getRequests();
    expect(requests.length).toBeGreaterThanOrEqual(2);
    expect(requests.length).toBeLessThanOrEqual(5);

    const observed = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(observed.generation).toBe(stable.generation);
    expect(observed.peers).toEqual(stable.peers);
  });

  test("consul source updates upstream when catalog changes", async () => {
    // Remove one service from consul
    consulMock.clearServices();
    consulMock.addService("api-backend", [
      { id: "api-1", address: "127.0.0.1", port: 19002, tags: ["primary"] },
    ]);

    const body = await waitForDynamicState((s) => s.peer_count === 1, 3000);
    expect(body.peers).toEqual([{ address: "127.0.0.1:19002", weight: 1 }]);
  });

  test("unchanged consul membership is a no-op refresh", async () => {
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    const beforeEvents = await getWorkerEvents();

    await Bun.sleep(450);

    const after = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    const events = await getWorkerEvents("upstreams", beforeEvents.newest_generation);

    expect(after.generation).toBe(before.generation);
    expect(
      events.events.filter((event) => {
        if (event.type !== "snapshot_activated") return false;
        const payload = JSON.parse(event.payload);
        return payload.target === "api_backend" && payload.source === "consul";
      }),
    ).toHaveLength(0);
  });

  test("slow consul does not block another worker-0 timer", async () => {
    const beforeStatic = await (await fetch(`${TEST_URL}/dynamic-upstreams-static`)).json();
    consulMock.setHealthBehavior({ delayMs: 6000 });

    writeFileSync(
      CONSUL_LIVENESS_SOURCE_FILE,
      JSON.stringify({ peers: [{ address: "127.0.0.1:19003", weight: 1 }] }),
    );

    const staticBody = await waitForDynamicRouteState(
      "/dynamic-upstreams-static",
      (s) => s.generation > beforeStatic.generation && s.peers[0]?.address === "127.0.0.1:19003",
      3000,
    );
    expect(staticBody.peers).toEqual([{ address: "127.0.0.1:19003", weight: 1 }]);

    consulMock.clearHealthBehavior();
    await waitForDynamicState((s) => s.peer_count === 1 && s.last_error_code === 0, 7000);
  });

  test("consul source keeps the last good snapshot on timeout", async () => {
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    consulMock.setHealthBehavior({ delayMs: 6000 });

    const after = await waitForDynamicState(
      (s) => s.generation === before.generation && s.last_error_code > 0,
      9000,
    );
    expect(after.peers).toEqual(before.peers);

    consulMock.clearHealthBehavior();
    await waitForDynamicState((s) => s.last_error_code === 0, 7000);
  });

  test("consul source records error and keeps last good state on consul failure", async () => {
    const snapshot = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    const prev_gen = snapshot.generation;
    const prev_peers = snapshot.peers;

    // Stop consul — next refresh will fail
    consulMock.stop();
    await Bun.sleep(500);

    const body = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    // Generation must not regress — last good snapshot stays active
    expect(body.generation).toBe(prev_gen);
    expect(body.last_error_code).toBeGreaterThan(0);
    expect(body.peers).toEqual(prev_peers);

    consulMock = createConsulMock(MOCK_PORTS.CONSUL);
    consulMock.addService("api-backend", [
      { id: "api-1", address: "127.0.0.1", port: 19002, tags: ["primary"] },
    ]);
    await waitForDynamicState((s) => s.peer_count === 1 && s.last_error_code === 0, 4000);
  });

  test("consul source keeps the last good snapshot on malformed JSON", async () => {
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    consulMock.setHealthBehavior({ rawBody: "{bad-json", headers: { "Content-Type": "application/json" } });

    const after = await waitForDynamicState(
      (s) => s.generation === before.generation && s.last_error_code === 4001,
      4000,
    );
    expect(after.peers).toEqual(before.peers);

    consulMock.clearHealthBehavior();
    await waitForDynamicState((s) => s.last_error_code === 0, 4000);
  });

  test("consul source reconciles an empty healthy result to an empty upstream snapshot", async () => {
    consulMock.clearServices();
    const before = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();

    const body = await waitForDynamicState(
      (s) => s.peer_count === 0 && s.generation > before.generation,
      3000,
    );
    expect(body.last_error_code).toBe(0);
    expect(body.peers).toEqual([]);
  });
});

describe("dynamic-upstreams Phase 4 — cold-start journal persistence", () => {
  const JOURNAL_PATH = "/tmp/nginz-journal-test.json";

  beforeAll(async () => {
    // Remove any stale journal before first run
    try { const { unlinkSync } = await import("fs"); unlinkSync(JOURNAL_PATH); } catch {}
    await startNginz(`tests/${MODULE}/nginx-journal.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    try { const { unlinkSync } = await import("fs"); unlinkSync(JOURNAL_PATH); } catch {}
  });

  test("GET response includes restored_from_journal and restore_error_code fields", async () => {
    const body = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(typeof body.restored_from_journal).toBe("boolean");
    expect(typeof body.restore_error_code).toBe("number");
  });

  test("successful PUT writes journal file to disk", async () => {
    const { existsSync } = await import("fs");

    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        peers: [
          { address: "127.0.0.1:19002", weight: 2 },
          { address: "127.0.0.1:19003", weight: 1 },
        ],
      }),
    });
    expect(res.status).toBe(200);

    // Journal is written synchronously after activation
    await Bun.sleep(100);
    expect(existsSync(JOURNAL_PATH)).toBe(true);

    const { readFileSync } = await import("fs");
    const journal = JSON.parse(readFileSync(JOURNAL_PATH, "utf8"));
    expect(journal.schema).toBe(1);
    expect(journal.target).toBe("api_backend");
    expect(journal.source).toBe("static");
    expect(typeof journal.generation).toBe("number");
    expect(journal.generation).toBeGreaterThan(0);
    expect(Array.isArray(journal.peers)).toBe(true);
    expect(journal.peers).toHaveLength(2);
    expect(journal.peers[0].address).toBe("127.0.0.1:19002");
    expect(journal.peers[0].weight).toBe(2);
  });

  test("cold restart restores snapshot from journal before first refresh", async () => {
    // PUT a known snapshot and let it journal
    const putRes = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ peers: [{ address: "127.0.0.1:19002", weight: 3 }] }),
    });
    expect(putRes.status).toBe(200);
    const putBody = await putRes.json();
    const journaledGen = putBody.generation;
    await Bun.sleep(100); // let journal flush

    // Restart nginx (cold restart — shared memory is not inherited)
    await stopNginz();
    await startNginz(`tests/${MODULE}/nginx-journal.conf`, MODULE);

    // Active snapshot should be restored immediately, before any PUT or timer
    const state = await waitForDynamicState((s) => s.peer_count > 0, 4000);
    expect(state.peer_count).toBe(1);
    expect(state.peers[0].address).toBe("127.0.0.1:19002");
    expect(state.restored_from_journal).toBe(true);
    expect(state.restore_error_code).toBe(0);
    // The restored generation is a new local generation, not necessarily equal to journaledGen
    expect(state.generation).toBeGreaterThan(0);
    void journaledGen;
  });

  test("cold restart emits snapshot_restored event", async () => {
    await stopNginz();
    await startNginz(`tests/${MODULE}/nginx-journal.conf`, MODULE);

    const events = await waitForWorkerEvents(
      (snapshot) => snapshot.events.some((event) => event.type === "snapshot_restored"),
      "upstreams",
      4000,
    );
    const restored = events.events.find((event) => event.type === "snapshot_restored");
    const payload = JSON.parse(restored.payload);
    expect(payload.target).toBe("api_backend");
    expect(payload.source).toBe("static");
    expect(typeof payload.generation).toBe("number");
    expect(typeof payload.peer_count).toBe("number");
    expect(payload.peer_count).toBeGreaterThan(0);
  });

  test("corrupt journal is non-fatal: nginx starts with restore_error_code set", async () => {
    const { writeFileSync } = await import("fs");
    writeFileSync(JOURNAL_PATH, "{bad-json");

    await stopNginz();
    await startNginz(`tests/${MODULE}/nginx-journal.conf`, MODULE);

    const state = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    // No snapshot restored from corrupt journal
    expect(state.restored_from_journal).toBe(false);
    expect(state.restore_error_code).toBeGreaterThan(0);
  });
});

describe("dynamic-upstreams Phase 5 — per-peer drain API", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("GET response includes drain_count field", async () => {
    const state = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(typeof state.drain_count).toBe("number");
    expect(state.drain_count).toBe(0);
  });

  test("PATCH drain adds address to drain table and updates drain_count", async () => {
    // First activate a snapshot so there is a managed store
    await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ peers: [{ address: "127.0.0.1:19002", weight: 1 }] }),
    });

    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
    expect(body.action).toBe("drain");
    expect(body.address).toBe("127.0.0.1:19002");
    expect(body.drain_count).toBe(1);

    // GET reflects the updated drain_count
    const state = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(state.drain_count).toBe(1);
  });

  test("PATCH drain emits peer_draining event", async () => {
    const beforeEvents = await getWorkerEvents("upstreams");
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);

    const events = await waitForWorkerEvents(
      (snapshot) => snapshot.events.some((event) => event.type === "peer_draining"),
      "upstreams",
      4000,
      beforeEvents.newest_generation,
    );
    const ev = events.events.find((event) => event.type === "peer_draining");
    const payload = JSON.parse(ev.payload);
    expect(payload.target).toBe("api_backend");
    expect(payload.address).toBe("127.0.0.1:19002");
    expect(payload.drain_count).toBeGreaterThanOrEqual(1);
  });

  test("PATCH drain is idempotent for already-draining address", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.drain_count).toBe(1); // still 1, not 2
  });

  test("PATCH undrain removes address and updates drain_count", async () => {
    const beforeEvents = await getWorkerEvents("upstreams");
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ undrain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.status).toBe("ok");
    expect(body.action).toBe("undrain");
    expect(body.drain_count).toBe(0);

    const state = await (await fetch(`${TEST_URL}/dynamic-upstreams`)).json();
    expect(state.drain_count).toBe(0);

    const events = await waitForWorkerEvents(
      (snapshot) => snapshot.events.some((event) => event.type === "peer_undrained"),
      "upstreams",
      4000,
      beforeEvents.newest_generation,
    );
    const ev = events.events.find((event) => event.type === "peer_undrained");
    const payload = JSON.parse(ev.payload);
    expect(payload.target).toBe("api_backend");
    expect(payload.address).toBe("127.0.0.1:19002");
    expect(payload.drain_count).toBe(0);
  });

  test("PATCH undrain is idempotent for non-draining address", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ undrain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.drain_count).toBe(0); // idempotent
  });

  test("PATCH rejects missing drain/undrain field", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ peers: [] }),
    });
    expect(res.status).toBe(400);
  });

  test("PATCH rejects requests that specify both drain and undrain", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        drain: "127.0.0.1:19002",
        undrain: "127.0.0.1:19002",
      }),
    });
    expect(res.status).toBe(400);
  });

  test("PATCH rejects address longer than 64 bytes", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "a".repeat(65) }),
    });
    expect(res.status).toBe(400);
  });

  test("PATCH rejects invalid JSON", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: "not-json",
    });
    expect(res.status).toBe(400);
  });

  test("PATCH drain rejects an address that is not part of the current upstream", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19999" }),
    });
    expect(res.status).toBe(404);
  });

  test("PATCH rejects missing Content-Type", async () => {
    const res = await fetch(`${TEST_URL}/dynamic-upstreams`, {
      method: "PATCH",
      body: JSON.stringify({ drain: "127.0.0.1:19002" }),
    });
    expect(res.status).toBe(415);
  });
});

describe("dynamic-upstreams Phase 5 — drain state is scoped per upstream", () => {
  let backend;

  beforeAll(async () => {
    backend = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1);
    backend.setDefault({ status: 200, body: { server: "shared-backend" } });
    await startNginz(`tests/${MODULE}/nginx-drain-scope.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend.stop();
    cleanupRuntime(MODULE);
  });

  test("draining one managed upstream does not exclude the same address in another upstream", async () => {
    const routeHeaders = { "x-route": "scope-test" };

    const beforeBlue = await fetch(`${TEST_URL}/blue`, { headers: routeHeaders });
    const beforeGreen = await fetch(`${TEST_URL}/green`, { headers: routeHeaders });
    expect(beforeBlue.status).toBe(200);
    expect(beforeGreen.status).toBe(200);

    const patchRes = await fetch(`${TEST_URL}/dynamic-upstreams-blue`, {
      method: "PATCH",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ drain: "127.0.0.1:19002" }),
    });
    expect(patchRes.status).toBe(200);

    const afterBlue = await fetch(`${TEST_URL}/blue`, { headers: routeHeaders });
    const afterGreen = await fetch(`${TEST_URL}/green`, { headers: routeHeaders });
    expect(afterBlue.status).toBe(502);
    expect(afterGreen.status).toBe(200);
  });
});
