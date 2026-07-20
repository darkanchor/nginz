import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { createHash, createHmac } from "crypto";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  teardownModule,
  prepareMockPorts,
  testFetch,
} from "../harness.js";

const MODULE = "njs";



describe("njs (QuickJS) module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await teardownModule(MODULE);
  });

  describe("js_content basic handler", () => {
    test("returns plain text response", async () => {
      const res = await testFetch(`/hello`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("Hello from njs!\n");
    });

    test("njs.version is a semver string", async () => {
      const res = await testFetch(`/version`);
      expect(res.status).toBe(200);
      const ver = await res.text();
      expect(ver).toMatch(/^\d+\.\d+\.\d+$/);
    });
  });

  describe("request inspection", () => {
    test("r.method reflects GET", async () => {
      const res = await testFetch(`/method`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("GET");
    });

    test("r.method reflects POST", async () => {
      const res = await testFetch(`/method`, { method: "POST", body: "" });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("POST");
    });

    test("r.uri is the request path", async () => {
      const res = await testFetch(`/uri?foo=bar`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("/uri");
    });

    test("r.args parses query string", async () => {
      const res = await testFetch(`/args?a=1&b=hello`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.a).toBe("1");
      expect(body.b).toBe("hello");
    });

    test("r.headersIn reads request header", async () => {
      const res = await testFetch(`/header`, {
        headers: { "X-Test": "custom-value" },
      });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("custom-value");
    });

    test("r.headersIn missing header returns fallback", async () => {
      const res = await testFetch(`/header`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("none");
    });
  });

  describe("response header manipulation", () => {
    test("r.headersOut sets response header", async () => {
      const res = await testFetch(`/set-header`);
      expect(res.status).toBe(200);
      expect(res.headers.get("X-Powered-By")).toBe("njs");
    });
  });

  describe("request body", () => {
    test("r.requestText echoes POST body", async () => {
      const res = await testFetch(`/body`, {
        method: "POST",
        body: "hello body",
      });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("hello body");
    });

    test("JSON roundtrip via JSON.parse / JSON.stringify", async () => {
      const payload = { name: "njs", engine: "quickjs" };
      const res = await testFetch(`/json`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.received).toEqual(payload);
    });
  });

  describe("Buffer and encoding", () => {
    test("Buffer.from().toString('base64') encodes correctly", async () => {
      const expected = Buffer.from("hello").toString("base64");
      const res = await testFetch(`/base64?input=hello`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(expected);
    });

    test("empty input produces empty base64", async () => {
      const res = await testFetch(`/base64`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("");
    });
  });

  describe("crypto module", () => {
    test("crypto.createHash sha256 digest matches", async () => {
      const expected = createHash("sha256").update("hello").digest("hex");
      const res = await testFetch(`/sha256?input=hello`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(expected);
    });

    test("sha256 of empty string is correct", async () => {
      const expected = createHash("sha256").update("").digest("hex");
      const res = await testFetch(`/sha256`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(expected);
    });

    test("crypto.createHmac sha256 digest matches", async () => {
      const expected = createHmac("sha256", "secret-key")
        .update("test-data")
        .digest("hex");
      const res = await testFetch(`/hmac?data=test-data`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(expected);
    });
  });

  describe("js_set variable", () => {
    test("js_set decodes URL-encoded variable into nginx var", async () => {
      const res = await testFetch(`/var?foo=hello%20world`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("hello world");
    });

    test("js_set with special characters", async () => {
      const res = await testFetch(`/var?foo=caf%C3%A9`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("café");
    });
  });
});
