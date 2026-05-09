import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL, createRedisMock, MOCK_PORTS } from "../harness.js";

const MODULE = "njs";
let redisMock;

describe("njs redis subrequest", () => {
  beforeAll(async () => {
    redisMock = createRedisMock(MOCK_PORTS.REDIS);

    // Pre-populate keys (keys include internal location prefix)
    redisMock.setValue("_redis/get/mykey", "hello-from-redis");
    redisMock.setValue("_redis/get/p1", "parallel-one");
    redisMock.setValue("_redis/get/p2", "parallel-two");
    redisMock.setValue("m1", "val1");
    redisMock.setValue("m2", "val2");
    redisMock.setValue("_redis/exists/yes-key", "present");
    redisMock.setValue("_redis/ttl/persistent-key", "forever");
    redisMock.setValue("_redis/strlen/hello-key", "hello");
    redisMock.setValue("_redis/hget/h1", JSON.stringify({ name: "Alice", age: "30" }));

    await startNginz("tests/njs/redis-subrequest.conf", MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    redisMock?.stop();
  });

  // =========================================================================
  // GET
  // =========================================================================

  describe("subrequest GET", () => {
    test("retrieves pre-populated value", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/get?key=mykey`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe("hello-from-redis");
    });

    test("returns null for missing key", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/get?key=nope`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(null);
    });
  });

  // =========================================================================
  // SET
  // =========================================================================

  describe("subrequest SET", () => {
    test("writes value and returns ok", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/set?key=write-me`, {
        method: "POST",
        body: "subrequest-value",
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);
      // verify via mock
      expect(redisMock.getValue("_redis/set/write-me")).toBe("subrequest-value");
    });

    test("preserves special characters", async () => {
      const raw = 'quotes " and\nnewlines';
      const res = await fetch(`${TEST_URL}/njs/redis/set?key=special`, {
        method: "POST",
        body: raw,
      });
      expect(res.status).toBe(200);
      expect(redisMock.getValue("_redis/set/special")).toBe(raw);
    });
  });

  // =========================================================================
  // DEL
  // =========================================================================

  describe("subrequest DEL", () => {
    test("deletes a key and returns count", async () => {
      redisMock.setValue("_redis/del/remove-me", "temp");
      const res = await fetch(`${TEST_URL}/njs/redis/del?key=remove-me`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(1);
      expect(redisMock.getValue("_redis/del/remove-me")).toBeUndefined();
    });

    test("returns 0 for non-existent key", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/del?key=no-such`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(0);
    });
  });

  // =========================================================================
  // INCR
  // =========================================================================

  describe("subrequest INCR", () => {
    test("creates key with value 1", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/incr?key=fresh`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(1);
      expect(redisMock.getValue("_redis/incr/fresh")).toBe("1");
    });

    test("increments existing key", async () => {
      redisMock.setValue("_redis/incr/count", "5");
      const res = await fetch(`${TEST_URL}/njs/redis/incr?key=count`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(6);
      expect(redisMock.getValue("_redis/incr/count")).toBe("6");
    });
  });

  // =========================================================================
  // DECR
  // =========================================================================

  describe("subrequest DECR", () => {
    test("creates key with value -1", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/decr?key=fresh`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(-1);
      expect(redisMock.getValue("_redis/decr/fresh")).toBe("-1");
    });

    test("decrements existing key", async () => {
      redisMock.setValue("_redis/decr/count", "10");
      const res = await fetch(`${TEST_URL}/njs/redis/decr?key=count`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(9);
      expect(redisMock.getValue("_redis/decr/count")).toBe("9");
    });
  });

  // =========================================================================
  // EXISTS
  // =========================================================================

  describe("subrequest EXISTS", () => {
    test("returns 1 for existing key", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/exists?key=yes-key`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(1);
    });

    test("returns 0 for missing key", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/exists?key=no-key`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(0);
    });
  });

  // =========================================================================
  // TTL
  // =========================================================================

  describe("subrequest TTL", () => {
    test("returns -1 for persistent key", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/ttl?key=persistent-key`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(-1);
    });

    test("returns -2 for missing key", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/ttl?key=ghost`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(-2);
    });
  });

  // =========================================================================
  // PING
  // =========================================================================

  describe("subrequest PING", () => {
    test("returns ok", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/ping`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.ok).toBe(true);
    });
  });

  // =========================================================================
  // STRLEN
  // =========================================================================

  describe("subrequest STRLEN", () => {
    test("returns length of value", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/strlen?key=hello-key`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(5);
    });

    test("returns 0 for missing key", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/strlen?key=nope`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(0);
    });
  });

  // =========================================================================
  // MGET
  // =========================================================================

  describe("subrequest MGET", () => {
    test("fetches multiple keys via query string", async () => {
      redisMock.setValue("m1", "val1");
      redisMock.setValue("m2", "val2");
      const res = await fetch(`${TEST_URL}/njs/redis/mget?keys=m1,m2`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.values).toEqual(["val1", "val2"]);
    });

    test("returns null for missing keys via query string", async () => {
      redisMock.setValue("m1", "val1");
      const res = await fetch(`${TEST_URL}/njs/redis/mget?keys=m1,ghost,m3`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.values).toEqual(["val1", null, null]);
    });
  });

  // =========================================================================
  // Parallel subrequests (Promise.all)
  // =========================================================================

  describe("subrequest parallel", () => {
    test("fetches two keys concurrently", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/parallel?k1=p1&k2=p2`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.k1.value).toBe("parallel-one");
      expect(body.k2.value).toBe("parallel-two");
    });
  });

  // =========================================================================
  // Hash: HGET
  // =========================================================================

  describe("subrequest HGET", () => {
    test("retrieves hash field", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/hget?key=h1&field=name`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe("Alice");
    });

    test("returns null for missing field", async () => {
      const res = await fetch(`${TEST_URL}/njs/redis/hget?key=h1&field=nope`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(null);
    });
  });

  // =========================================================================
  // Hash: HSET
  // =========================================================================

  describe("subrequest HSET", () => {
    test("sets a hash field and returns 1", async () => {
      redisMock.setValue("_redis/hset/h1", '{"existing":"old"}');
      const res = await fetch(`${TEST_URL}/njs/redis/hset?key=h1&field=city`, {
        method: "POST",
        body: "Paris",
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(1);
      // verify via mock
      const stored = JSON.parse(redisMock.getValue("_redis/hset/h1"));
      expect(stored.city).toBe("Paris");
    });

    test("returns 0 for existing field", async () => {
      redisMock.setValue("_redis/hset/h2", '{"f1":"v1"}');
      const res = await fetch(`${TEST_URL}/njs/redis/hset?key=h2&field=f1`, {
        method: "POST",
        body: "updated",
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(0);
      const stored = JSON.parse(redisMock.getValue("_redis/hset/h2"));
      expect(stored.f1).toBe("updated");
    });
  });

  // =========================================================================
  // Hash: HDEL
  // =========================================================================

  describe("subrequest HDEL", () => {
    test("deletes a hash field and returns 1", async () => {
      redisMock.setValue("_redis/hdel/h1", '{"f1":"v1","f2":"v2"}');
      const res = await fetch(`${TEST_URL}/njs/redis/hdel?key=h1&field=f1`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(1);
      const stored = JSON.parse(redisMock.getValue("_redis/hdel/h1"));
      expect(stored.f1).toBeUndefined();
      expect(stored.f2).toBe("v2");
    });

    test("returns 0 for non-existent field", async () => {
      redisMock.setValue("_redis/hdel/h2", '{"f1":"v1"}');
      const res = await fetch(`${TEST_URL}/njs/redis/hdel?key=h2&field=ghost`, { method: "POST" });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe(0);
    });
  });
});
