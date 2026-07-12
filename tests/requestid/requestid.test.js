import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  MOCK_PORTS,
} from "../harness.js";

const MODULE = "requestid";
let httpMock;

// UUID4 regex pattern: 8-4-4-4-12 hex characters
const UUID4_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

describe("requestid module", () => {
  beforeAll(async () => {
    // Start mock backend server
    httpMock = createHTTPMock(MOCK_PORTS.HTTP);
    httpMock.get("/", { body: { status: "ok" }, status: 200 });

    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    httpMock.stop();
    cleanupRuntime(MODULE);
  });

  describe("basic functionality", () => {
    test("generates X-Request-ID response header", async () => {
      const res = await fetch(`${TEST_URL}/return-test`);
      expect(res.status).toBe(200);

      const requestId = res.headers.get("X-Request-ID");
      expect(requestId).toBeTruthy();
      expect(requestId).toMatch(UUID4_PATTERN);
    });

    test("generates unique IDs for each request", async () => {
      const ids = new Set();

      for (let i = 0; i < 10; i++) {
        const res = await fetch(`${TEST_URL}/return-test`);
        const requestId = res.headers.get("X-Request-ID");
        ids.add(requestId);
      }

      // All 10 IDs should be unique
      expect(ids.size).toBe(10);
    });
  });

  describe("disabled location", () => {
    test("does not generate ID when request_id is not enabled", async () => {
      const res = await fetch(`${TEST_URL}/disabled`);
      expect(res.status).toBe(200);

      const requestId = res.headers.get("X-Request-ID");
      expect(requestId).toBeNull();
    });
  });

  describe("ID propagation", () => {
    test("propagates existing X-Request-ID from request", async () => {
      const incomingId = "test-propagated-id-12345";
      const res = await fetch(`${TEST_URL}/return-test`, {
        headers: { "X-Request-ID": incomingId },
      });
      expect(res.status).toBe(200);

      // Response header should contain the propagated ID
      const responseId = res.headers.get("X-Request-ID");
      expect(responseId).toBe(incomingId);
    });

    test("generates new ID when no incoming header", async () => {
      const res = await fetch(`${TEST_URL}/return-test`);
      expect(res.status).toBe(200);

      const requestId = res.headers.get("X-Request-ID");
      expect(requestId).toBeTruthy();
      expect(requestId).toMatch(UUID4_PATTERN);
    });

    test("header matching is case-insensitive", async () => {
      const incomingId = "case-insensitive-test-id";

      // Test with lowercase header
      const res1 = await fetch(`${TEST_URL}/return-test`, {
        headers: { "x-request-id": incomingId },
      });
      expect(res1.headers.get("X-Request-ID")).toBe(incomingId);

      // Test with mixed case header
      const res2 = await fetch(`${TEST_URL}/return-test`, {
        headers: { "X-REQUEST-ID": incomingId },
      });
      expect(res2.headers.get("X-Request-ID")).toBe(incomingId);
    });

    test("supports custom request ID header names", async () => {
      const incomingId = "custom-correlation-id-123";
      const res = await fetch(`${TEST_URL}/custom-header`, {
        headers: { "X-Correlation-ID": incomingId },
      });
      expect(res.status).toBe(200);
      expect(res.headers.get("X-Correlation-ID")).toBe(incomingId);
      expect(res.headers.get("X-Request-ID")).toBeNull();
    });

    test("rejects oversized or whitespace-bearing incoming IDs and regenerates", async () => {
      for (const incomingId of ["x".repeat(129), "not a safe id"]) {
        const res = await fetch(`${TEST_URL}/return-test`, {
          headers: { "X-Request-ID": incomingId },
        });
        const responseId = res.headers.get("X-Request-ID");
        expect(responseId).not.toBe(incomingId);
        expect(responseId).toMatch(UUID4_PATTERN);
      }
    });
  });

  describe("proxy pass", () => {
    test("adds X-Request-ID header when proxying", async () => {
      httpMock.requestLog = [];
      const res = await fetch(`${TEST_URL}/proxy-test`);
      expect(res.status).toBe(200);

      const requestId = res.headers.get("X-Request-ID");
      expect(requestId).toBeTruthy();
      expect(requestId).toMatch(UUID4_PATTERN);

      const upstreamRequests = httpMock.getRequestsFor("/", "GET");
      expect(upstreamRequests.length).toBeGreaterThan(0);
      expect(upstreamRequests[0].headers["x-request-id"]).toBe(requestId);
    });
  });

  describe("$ngz_request_id variable", () => {
    test("variable contains the request ID", async () => {
      const res = await fetch(`${TEST_URL}/variable-test`);
      expect(res.status).toBe(200);

      const body = await res.text();
      const requestId = res.headers.get("X-Request-ID");

      // Body should contain "id:<request-id>"
      expect(body).toBe(`id:${requestId}\n`);
    });

    test("variable matches UUID4 format", async () => {
      const res = await fetch(`${TEST_URL}/variable-test`);
      const body = await res.text();

      // Extract ID from body "id:<uuid>\n"
      const idFromBody = body.slice(3, -1);
      expect(idFromBody).toMatch(UUID4_PATTERN);
    });

    test("variable propagates incoming header", async () => {
      const incomingId = "propagated-via-variable-123";
      const res = await fetch(`${TEST_URL}/variable-test`, {
        headers: { "X-Request-ID": incomingId },
      });
      expect(res.status).toBe(200);

      const body = await res.text();
      expect(body).toBe(`id:${incomingId}\n`);
    });

    test("variable still works when response header emission is disabled", async () => {
      const res = await fetch(`${TEST_URL}/internal-variable`);
      expect(res.status).toBe(200);

      const body = await res.text();
      const idFromBody = body.slice(3, -1);
      expect(idFromBody).toMatch(UUID4_PATTERN);
      expect(res.headers.get("X-Request-ID")).toBeNull();
    });
  });

  describe("UUID4 format validation", () => {
    test("version nibble is 4", async () => {
      const res = await fetch(`${TEST_URL}/return-test`);
      const requestId = res.headers.get("X-Request-ID");

      // Character at position 14 should be '4' (version)
      expect(requestId[14]).toBe("4");
    });

    test("variant nibble is valid (8, 9, a, or b)", async () => {
      const res = await fetch(`${TEST_URL}/return-test`);
      const requestId = res.headers.get("X-Request-ID");

      // Character at position 19 should be 8, 9, a, or b (variant)
      expect(["8", "9", "a", "b"]).toContain(requestId[19]);
    });

    test("correct hyphen positions", async () => {
      const res = await fetch(`${TEST_URL}/return-test`);
      const requestId = res.headers.get("X-Request-ID");

      expect(requestId[8]).toBe("-");
      expect(requestId[13]).toBe("-");
      expect(requestId[18]).toBe("-");
      expect(requestId[23]).toBe("-");
    });

    test("correct total length", async () => {
      const res = await fetch(`${TEST_URL}/return-test`);
      const requestId = res.headers.get("X-Request-ID");

      expect(requestId.length).toBe(36);
    });
  });
});
