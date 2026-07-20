import { describe, test, expect, beforeAll, afterAll } from "bun:test";
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



describe("njs stdlib modules", () => {
  beforeAll(async () => {
    await startNginz("tests/njs/stdlib.conf", MODULE);
  });

  afterAll(async () => {
    await teardownModule(MODULE);
  });

  describe("querystring module", () => {
    test("qs.stringify serializes an object to query string", async () => {
      const res = await testFetch(`/qs/stringify`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "alice", age: "30" }),
      });
      expect(res.status).toBe(200);
      const text = await res.text();
      const parsed = Object.fromEntries(new URLSearchParams(text));
      expect(parsed.name).toBe("alice");
      expect(parsed.age).toBe("30");
    });

    test("qs.parse deserializes query string args to object", async () => {
      const res = await testFetch(`/qs/parse?a=1&b=hello`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.a).toBe("1");
      expect(body.b).toBe("hello");
    });

    test("qs.parse handles empty query string", async () => {
      const res = await testFetch(`/qs/parse`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(Object.keys(body).length).toBe(0);
    });

    test("stringify/parse roundtrip preserves special characters", async () => {
      const res = await testFetch(`/qs/roundtrip`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);
    });
  });

  describe("fs module", () => {
    test("writeFileSync creates file with content", async () => {
      const content = "hello from njs fs";
      await testFetch(`/fs/write`, { method: "POST", body: content });
      const res = await testFetch(`/fs/read`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(content);
    });

    test("writeFileSync overwrites existing content", async () => {
      await testFetch(`/fs/write`, { method: "POST", body: "first" });
      await testFetch(`/fs/write`, { method: "POST", body: "second" });
      const res = await testFetch(`/fs/read`);
      expect(await res.text()).toBe("second");
    });

    test("appendFileSync appends to file", async () => {
      await testFetch(`/fs/write`, { method: "POST", body: "line1" });
      await testFetch(`/fs/append`, { method: "POST", body: "line2" });
      const res = await testFetch(`/fs/read`);
      expect(await res.text()).toBe("line1line2");
    });

    test("readFileSync returns 404 after unlink", async () => {
      await testFetch(`/fs/write`, { method: "POST", body: "data" });
      await testFetch(`/fs/unlink`);
      const res = await testFetch(`/fs/read`);
      expect(res.status).toBe(404);
    });
  });

  describe("xml module", () => {
    test("xml.parse returns root element name", async () => {
      const res = await testFetch(`/xml/root-name`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("catalog");
    });

    test("$tag$child.$text reads element text content", async () => {
      const res = await testFetch(`/xml/child-text`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("hello njs");
    });

    test("$attr$name reads element attributes", async () => {
      const res = await testFetch(`/xml/attribute`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.id).toBe("42");
      expect(body.lang).toBe("en");
    });

    test("$tags$name returns all matching children as array", async () => {
      const res = await testFetch(`/xml/multiple-tags`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body).toEqual(["a", "b", "c"]);
    });

    test("nested elements accessible via chained $tag$", async () => {
      const res = await testFetch(`/xml/nested`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.title).toBe("T1");
      expect(body.body).toBe("B1");
    });

    test("xml.serializeToString round-trips the document", async () => {
      const res = await testFetch(`/xml/serialize`);
      expect(res.status).toBe(200);
      const text = await res.text();
      expect(text).toContain("Alice");
      expect(text).toContain("Bob");
      expect(text).toContain("<to>");
      expect(text).toContain("<from>");
    });
  });
});
