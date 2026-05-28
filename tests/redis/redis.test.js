import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  ensureBuild,
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createRedisMock,
  MOCK_PORTS,
} from "../harness.js";

const MODULE_NAME = "redis";
let redisMock;

beforeAll(async () => {
  ensureBuild();

  // Start Redis mock on test port
  redisMock = createRedisMock(MOCK_PORTS.REDIS);

  // Pre-populate some test data
  // Keys must match the full URI path (without leading slash)
  redisMock.setValue("test-key", "test-value");
  redisMock.setValue("get/mykey", "hello-world");
  redisMock.setValue("get/counter", "42");
  redisMock.setValue("get/json-data", '{"name":"test","count":123}');

  await startNginz(`tests/${MODULE_NAME}/nginx.conf`, MODULE_NAME);
});

afterAll(async () => {
  await stopNginz();
  if (redisMock) {
    redisMock.stop();
  }
  cleanupRuntime(MODULE_NAME);
});

describe("Redis GET Operations", () => {
  test("gets value using URI as key", async () => {
    const res = await fetch(`${TEST_URL}/get/mykey`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe("hello-world");
  });

  test("gets value using static key directive", async () => {
    const res = await fetch(`${TEST_URL}/static-key`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe("test-value");
  });

  test("returns null for non-existent key", async () => {
    const res = await fetch(`${TEST_URL}/get/nonexistent-key`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(null);
  });

  test("handles JSON value stored in Redis", async () => {
    const res = await fetch(`${TEST_URL}/get/json-data`);
    expect(res.status).toBe(200);

    const body = await res.json();
    // Value is returned as string (not parsed JSON)
    expect(body.value).toBe('{"name":"test","count":123}');
  });

  test("handles numeric value stored in Redis", async () => {
    const res = await fetch(`${TEST_URL}/get/counter`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe("42");
  });

  test("escapes special characters in JSON string responses", async () => {
    const rawValue = 'quote" slash\\ newline\n tab\t carriage\r';
    redisMock.setValue("get/escaped", rawValue);

    const res = await fetch(`${TEST_URL}/get/escaped`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(rawValue);
  });

  test("exposes GET hit variables", async () => {
    const res = await fetch(`${TEST_URL}/vars/get-hit`);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-redis-last-value")).toBe("hello-world");
    expect(res.headers.get("x-redis-last-exists")).toBe("1");
    expect(res.headers.get("x-redis-last-error")).toBeNull();
    expect(res.headers.get("x-redis-connection-state")).toBe("connected");
  });

  test("exposes GET miss variables", async () => {
    const res = await fetch(`${TEST_URL}/vars/get-miss`);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-redis-last-value")).toBeNull();
    expect(res.headers.get("x-redis-last-exists")).toBe("0");
    expect(res.headers.get("x-redis-last-error")).toBeNull();
    expect(res.headers.get("x-redis-connection-state")).toBe("connected");
  });
});

describe("Redis SET Operations", () => {
  test("sets a value and returns ok", async () => {
    const res = await fetch(`${TEST_URL}/set/newkey`, {
      method: "POST",
      body: "new-value",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.ok).toBe(true);

    // Verify value was stored
    expect(redisMock.getValue("set/newkey")).toBe("new-value");
  });

  test("overwrites existing value", async () => {
    redisMock.setValue("set/existing", "old-value");

    const res = await fetch(`${TEST_URL}/set/existing`, {
      method: "POST",
      body: "updated-value",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(redisMock.getValue("set/existing")).toBe("updated-value");
  });

  test("stores request bodies with special characters intact", async () => {
    const rawValue = 'value with "quotes", slash\\, and\nnewlines';

    const res = await fetch(`${TEST_URL}/set/escaped-body`, {
      method: "POST",
      body: rawValue,
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(redisMock.getValue("set/escaped-body")).toBe(rawValue);
  });

  test("stores spilled SET request bodies intact", async () => {
    const rawValue = `spill-start-${"x".repeat(8192)}-spill-end`;

    const res = await fetch(`${TEST_URL}/set-spill/spilled-body`, {
      method: "POST",
      body: rawValue,
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);
    expect(redisMock.getValue("set-spill/spilled-body")).toBe(rawValue);
  });

  test("rejects GET method for SET command", async () => {
    const res = await fetch(`${TEST_URL}/set/testkey`);
    expect(res.status).toBe(405);
  });

  test("rejects empty body for SET", async () => {
    const res = await fetch(`${TEST_URL}/set/emptykey`, {
      method: "POST",
      body: "",
    });
    expect(res.status).toBe(400);
  });
});

describe("Redis DEL Operations", () => {
  test("deletes existing key and returns count", async () => {
    redisMock.setValue("del/deletekey", "to-delete");

    const res = await fetch(`${TEST_URL}/del/deletekey`, {
      method: "POST",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(1); // 1 key deleted

    // Verify key was deleted
    expect(redisMock.getValue("del/deletekey")).toBeUndefined();
  });

  test("returns 0 for non-existent key", async () => {
    const res = await fetch(`${TEST_URL}/del/nonexistent`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("accepts DELETE method", async () => {
    redisMock.setValue("del/deletemethod", "delete-me");

    const res = await fetch(`${TEST_URL}/del/deletemethod`, {
      method: "DELETE",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
  });
});

describe("Redis INCR Operations", () => {
  test("increments existing numeric key", async () => {
    redisMock.setValue("incr/counter", "10");

    const res = await fetch(`${TEST_URL}/incr/counter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(11);
    expect(redisMock.getValue("incr/counter")).toBe("11");
  });

  test("creates key with value 1 if not exists", async () => {
    const res = await fetch(`${TEST_URL}/incr/newcounter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
    expect(redisMock.getValue("incr/newcounter")).toBe("1");
  });

  test("rejects GET method for INCR command", async () => {
    const res = await fetch(`${TEST_URL}/incr/counter`);
    expect(res.status).toBe(405);
  });

  test("returns redis_error for non-numeric INCR target", async () => {
    redisMock.setValue("incr/not-a-number", "abc");

    const res = await fetch(`${TEST_URL}/vars/incr-error`, {
      method: "POST",
    });
    expect(res.status).toBe(500);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body).toEqual({ error: "redis_error" });
    expect(res.headers.get("x-redis-last-error")).toBe("redis_error");
    expect(res.headers.get("x-redis-connection-state")).toBe("degraded");
    expect(res.headers.get("x-redis-last-exists")).toBe("0");
  });
});

describe("Redis EXPIRE Operations", () => {
  test("sets expiration on existing key", async () => {
    redisMock.setValue("expire/tempkey", "temporary");

    const res = await fetch(`${TEST_URL}/expire/tempkey`, {
      method: "POST",
      body: "3600", // 1 hour in seconds
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.value).toBe(1); // Success
  });

  test("returns 0 for non-existent key", async () => {
    const res = await fetch(`${TEST_URL}/expire/nonexistent`, {
      method: "POST",
      body: "60",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("uses default TTL if body is empty", async () => {
    redisMock.setValue("expire/defaultttl", "default-ttl-test");

    const res = await fetch(`${TEST_URL}/expire/defaultttl`, {
      method: "POST",
      body: "",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
  });

  test("returns redis_error for invalid TTL body", async () => {
    redisMock.setValue("expire/badttl", "still-here");

    const res = await fetch(`${TEST_URL}/expire/badttl`, {
      method: "POST",
      body: "not-a-number",
    });
    expect(res.status).toBe(500);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body).toEqual({ error: "redis_error" });
  });

  test("parses spilled EXPIRE request bodies intact", async () => {
    redisMock.setValue("expire-spill/ttlkey", "spilled-ttl");

    const res = await fetch(`${TEST_URL}/expire-spill/ttlkey`, {
      method: "POST",
      body: "3600",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
  });
});

describe("Redis MGET Operations", () => {
  test("gets multiple values with query string", async () => {
    redisMock.setValue("key1", "value1");
    redisMock.setValue("key2", "value2");
    redisMock.setValue("key3", "value3");

    const res = await fetch(`${TEST_URL}/mget?keys=key1,key2,key3`);
    expect(res.status).toBe(200);
    expect(res.headers.get("content-type")).toBe("application/json");

    const body = await res.json();
    expect(body.values).toEqual(["value1", "value2", "value3"]);
  });

  test("returns null for missing keys in array", async () => {
    redisMock.setValue("exists1", "exists-value");
    // missing2 doesn't exist
    redisMock.setValue("exists3", "exists-value-3");

    const res = await fetch(`${TEST_URL}/mget?keys=exists1,missing2,exists3`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toEqual(["exists-value", null, "exists-value-3"]);
  });

  test("handles single key in query string", async () => {
    redisMock.setValue("singlekey", "single-value");

    const res = await fetch(`${TEST_URL}/mget?keys=singlekey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toEqual(["single-value"]);
  });

  test("stops parsing MGET keys at the next query parameter", async () => {
    redisMock.setValue("amp1", "value-1");
    redisMock.setValue("amp2", "value-2");

    const res = await fetch(`${TEST_URL}/mget?keys=amp1,amp2&ignored=1`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toEqual(["value-1", "value-2"]);
  });

  test("caps MGET to 16 keys", async () => {
    const keys = Array.from({ length: 17 }, (_, i) => `limit-key-${i + 1}`);
    keys.forEach((key) => redisMock.setValue(key, `value-${key}`));

    const res = await fetch(`${TEST_URL}/mget?keys=${keys.join(",")}`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.values).toHaveLength(16);
    expect(body.values[0]).toBe("value-limit-key-1");
    expect(body.values[15]).toBe("value-limit-key-16");
  });
});

describe("Redis DECR Operations", () => {
  test("decrements existing numeric key", async () => {
    redisMock.setValue("decr/counter", "10");

    const res = await fetch(`${TEST_URL}/decr/counter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(9);
    expect(redisMock.getValue("decr/counter")).toBe("9");
  });

  test("creates key with value -1 if not exists", async () => {
    const res = await fetch(`${TEST_URL}/decr/newcounter`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(-1);
    expect(redisMock.getValue("decr/newcounter")).toBe("-1");
  });

  test("rejects GET method for DECR command", async () => {
    const res = await fetch(`${TEST_URL}/decr/counter`);
    expect(res.status).toBe(405);
  });

  test("returns redis_error for non-numeric DECR target", async () => {
    redisMock.setValue("decr/not-a-number", "abc");

    const res = await fetch(`${TEST_URL}/decr/not-a-number`, {
      method: "POST",
    });
    expect(res.status).toBe(500);

    const body = await res.json();
    expect(body).toEqual({ error: "redis_error" });
  });
});

describe("Redis EXISTS Operations", () => {
  test("returns 1 for existing key", async () => {
    redisMock.setValue("exists/haskey", "some-value");

    const res = await fetch(`${TEST_URL}/exists/haskey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
  });

  test("returns 0 for non-existent key", async () => {
    const res = await fetch(`${TEST_URL}/exists/nokey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("rejects POST method for EXISTS command", async () => {
    const res = await fetch(`${TEST_URL}/exists/somekey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });
});

describe("Redis TTL Operations", () => {
  test("returns -1 for key without expiry", async () => {
    redisMock.setValue("ttl/noexpiry", "persistent");

    const res = await fetch(`${TEST_URL}/ttl/noexpiry`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(-1);
  });

  test("returns -2 for non-existent key", async () => {
    const res = await fetch(`${TEST_URL}/ttl/nokey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(-2);
  });

  test("rejects POST method for TTL command", async () => {
    const res = await fetch(`${TEST_URL}/ttl/somekey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });
});

describe("Redis PING Operations", () => {
  test("returns ok for PING", async () => {
    const res = await fetch(`${TEST_URL}/ping`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.ok).toBe(true);
  });
});

describe("Redis STRLEN Operations", () => {
  test("returns length of string value", async () => {
    redisMock.setValue("strlen/mystr", "hello");

    const res = await fetch(`${TEST_URL}/strlen/mystr`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(5);
  });

  test("returns 0 for non-existent key", async () => {
    const res = await fetch(`${TEST_URL}/strlen/nokey`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("rejects POST method for STRLEN command", async () => {
    const res = await fetch(`${TEST_URL}/strlen/somekey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });
});

describe("Redis HGET Operations", () => {
  test("gets a hash field value", async () => {
    redisMock.setValue("hget/myhash", '{"name":"Alice","age":"30"}');

    const res = await fetch(`${TEST_URL}/hget/myhash?field=name`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe("Alice");
  });

  test("returns null for missing field", async () => {
    redisMock.setValue("hget/myhash", '{"name":"Alice"}');

    const res = await fetch(`${TEST_URL}/hget/myhash?field=missing`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(null);
  });

  test("returns null for non-existent hash key", async () => {
    const res = await fetch(`${TEST_URL}/hget/nokey?field=name`);
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(null);
  });

  test("returns 400 when field parameter is missing", async () => {
    const res = await fetch(`${TEST_URL}/hget/myhash`);
    expect(res.status).toBe(400);
  });

  test("rejects POST method for HGET command", async () => {
    const res = await fetch(`${TEST_URL}/hget/myhash?field=name`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });
});

describe("Redis HSET Operations", () => {
  test("sets a hash field and returns 1 for new field", async () => {
    redisMock.setValue("hset/myhash", '{"existing":"old"}');

    const res = await fetch(`${TEST_URL}/hset/myhash?field=newfield`, {
      method: "POST",
      body: "new-value",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1); // new field created

    // Verify via mock store
    const stored = JSON.parse(redisMock.getValue("hset/myhash"));
    expect(stored.newfield).toBe("new-value");
  });

  test("returns 0 for existing field", async () => {
    redisMock.setValue("hset/myhash", '{"field1":"val1"}');

    const res = await fetch(`${TEST_URL}/hset/myhash?field=field1`, {
      method: "POST",
      body: "updated",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0); // field already existed

    const stored = JSON.parse(redisMock.getValue("hset/myhash"));
    expect(stored.field1).toBe("updated");
  });

  test("rejects GET method for HSET command", async () => {
    const res = await fetch(`${TEST_URL}/hset/myhash?field=f`);
    expect(res.status).toBe(405);
  });

  test("rejects empty body for HSET", async () => {
    const res = await fetch(`${TEST_URL}/hset/myhash?field=f`, {
      method: "POST",
      body: "",
    });
    expect(res.status).toBe(400);
  });

  test("stores spilled HSET request bodies intact", async () => {
    const rawValue = `spill-hset-${"z".repeat(8192)}-tail`;

    const res = await fetch(`${TEST_URL}/hset-spill/myhash?field=large`, {
      method: "POST",
      body: rawValue,
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
    const stored = JSON.parse(redisMock.getValue("hset-spill/myhash"));
    expect(stored.large).toBe(rawValue);
  });

  test("returns 400 when field parameter is missing", async () => {
    const res = await fetch(`${TEST_URL}/hset/myhash`, {
      method: "POST",
      body: "value",
    });
    expect(res.status).toBe(400);
  });
});

describe("Redis HDEL Operations", () => {
  test("deletes a hash field and returns 1", async () => {
    redisMock.setValue("hdel/myhash", '{"field1":"val1","field2":"val2"}');

    const res = await fetch(`${TEST_URL}/hdel/myhash?field=field1`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);

    // Verify field was removed
    const stored = JSON.parse(redisMock.getValue("hdel/myhash"));
    expect(stored.field1).toBeUndefined();
    expect(stored.field2).toBe("val2");
  });

  test("returns 0 for non-existent field", async () => {
    redisMock.setValue("hdel/myhash", '{"field1":"val1"}');

    const res = await fetch(`${TEST_URL}/hdel/myhash?field=missing`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("returns 0 for non-existent hash key", async () => {
    const res = await fetch(`${TEST_URL}/hdel/nokey?field=f`, {
      method: "POST",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(0);
  });

  test("accepts DELETE method for HDEL", async () => {
    redisMock.setValue("hdel/myhash", '{"field1":"val1"}');

    const res = await fetch(`${TEST_URL}/hdel/myhash?field=field1`, {
      method: "DELETE",
    });
    expect(res.status).toBe(200);

    const body = await res.json();
    expect(body.value).toBe(1);
  });

  test("returns 400 when field parameter is missing", async () => {
    const res = await fetch(`${TEST_URL}/hdel/myhash`, {
      method: "POST",
    });
    expect(res.status).toBe(400);
  });
});

describe("Redis Error Handling", () => {
  test("rejects non-GET HTTP methods for GET command", async () => {
    const res = await fetch(`${TEST_URL}/get/mykey`, {
      method: "POST",
    });
    expect(res.status).toBe(405);
  });

  test("exposes connection failure variables when upstream is unavailable", async () => {
    const res = await fetch(`${TEST_URL}/vars/down/missing-upstream`);
    expect(res.status).toBe(502);
    expect(res.headers.get("x-redis-last-error")).toBe("connection_failed");
    expect(res.headers.get("x-redis-connection-state")).toBe("error");
    expect(res.headers.get("x-redis-last-value")).toBeNull();
  });
});

describe("Regular endpoints still work", () => {
  test("non-redis location returns content", async () => {
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("Hello World");
  });
});
