import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  createHTTPMock,
  MOCK_PORTS,
  TEST_URL,
} from "../harness.js";

const MODULE = "upstream-balancer";

let backend;

describe("upstream-balancer scaffold module", () => {
  beforeAll(async () => {
    backend = createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1);
    backend.get("/", {
      status: 200,
      body: { upstream: "ok", module: MODULE },
    });

    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    backend.stop();
    cleanupRuntime(MODULE);
  });

  test("accepts upstream scaffold directives and preserves proxy traffic", async () => {
    const res = await fetch(`${TEST_URL}/`, {
      headers: {
        Cookie: "route=stable-a",
        "X-Sticky-Key": "beta-client",
      },
    });

    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toContain("application/json");

    const body = await res.json();
    expect(body).toEqual({ upstream: "ok", module: MODULE });

    const requests = backend.getRequestsFor("/", "GET");
    expect(requests.length).toBeGreaterThan(0);
  });
});
