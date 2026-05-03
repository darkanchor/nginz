import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "worker-events";

describe("worker-events scaffold module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("returns explicit 501 placeholder JSON", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`);
    expect(res.status).toBe(501);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json();
    expect(body).toEqual({
      status: "not_implemented",
      module: "worker_events",
    });
  });

  test("supports HEAD requests on scaffold endpoint", async () => {
    const res = await fetch(`${TEST_URL}/worker-events`, { method: "HEAD" });
    expect(res.status).toBe(501);
    expect(await res.text()).toBe("");
  });

  test("leaves normal locations unaffected", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});
