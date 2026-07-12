import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "echoz";

describe("echoz module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  describe("echoz directive", () => {
    test("outputs text with newline", async () => {
      const res = await fetch(`${TEST_URL}/echo`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello world\n");
    });

    test("multiple echoz commands output multiple lines", async () => {
      const res = await fetch(`${TEST_URL}/multi`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("line1\nline2\nline3\n");
    });

    test("handles multiple arguments with spaces", async () => {
      const res = await fetch(`${TEST_URL}/args`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello world from nginx\n");
    });

    test("empty echoz outputs just newline", async () => {
      const res = await fetch(`${TEST_URL}/empty`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("\n");
    });
  });

  describe("echozn directive", () => {
    test("outputs text without newline", async () => {
      const res = await fetch(`${TEST_URL}/echon`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("nonewline");
    });

    test("HEAD request stays bodyless", async () => {
      const res = await fetch(`${TEST_URL}/echon`, { method: "HEAD" });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("");
    });
  });

  describe("echoz_duplicate directive", () => {
    test("repeats string N times", async () => {
      const res = await fetch(`${TEST_URL}/duplicate`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("abcabcabc");
    });
  });

  describe("variable interpolation", () => {
    test("interpolates nginx variables", async () => {
      const res = await fetch(`${TEST_URL}/vars`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toContain("method: GET");
      expect(body).toContain("uri: /vars");
    });
  });

  describe("echoz_exec directive", () => {
    test("redirects to named location", async () => {
      const res = await fetch(`${TEST_URL}/exec`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("redirected!\n");
    });

    test("redirects to regular location", async () => {
      const res = await fetch(`${TEST_URL}/exec2`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("hello world\n");
    });
  });

  describe("echoz_request_body directive", () => {
    test("echoes request body", async () => {
      const res = await fetch(`${TEST_URL}/body`, {
        method: "POST",
        body: "test body content",
      });
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toContain("body received:");
      expect(body).toContain("test body content");
    });

    test("request-body variable is empty when no body was read", async () => {
      const res = await fetch(`${TEST_URL}/body-variable-without-read`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("");

      // Prove the worker remains available after evaluating the variable.
      const followup = await fetch(`${TEST_URL}/echo`);
      expect(followup.status).toBe(200);
      expect(await followup.text()).toBe("hello world\n");
    });
  });

  describe("echoz_location_async directive", () => {
    test("makes async subrequest", async () => {
      const res = await fetch(`${TEST_URL}/main`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("before\nafter\n");
    });

    test("survives repeated subrequest fanout", async () => {
      for (let i = 0; i < 3; i++) {
        const res = await fetch(`${TEST_URL}/main`);
        expect(res.status).toBe(200);
        expect(await res.text()).toBe("before\nafter\n");
      }
    });
  });

  describe("echozn as subrequest target", () => {
    test("auth_request can use echozn target", async () => {
      const res = await fetch(`${TEST_URL}/auth-gate`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("granted");
    });

    test("SSI can include echozn target without adding newline", async () => {
      const res = await fetch(`${TEST_URL}/ssi-snippet`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("preXpost");
    });

    test("mirror can target echozn repeatedly without crashing worker", async () => {
      for (let i = 0; i < 3; i++) {
        const res = await fetch(`${TEST_URL}/mirror-snippet`);
        expect(res.status).toBe(200);
        expect(await res.text()).toBe("mirror-ok");
      }
    });
  });

  describe("additional documented directives", () => {
    test("echoz_flush keeps response stream valid", async () => {
      const res = await fetch(`${TEST_URL}/flush`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toBe("before flush\nafter flush\n");
    });

    test("filter directives can set status, headers, and wrap body", async () => {
      const res = await fetch(`${TEST_URL}/filtered`);
      expect(res.status).toBe(201);
      expect(res.headers.get("x-echoz")).toBe("filtered");
      const body = await res.text();
      expect(body).toBe("before|body|after");
    });
  });
});
