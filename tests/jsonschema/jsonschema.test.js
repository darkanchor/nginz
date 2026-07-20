import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "fs";
import { tmpdir } from "os";
import { join } from "path";

const MODULE = "jsonschema";

function testSchemaConfig(schema) {
  const runtime = mkdtempSync(join(tmpdir(), "nginz-jsonschema-config-"));
  const config = join(runtime, "nginx.conf");
  mkdirSync(join(runtime, "logs"), { recursive: true });
  writeFileSync(config, `daemon off; error_log stderr notice; pid logs/nginx.pid;
events { worker_connections 16; }
http { server { listen 8899; location / { jsonschema '${schema}'; echozn ok; } } }
`);
  try {
    return spawnSync("./zig-out/bin/nginz", ["-t", "-p", runtime, "-c", config], {
      cwd: process.cwd(), encoding: "utf8",
    });
  } finally {
    rmSync(runtime, { recursive: true, force: true });
  }
}


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("jsonschema module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  describe("non-validated endpoints", () => {
    test("allows any request to non-validated endpoint", async () => {
      const res = await fetchClose(`${TEST_URL}/`);
      expect(res.status).toBe(200);
    });

    test("allows GET requests without validation", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`);
      expect(res.status).toBe(200);
    });
  });

  describe("valid JSON validation", () => {
    test("accepts valid JSON with required fields", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "John", email: "john@example.com" }),
      });
      expect(res.status).toBe(200);
    });

    test("accepts valid JSON with all fields", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "John",
          email: "john@example.com",
          age: 25,
        }),
      });
      expect(res.status).toBe(200);
    });

    test("accepts valid object type", async () => {
      const res = await fetchClose(`${TEST_URL}/api/simple`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ any: "data" }),
      });
      expect(res.status).toBe(200);
    });

    test("accepts PUT requests when body matches schema", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "PUT",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "John",
          email: "john@example.com",
          age: 25,
        }),
      });
      expect(res.status).toBe(200);
    });

    test("accepts PATCH requests when body matches schema", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json; charset=utf-8" },
        body: JSON.stringify({
          name: "John",
          email: "john@example.com",
          age: 25,
        }),
      });
      expect(res.status).toBe(200);
    });

    test("accepts integer values for integer schemas", async () => {
      const res = await fetchClose(`${TEST_URL}/api/integer`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ count: 2 }),
      });
      expect(res.status).toBe(200);
    });
  });

  describe("invalid JSON validation", () => {
    test("rejects a request body above the configured module limit", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "x".repeat(160), email: "john@example.com" }),
      });
      expect(res.status).toBe(413);
    });

    test("rejects invalid JSON syntax with 400", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "not valid json",
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe("validation_failed");
    });

    test("rejects missing required field with 400", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "John" }), // missing email
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.error).toBe("validation_failed");
    });

    test("rejects wrong type with 400", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: 123, // should be string
          email: "test@example.com",
        }),
      });
      expect(res.status).toBe(400);
    });

    test("rejects number below minimum with 400", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "John",
          email: "john@example.com",
          age: -5, // minimum is 0
        }),
      });
      expect(res.status).toBe(400);
    });

    test("rejects string below minLength with 400", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          name: "", // minLength is 1
          email: "john@example.com",
        }),
      });
      expect(res.status).toBe(400);
    });

    test("rejects non-object when object required", async () => {
      const res = await fetchClose(`${TEST_URL}/api/simple`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify("just a string"),
      });
      expect(res.status).toBe(400);
    });

    test("rejects fractional numbers for integer schemas", async () => {
      const res = await fetchClose(`${TEST_URL}/api/integer`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ count: 1.5 }),
      });
      expect(res.status).toBe(400);
    });
  });

  describe("content type handling", () => {
    test("does not mistake JSON-like media types for JSON", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/jsonp" },
        body: "not json",
      });
      expect(res.status).toBe(200);
    });

    test("skips validation for non-JSON content type", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "text/plain" },
        body: "not json",
      });
      // Should pass through without validation
      expect(res.status).toBe(200);
    });

    test("skips validation for missing content type", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        body: JSON.stringify({ name: 123 }),
      });
      expect(res.status).toBe(200);
    });

    test("allows empty JSON request bodies to pass through", async () => {
      const res = await fetchClose(`${TEST_URL}/api/users`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "",
      });
      expect(res.status).toBe(200);
    });
  });

  describe("schema vocabulary validation", () => {
    test("rejects unsupported schema keywords at configuration time", () => {
      const result = testSchemaConfig('{"type":"string","pattern":"^safe$"}');
      const output = `${result.stderr}${result.stdout}`;
      expect(output).toContain("configuration file");
      expect(output).toContain("test failed");
      expect(output).toContain("unsupported or malformed vocabulary");
    });

    test("rejects malformed supported keywords at configuration time", () => {
      const result = testSchemaConfig('{"type":"object","required":"name"}');
      const output = `${result.stderr}${result.stdout}`;
      expect(output).toContain("configuration file");
      expect(output).toContain("test failed");
      expect(output).toContain("unsupported or malformed vocabulary");
    });
  });
});
