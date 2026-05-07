import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "dynamic-upstreams";

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
});
