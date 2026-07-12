import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  createHTTPMock,
  MOCK_PORTS,
  TEST_URL,
} from "../harness.js";

const MODULE_NAME = "transform";

let httpMock;

beforeAll(async () => {
  // Create mock backend that returns various JSON responses
  httpMock = createHTTPMock(MOCK_PORTS.HTTP);
  httpMock.setDefault((req) => {
    const url = new URL(req.url);

    if (url.pathname === "/nested") {
      return Response.json({
        status: "ok",
        data: {
          value: 42,
          name: "test"
        }
      });
    }

    if (url.pathname === "/with-array") {
      return Response.json({
        items: [
          { id: 1, name: "first" },
          { id: 2, name: "second" },
          { id: 3, name: "third" }
        ],
        total: 3
      });
    }

    if (url.pathname === "/text") {
      return new Response("plain text response", {
        headers: { "Content-Type": "text/plain" }
      });
    }

    if (url.pathname === "/json-charset") {
      return new Response(JSON.stringify({
        data: { name: "charset-json", count: 7 }
      }), {
        headers: { "Content-Type": "application/json; charset=utf-8" }
      });
    }

    if (url.pathname === "/string-value") {
      return Response.json({
        data: { greeting: "hello world" }
      });
    }

    if (url.pathname === "/invalid-json") {
      return new Response('{"data":', {
        headers: { "Content-Type": "application/json" }
      });
    }

    if (url.pathname.startsWith("/sized/")) {
      const size = Number(url.pathname.split("/").pop());
      return new Response(`{"data":"${"x".repeat(size - 11)}"}`, {
        headers: { "Content-Type": "application/json", "Content-Length": String(size) }
      });
    }

    if (url.pathname === "/json-lookalike") {
      return new Response('{"data":{"leaked":true}}', {
        headers: { "Content-Type": "application/jsonp" }
      });
    }

    if (url.pathname === "/json-case") {
      return new Response('{"data":{"case":"ok"}}', {
        headers: { "Content-Type": "Application/JSON ; charset=utf-8" }
      });
    }

    return Response.json({ error: "not found" }, { status: 404 });
  });

  await startNginz(`tests/${MODULE_NAME}/nginx.conf`, MODULE_NAME);
});

afterAll(async () => {
  await stopNginz();
  httpMock?.stop();
  cleanupRuntime(MODULE_NAME);
});

describe("transform_response directive", () => {
  test("extracts nested object with $.data path", async () => {
    const res = await fetch(`${TEST_URL}/extract-object`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({ value: 42, name: "test" });
  });

  test("extracts array with $.items path", async () => {
    const res = await fetch(`${TEST_URL}/extract-array`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toBeArray();
    expect(body.length).toBe(3);
    expect(body[0]).toEqual({ id: 1, name: "first" });
  });

  test("extracts nested value with $.data.value path", async () => {
    const res = await fetch(`${TEST_URL}/extract-nested`);
    expect(res.status).toBe(200);
    const text = await res.text();
    // Parse as number since cJSON may add trailing characters
    expect(parseInt(text, 10)).toBe(42);
  });

  test("extracts array element with $.items.0 path", async () => {
    const res = await fetch(`${TEST_URL}/extract-element`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({ id: 1, name: "first" });
  });

  test("passes through response without transform directive", async () => {
    const res = await fetch(`${TEST_URL}/passthrough`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({
      status: "ok",
      data: { value: 42, name: "test" }
    });
  });

  test("passes through when path does not exist", async () => {
    const res = await fetch(`${TEST_URL}/invalid-path`);
    expect(res.status).toBe(200);
    const body = await res.json();
    // Original response passed through on transform failure
    expect(body).toEqual({
      status: "ok",
      data: { value: 42, name: "test" }
    });
  });

  test("passes through non-JSON responses", async () => {
    const res = await fetch(`${TEST_URL}/non-json`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toBe("plain text response");
  });

  test("transforms JSON responses with charset content-type", async () => {
    const res = await fetch(`${TEST_URL}/json-charset`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body).toEqual({ name: "charset-json", count: 7 });
  });

  test("extracts string values as JSON strings", async () => {
    const res = await fetch(`${TEST_URL}/extract-string`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toBe('"hello world"');
  });

  test("passes through invalid JSON bodies unchanged", async () => {
    const res = await fetch(`${TEST_URL}/invalid-json-transform`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text).toBe('{"data":');
  });

  test("transforms a response exactly at the configured buffer limit", async () => {
    const res = await fetch(`${TEST_URL}/limit-exact`);
    expect(res.status).toBe(200);
    expect(await res.json()).toBe("x".repeat(117));
  });

  test("rejects a known response one byte above the configured buffer limit", async () => {
    const res = await fetch(`${TEST_URL}/limit-over`);
    expect(res.status).toBe(502);
    expect(await res.text()).toBe("");
  });

  test("does not transform JSON-like media types", async () => {
    const res = await fetch(`${TEST_URL}/json-lookalike`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ data: { leaked: true } });
  });

  test("matches the JSON media type case-insensitively", async () => {
    const res = await fetch(`${TEST_URL}/json-case`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ case: "ok" });
  });

});
