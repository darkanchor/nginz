import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";

const MODULE = "redis";
const REDIS_CONTAINER = "redis-nginz-test";

// ---------------------------------------------------------------------------
// Shell helpers
// ---------------------------------------------------------------------------

function runResult(command) {
  const result = Bun.spawnSync(command, {
    stdout: "pipe",
    stderr: "pipe",
    cwd: process.cwd(),
    env: process.env,
  });
  return {
    exitCode: result.exitCode,
    stdout: result.stdout ? Buffer.from(result.stdout).toString() : "",
    stderr: result.stderr ? Buffer.from(result.stderr).toString() : "",
  };
}

function run(command) {
  const result = runResult(command);
  if (result.exitCode !== 0) {
    throw new Error(`Command failed: ${command.join(" ")}\n${result.stdout}${result.stderr}`.trim());
  }
  return result;
}

function ensureContainerRunning(name) {
  const result = runResult(["sudo", "docker", "inspect", "--format", "{{.State.Running}}", name]);
  if (result.exitCode !== 0 || !result.stdout.trim().includes("true")) {
    throw new Error(`Container ${name} is not running. Start it before running container tests.`);
  }
}

function ensureHostPortOpen(host, port) {
  const result = runResult(["nc", "-z", host, String(port)]);
  if (result.exitCode !== 0) {
    throw new Error(`Port ${port} on ${host} is not reachable. Ensure the Redis container exposes host port ${port} (e.g., -p ${port}:${port}).`);
  }
}

