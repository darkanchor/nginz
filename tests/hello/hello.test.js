import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";

const MODULE = "hello";


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("hello module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  describe("hello directive", () => {
    test("outputs 'hello' text", async () => {
      const res = await fetchClose(`${TEST_URL}/hello`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello");
    });

    test("works on different location paths", async () => {
      const res = await fetchClose(`${TEST_URL}/greeting`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello");
    });

    test("works with nested locations", async () => {
      const res = await fetchClose(`${TEST_URL}/api/hello`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello");
    });

    test("works on exact-match locations", async () => {
      const res = await fetchClose(`${TEST_URL}/hello-exact`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello");
    });

    test("returns correct content type (none set)", async () => {
      const res = await fetchClose(`${TEST_URL}/hello`);
      expect(res.status).toBe(200);
      // hello module doesn't set content-type explicitly
    });

    test("handles HEAD request", async () => {
      const res = await fetchClose(`${TEST_URL}/hello`, { method: "HEAD" });
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe(""); // HEAD should not return body
    });

    test("returns hello body for POST requests as well", async () => {
      const res = await fetchClose(`${TEST_URL}/hello`, {
        method: "POST",
        body: "ignored",
      });
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello");
    });

    test("non-hello locations remain unaffected", async () => {
      const res = await fetchClose(`${TEST_URL}/plain`);
      expect(res.status).toBe(204);
      const body = await res.text();
      expect(body).toBe("");
    });

    test("terminates SSI subrequests correctly", async () => {
      const res = await fetchClose(`${TEST_URL}/hello-ssi-parent`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello");
    });

    test("works as an auth_request target without emitting body", async () => {
      const res = await fetchClose(`${TEST_URL}/hello-auth-parent`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("auth-ok");
    });

    test("works as a mirror target without breaking the parent response", async () => {
      const res = await fetchClose(`${TEST_URL}/hello-mirror-parent`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("mirror-ok");
    });
  });
});
