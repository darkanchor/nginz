import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "cache-purge";

async function purge(targets) {
  return fetch(`${TEST_URL}/cache-purge`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ targets }),
  });
}

describe("cache-purge Phase 1 - API contract", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("GET returns 405 method not allowed", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`);
    expect(res.status).toBe(405);
    const body = await res.json();
    expect(body.module).toBe("cache_purge");
    expect(body.status).toBe("error");
  });

  test("HEAD returns 405 method not allowed", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`, { method: "HEAD" });
    expect(res.status).toBe(405);
    expect(await res.text()).toBe("");
  });

  test("POST without JSON content-type returns 415", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`, {
      method: "POST",
      body: '{"targets":["tag1"]}',
    });
    expect(res.status).toBe(415);
  });

  test("POST with missing body returns 400", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("POST with invalid JSON returns 400", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not json",
    });
    expect(res.status).toBe(400);
  });

  test("POST with non-array targets returns 400", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: '{"targets":"user-123"}',
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain("'targets' must be an array");
  });

  test("POST with too many targets returns 400 (max_keys=4)", async () => {
    const res = await purge(["a", "b", "c", "d", "e"]);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain("max_keys");
  });

  test("POST with empty targets array returns 200 with zero counts", async () => {
    const res = await purge([]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.module).toBe("cache_purge");
    expect(body.match).toBe("exact");
    expect(body.requested).toBe(0);
    expect(body.purged).toBe(0);
    expect(body.missing).toBe(0);
    expect(body.rejected).toBe(0);
    expect(Array.isArray(body.results)).toBe(true);
    expect(body.results).toHaveLength(0);
  });
});

describe("cache-purge Phase 2 - Exact invalidation", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("zero-hit purge is non-error with explicit accounting", async () => {
    const res = await purge(["nonexistent-tag"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(1);
    expect(body.purged).toBe(0);
    expect(body.missing).toBe(1);
    expect(body.rejected).toBe(0);
    expect(body.results).toHaveLength(1);
    expect(body.results[0].target).toBe("nonexistent-tag");
    expect(body.results[0].purged).toBe(0);
  });

  test("purges an existing tag and returns correct counts", async () => {
    // Register tag via cache-tags header filter
    await fetch(`${TEST_URL}/api`);

    const res = await purge(["user-123"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(1);
    expect(body.purged).toBeGreaterThan(0);
    expect(body.missing).toBe(0);
    expect(body.results[0].target).toBe("user-123");
    expect(body.results[0].purged).toBeGreaterThan(0);
  });

  test("second purge of same tag is zero-hit (idempotent)", async () => {
    // Tag already purged from previous test — purging again is a non-error zero-hit
    const res = await purge(["user-123"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.purged).toBe(0);
    expect(body.missing).toBe(1);
  });

  test("batch purge with mixed hit/miss targets", async () => {
    // Re-register tag
    await fetch(`${TEST_URL}/api`);

    const res = await purge(["user-123", "no-such-tag"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(2);
    expect(body.missing).toBe(1);
    expect(body.results).toHaveLength(2);
  });

  test("other routes remain available", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});
