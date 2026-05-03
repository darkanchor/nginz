import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "cache-purge";

describe("cache-purge scaffold module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("returns explicit 501 placeholder JSON", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`);
    expect(res.status).toBe(501);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json();
    expect(body).toEqual({
      status: "not_implemented",
      module: "cache_purge",
    });
  });

  test("supports HEAD requests on scaffold endpoint", async () => {
    const res = await fetch(`${TEST_URL}/cache-purge`, { method: "HEAD" });
    expect(res.status).toBe(501);
    expect(await res.text()).toBe("");
  });

  test("keeps other routes available", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});