// Run redis-cli inside the container
function redisCli(...args) {
  const result = Bun.spawnSync(
    ["sudo", "docker", "exec", "-i", REDIS_CONTAINER, "redis-cli", ...args],
    { stdout: "pipe", stderr: "pipe" }
  );
  const stdout = result.stdout ? Buffer.from(result.stdout).toString().trim() : "";
  const stderr = result.stderr ? Buffer.from(result.stderr).toString().trim() : "";
  if (result.exitCode !== 0) {
    throw new Error(`redis-cli failed: ${args.join(" ")}\n${stdout}${stderr}`);
  }
  return stdout;
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("redis module - real Redis integration", () => {
  beforeAll(async () => {
    ensureContainerRunning(REDIS_CONTAINER);
    ensureHostPortOpen("127.0.0.1", 6379);

    // Flush all keys to start clean
    redisCli("FLUSHALL");

    // Pre-populate test data
    redisCli("SET", "test-key", "test-value");
    redisCli("SET", "get/mykey", "hello-world");
    redisCli("SET", "get/counter", "42");
    redisCli("SET", "get/json-data", '{"name":"test","count":123}');

    await startNginz(`tests/${MODULE}/nginx.container.conf`, MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  }, 30000);

  // =========================================================================
  // Redis GET Operations
  // =========================================================================

  test("gets value using URI as key", async () => {
    const res = await fetchClose(`${TEST_URL}/get/mykey`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe("hello-world");
  });

  test("gets value using static key directive", async () => {
    const res = await fetchClose(`${TEST_URL}/static-key`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe("test-value");
  });

  test("returns null for non-existent key", async () => {
    const res = await fetchClose(`${TEST_URL}/get/nonexistent-key`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(null);
  });

  test("handles JSON value stored in Redis", async () => {
    const res = await fetchClose(`${TEST_URL}/get/json-data`);
    expect(res.status).toBe(200);

    const body = await res.json();
    // Value is returned as string (not parsed JSON)
    expect(body.value).toBe('{"name":"test","count":123}');
  });

  test("handles numeric value stored in Redis", async () => {
    const res = await fetchClose(`${TEST_URL}/get/counter`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe("42");
  });

  test("escapes special characters in JSON string responses", async () => {
    const rawValue = 'quote" slash\\ newline\n tab\t carriage\r';
    redisCli("SET", "get/escaped", rawValue);

    const res = await fetchClose(`${TEST_URL}/get/escaped`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(rawValue);
  });

  // =========================================================================
  // Redis SET Operations
  // =========================================================================

  test("sets a value and returns ok", async () => {
    const res = await fetchClose(`${TEST_URL}/set/newkey`, {
      method: "POST",
      body: "new-value",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.ok).toBe(true);

    // Verify value was stored in real Redis
    const redisVal = redisCli("GET", "set/newkey");
    expect(redisVal).toBe("new-value");
  });

  test("overwrites existing value", async () => {
    redisCli("SET", "set/existing", "old-value");

    const res = await fetchClose(`${TEST_URL}/set/existing`, {
      method: "POST",
      body: "updated-value",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);

    const redisVal = redisCli("GET", "set/existing");
    expect(redisVal).toBe("updated-value");
  });

  test("stores request bodies with special characters intact", async () => {
    const rawValue = 'value with "quotes", slash\\, and\nnewlines';

    const res = await fetchClose(`${TEST_URL}/set/escaped-body`, {
      method: "POST",
      body: rawValue,
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);

    const redisVal = redisCli("GET", "set/escaped-body");
    expect(redisVal).toBe(rawValue);
  });

  test("rejects GET method for SET command", async () => {
    const res = await fetchClose(`${TEST_URL}/set/testkey`);
    expect(res.status).toBe(405);
  });

  test("rejects empty body for SET", async () => {
    const res = await fetchClose(`${TEST_URL}/set/emptykey`, {
      method: "POST",
      body: "",
    });
    expect(res.status).toBe(400);
  });

  // =========================================================================
  // Redis DEL Operations
  // =========================================================================

  test("deletes existing key and returns count", async () => {
    redisCli("SET", "del/deletekey", "to-delete");

    const res = await fetchClose(`${TEST_URL}/del/deletekey`, {
      method: "POST",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(1); // 1 key deleted

    // Verify key was deleted in real Redis
    const exists = redisCli("EXISTS", "del/deletekey");
    expect(exists).toBe("0"); // 0 = does not exist
  });

  test("returns 0 for non-existent key", async () => {
    const res = await fetchClose(`${TEST_URL}/del/nonexistent`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("accepts DELETE method", async () => {
    redisCli("SET", "del/deletemethod", "delete-me");

    const res = await fetchClose(`${TEST_URL}/del/deletemethod`, {
      method: "DELETE",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);

    const exists = redisCli("EXISTS", "del/deletemethod");
    expect(exists).toBe("0"); // 0 = does not exist
  });

  // =========================================================================
  // Redis INCR Operations
  // =========================================================================

  test("increments existing numeric key", async () => {
    redisCli("SET", "incr/counter", "10");

    const res = await fetchClose(`${TEST_URL}/incr/counter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(11);

    const redisVal = redisCli("GET", "incr/counter");
    expect(redisVal).toBe("11");
  });

  test("creates key with value 1 if not exists", async () => {
    // Ensure key doesn't exist
    redisCli("DEL", "incr/newcounter");

    const res = await fetchClose(`${TEST_URL}/incr/newcounter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);

    const redisVal = redisCli("GET", "incr/newcounter");
    expect(redisVal).toBe("1");
  });

  test("rejects GET method for INCR command", async () => {
    const res = await fetchClose(`${TEST_URL}/incr/counter`);
    expect(res.status).toBe(405);
  });

  test("returns redis_error for non-numeric INCR target", async () => {
    redisCli("SET", "incr/not-a-number", "abc");

    const res = await fetchClose(`${TEST_URL}/incr/not-a-number`, {
      method: "POST",
    });
    expect(res.status).toBe(500);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body).toEqual({ error: "redis_error" });
  });

  // =========================================================================
  // Redis EXPIRE Operations
  // =========================================================================

  test("sets expiration on existing key", async () => {
    redisCli("SET", "expire/tempkey", "temporary");

    const res = await fetchClose(`${TEST_URL}/expire/tempkey`, {
      method: "POST",
      body: "3600", // 1 hour in seconds
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(1); // Success

    // Verify TTL is set (> 0)
    const ttl = redisCli("TTL", "expire/tempkey");
    expect(Number(ttl)).toBeGreaterThan(0);
  });

  test("returns 0 for non-existent key", async () => {
    const res = await fetchClose(`${TEST_URL}/expire/nonexistent`, {
      method: "POST",
      body: "60",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("uses default TTL if body is empty", async () => {
    redisCli("SET", "expire/defaultttl", "default-ttl-test");

    const res = await fetchClose(`${TEST_URL}/expire/defaultttl`, {
      method: "POST",
      body: "",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);

    // Verify TTL is set to 60 seconds
    const ttl = redisCli("TTL", "expire/defaultttl");
    expect(Number(ttl)).toBeGreaterThan(0);
    expect(Number(ttl)).toBeLessThanOrEqual(60);
  });

  test("returns redis_error for invalid TTL body", async () => {
    redisCli("SET", "expire/badttl", "still-here");

    const res = await fetchClose(`${TEST_URL}/expire/badttl`, {
      method: "POST",
      body: "not-a-number",
    });
    expect(res.status).toBe(500);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body).toEqual({ error: "redis_error" });
  });

  // =========================================================================
  // Redis MGET Operations
  // =========================================================================

  test("gets multiple values with query string", async () => {
    redisCli("SET", "key1", "value1");
    redisCli("SET", "key2", "value2");
    redisCli("SET", "key3", "value3");

    const res = await fetchClose(`${TEST_URL}/mget?keys=key1,key2,key3`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.values).toEqual(["value1", "value2", "value3"]);
  });

  test("returns null for missing keys in array", async () => {
    redisCli("SET", "exists1", "exists-value");
    redisCli("DEL", "missing2"); // Ensure it doesn't exist
    redisCli("SET", "exists3", "exists-value-3");

    const res = await fetchClose(`${TEST_URL}/mget?keys=exists1,missing2,exists3`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toEqual(["exists-value", null, "exists-value-3"]);
  });

  test("handles single key in query string", async () => {
    redisCli("SET", "singlekey", "single-value");

    const res = await fetchClose(`${TEST_URL}/mget?keys=singlekey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toEqual(["single-value"]);
  });

  test("stops parsing MGET keys at the next query parameter", async () => {
    redisCli("SET", "amp1", "value-1");
    redisCli("SET", "amp2", "value-2");

    const res = await fetchClose(`${TEST_URL}/mget?keys=amp1,amp2&ignored=1`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toEqual(["value-1", "value-2"]);
  });

  test("caps MGET to 16 keys", async () => {
    const keys = Array.from({ length: 17 }, (_, i) => `limit-key-${i + 1}`);
    keys.forEach((key) => redisCli("SET", key, `value-${key}`));

    const res = await fetchClose(`${TEST_URL}/mget?keys=${keys.join(",")}`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toHaveLength(16);
    expect(body.values[0]).toBe("value-limit-key-1");
    expect(body.values[15]).toBe("value-limit-key-16");
  });

  // =========================================================================
  // Redis DECR Operations
  // =========================================================================

  test("decrements existing numeric key", async () => {
    redisCli("SET", "decr/counter", "10");

    const res = await fetchClose(`${TEST_URL}/decr/counter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(9);

    const redisVal = redisCli("GET", "decr/counter");
    expect(redisVal).toBe("9");
  });

  test("creates key with value -1 if not exists", async () => {
    redisCli("DEL", "decr/newcounter");

    const res = await fetchClose(`${TEST_URL}/decr/newcounter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(-1);

    const redisVal = redisCli("GET", "decr/newcounter");
    expect(redisVal).toBe("-1");
  });

  test("rejects GET method for DECR command", async () => {
    const res = await fetchClose(`${TEST_URL}/decr/counter`);
    expect(res.status).toBe(405);
  });

  test("returns redis_error for non-numeric DECR target", async () => {
    redisCli("SET", "decr/not-a-number", "abc");

    const res = await fetchClose(`${TEST_URL}/decr/not-a-number`, {
      method: "POST",
    });
    expect(res.status).toBe(500);

    const body = await res.json();
    expect(body).toEqual({ error: "redis_error" });
  });

  // =========================================================================
  // Redis EXISTS Operations
  // =========================================================================

  test("returns 1 for existing key", async () => {
    redisCli("SET", "exists/haskey", "some-value");

    const res = await fetchClose(`${TEST_URL}/exists/haskey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
  });

  test("returns 0 for non-existent key", async () => {
    redisCli("DEL", "exists/nokey");

    const res = await fetchClose(`${TEST_URL}/exists/nokey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("rejects POST method for EXISTS command", async () => {
    const res = await fetchClose(`${TEST_URL}/exists/somekey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });

  // =========================================================================
  // Redis TTL Operations
  // =========================================================================

  test("returns -1 for key without expiry", async () => {
    redisCli("SET", "ttl/noexpiry", "persistent");
    redisCli("PERSIST", "ttl/noexpiry");

    const res = await fetchClose(`${TEST_URL}/ttl/noexpiry`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(-1);
  });

  test("returns -2 for non-existent key", async () => {
    redisCli("DEL", "ttl/nokey");

    const res = await fetchClose(`${TEST_URL}/ttl/nokey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(-2);
  });

  test("returns positive TTL for key with expiry", async () => {
    redisCli("SET", "ttl/withttl", "expires");
    redisCli("EXPIRE", "ttl/withttl", "300");

    const res = await fetchClose(`${TEST_URL}/ttl/withttl`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBeGreaterThan(0);
    expect(body.value).toBeLessThanOrEqual(300);
  });

  test("rejects POST method for TTL command", async () => {
    const res = await fetchClose(`${TEST_URL}/ttl/somekey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });

  // =========================================================================
  // Redis PING Operations
  // =========================================================================

  test("returns ok for PING", async () => {
    const res = await fetchClose(`${TEST_URL}/ping`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);
  });

  // =========================================================================
  // Redis STRLEN Operations
  // =========================================================================

  test("returns length of string value", async () => {
    redisCli("SET", "strlen/mystr", "hello");

    const res = await fetchClose(`${TEST_URL}/strlen/mystr`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(5);
  });

  test("returns 0 for non-existent key", async () => {
    redisCli("DEL", "strlen/nokey");

    const res = await fetchClose(`${TEST_URL}/strlen/nokey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("rejects POST method for STRLEN command", async () => {
    const res = await fetchClose(`${TEST_URL}/strlen/somekey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });

  // =========================================================================
  // Redis HGET Operations
  // =========================================================================

  test("gets a hash field value", async () => {
    redisCli("HSET", "hget/myhash", "name", "Alice");
    redisCli("HSET", "hget/myhash", "age", "30");

    const res = await fetchClose(`${TEST_URL}/hget/myhash?field=name`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe("Alice");
  });

  test("returns null for missing field", async () => {
    redisCli("HSET", "hget/myhash", "name", "Alice");

    const res = await fetchClose(`${TEST_URL}/hget/myhash?field=missing`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(null);
  });

  test("returns null for non-existent hash key", async () => {
    redisCli("DEL", "hget/nokey");

    const res = await fetchClose(`${TEST_URL}/hget/nokey?field=name`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(null);
  });

  test("returns 400 when field parameter is missing", async () => {
    const res = await fetchClose(`${TEST_URL}/hget/myhash`);
    expect(res.status).toBe(400);
  });

  test("rejects POST method for HGET command", async () => {
    const res = await fetchClose(`${TEST_URL}/hget/myhash?field=name`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });

  // =========================================================================
  // Redis HSET Operations
  // =========================================================================

  test("sets a hash field and returns 1 for new field", async () => {
    redisCli("HSET", "hset/myhash", "existing", "old");

    const res = await fetchClose(`${TEST_URL}/hset/myhash?field=newfield`, {
      method: "POST",
      body: "new-value",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1); // new field created

    // Verify via redis-cli
    const redisVal = redisCli("HGET", "hset/myhash", "newfield");
    expect(redisVal).toBe("new-value");
  });

  test("returns 0 for existing field", async () => {
    redisCli("HSET", "hset/myhash", "field1", "val1");

    const res = await fetchClose(`${TEST_URL}/hset/myhash?field=field1`, {
      method: "POST",
      body: "updated",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0); // field already existed

    const redisVal = redisCli("HGET", "hset/myhash", "field1");
    expect(redisVal).toBe("updated");
  });

  test("rejects GET method for HSET command", async () => {
    const res = await fetchClose(`${TEST_URL}/hset/myhash?field=f`);
    expect(res.status).toBe(405);
  });

  test("rejects empty body for HSET", async () => {
    const res = await fetchClose(`${TEST_URL}/hset/myhash?field=f`, {
      method: "POST",
      body: "",
    });
    expect(res.status).toBe(400);
  });

  test("returns 400 when field parameter is missing", async () => {
    const res = await fetchClose(`${TEST_URL}/hset/myhash`, {
      method: "POST",
      body: "value",
    });
    expect(res.status).toBe(400);
  });

  // =========================================================================
  // Redis HDEL Operations
  // =========================================================================

  test("deletes a hash field and returns 1", async () => {
    redisCli("HSET", "hdel/myhash", "field1", "val1");
    redisCli("HSET", "hdel/myhash", "field2", "val2");

    const res = await fetchClose(`${TEST_URL}/hdel/myhash?field=field1`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);

    // Verify field was removed but other remains
    const deletedVal = redisCli("HGET", "hdel/myhash", "field1");
    expect(deletedVal).toBe("");
    const keptVal = redisCli("HGET", "hdel/myhash", "field2");
    expect(keptVal).toBe("val2");
  });

  test("returns 0 for non-existent field", async () => {
    redisCli("HSET", "hdel/myhash", "field1", "val1");

    const res = await fetchClose(`${TEST_URL}/hdel/myhash?field=missing`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("returns 0 for non-existent hash key", async () => {
    redisCli("DEL", "hdel/nokey");

    const res = await fetchClose(`${TEST_URL}/hdel/nokey?field=f`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("accepts DELETE method for HDEL", async () => {
    redisCli("HSET", "hdel/myhash", "field1", "val1");

    const res = await fetchClose(`${TEST_URL}/hdel/myhash?field=field1`, {
      method: "DELETE",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
  });

  test("returns 400 when field parameter is missing", async () => {
    const res = await fetchClose(`${TEST_URL}/hdel/myhash`, {
      method: "POST",
    });
    expect(res.status).toBe(400);
  });

  // =========================================================================
  // Redis Error Handling
  // =========================================================================

  test("rejects non-GET HTTP methods for GET command", async () => {
    const res = await fetchClose(`${TEST_URL}/get/mykey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });

  // =========================================================================
  // Regular endpoints still work
  // =========================================================================

  test("non-redis location returns content", async () => {
    const res = await fetchClose(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("Hello World");
  });
});
