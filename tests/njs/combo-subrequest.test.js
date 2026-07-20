import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createRedisMock,
  createPostgresMock,
  MOCK_PORTS,
  teardownModule,
  prepareMockPorts,
  testFetch,
} from "../harness.js";

const MODULE = "njs";
let redisMock;
let pgMock;



describe("njs combo subrequest", () => {
  beforeAll(async () => {
    await prepareMockPorts(MOCK_PORTS.REDIS, MOCK_PORTS.POSTGRES);
    redisMock = createRedisMock(MOCK_PORTS.REDIS);
    pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);

    // ── Redis pre-populated data ────────────────────────────────────────
    redisMock.setValue("_redis/get/cached-users",
      JSON.stringify([{ id: 99, name: "Cached-Alice" }]));

    // TTL-aware: key at both GET and TTL prefixes
    redisMock.setValue("_redis/get/ttl-cached", "ttl-cached-value");
    redisMock.setValue("_redis/ttl/ttl-cached", "ttl-cached-value");

    // DEL + refresh: stale cache to delete
    redisMock.setValue("_redis/del/stale-cache", "old-data");
    redisMock.setValue("_redis/set/stale-cache", "old-data");

    // DECR rate gate: pre-set counter
    redisMock.setValue("_redis/decr/rate-limit", "3");

    // Hash config
    redisMock.setValue("_redis/hget/query-config",
      JSON.stringify({ select: "id,name" }));

    // MGET batch: pre-populate some keys
    redisMock.setValue("m1", "val1");
    redisMock.setValue("m3", "val3");

    // EXISTS guard
    redisMock.setValue("_redis/exists/guard-key", "present");

    // STRLEN: short value at strlen prefix for STRLEN check, and shared-key for read-back
    redisMock.setValue("_redis/strlen/str-cached", "short");
    redisMock.setValue("str-data", "short"); // shared key for str_set/str_get

    // ── PGrest mock handlers ───────────────────────────────────────────
    pgMock.setQueryHandler(/users/i, (query) => {
      if (/SELECT.*count\(\*\)/i.test(query)) return { columns: ["count"], rows: [["3"]] };
      if (/INSERT/i.test(query)) return { columns: [], rows: [] };
      return {
        columns: ["id", "name", "email", "status"],
        rows: [
          ["1", "Alice", "alice@test.com", "active"],
          ["2", "Bob", "bob@test.com", "active"],
          ["3", "Carol", "carol@test.com", "inactive"],
        ],
      };
    });
    pgMock.setQueryHandler(/pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i, () => ({
      columns: ["dummy"], rows: [],
    }));
    pgMock.setQueryHandler(/^SET\s|^RESET\s/i, () => ({ columns: [], rows: [] }));

    await startNginz("tests/njs/combo-subrequest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await teardownModule(MODULE, [redisMock, pgMock], [MOCK_PORTS.REDIS, MOCK_PORTS.POSTGRES]);
  });

  // =========================================================================
  // Existing combos
  // =========================================================================

  describe("redis write-then-read", () => {
    test("SET then GET returns the same value", async () => {
      const res = await testFetch(`/combo/redis-write-read`, {
        method: "POST", body: "hello-from-combo",
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.set.ok).toBe(true);
      expect(body.get.value).toBe("hello-from-combo");
    });
  });

  test("redis INCR twice", async () => {
    const res = await testFetch(`/combo/redis-incr-twice?key=incr-seq`, { method: "POST" });
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.first).toBe(1);
    expect(body.second).toBe(2);
  });

  test("redis + pgrest parallel", async () => {
    const res = await testFetch(`/combo/redis-pgrest-parallel?rkey=cached-users`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(JSON.parse(body.redis_value)[0].name).toBe("Cached-Alice");
    expect(body.pgrest_user_count).toBe(3);
  });

  test("conditional: cache HIT", async () => {
    const res = await testFetch(`/combo/conditional?key=cached-users`);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-cache")).toBe("HIT");
  });

  test("conditional: cache MISS → PGrest", async () => {
    const res = await testFetch(`/combo/conditional?key=no-such-cache`);
    expect(res.status).toBe(200);
    expect(res.headers.get("x-cache")).toBe("MISS");
    const body = await res.json();
    expect(body.user_count).toBe(3);
  });

  describe("read-through cache", () => {
    test("MISS → PGrest → caches in Redis", async () => {
      const res = await testFetch(`/combo/read-through?key=read-through-test`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-cache")).toBe("MISS");
      const body = await res.json();
      expect(body.source).toBe("pgrest");
      expect(body.user_count).toBe(3);
      const cached = JSON.parse(redisMock.getValue("cache-data"));
      expect(Array.isArray(cached)).toBe(true);
    });
  });

  describe("counter + data", () => {
    test("INCR + PGrest GET", async () => {
      const r1 = await testFetch(`/combo/counter-and-data?ckey=hits-2`);
      const b1 = await r1.json();
      expect(b1.hit_count).toBe(1);
      expect(b1.user_count).toBe(3);

      const r2 = await testFetch(`/combo/counter-and-data?ckey=hits-2`);
      const b2 = await r2.json();
      expect(b2.hit_count).toBe(2);
    });
  });

  // =========================================================================
  // New combos
  // =========================================================================

  // 1. TTL-aware refresh
  describe("TTL-aware refresh", () => {
    test("reports TTL and current value", async () => {
      const res = await testFetch(`/combo/ttl-refresh?key=ttl-cached`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.value).toBe("ttl-cached-value");
      // Mock returns -1 for keys without expiry
      expect(body.ttl).toBe(-1);
      // TTL > 10 so no refresh
      expect(body.refreshed).toBe(false);
    });
  });

  // 2. DEL + refresh
  describe("DEL + refresh", () => {
    test("deletes old cache and refreshes from PGrest", async () => {
      const res = await testFetch(`/combo/del-refresh?key=stale-cache`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.deleted).toBe(1);
      expect(body.user_count).toBe(3);
      // Verify new cache was written
      expect(redisMock.getValue("_redis/set/stale-cache")).toBeTruthy();
    });
  });

  // 3. DECR rate gate
  describe("DECR rate gate", () => {
    test("allows request when quota remains", async () => {
      // Pre-set to 3, first DECR → 2, second → 1, third → 0, fourth → -1 (blocked)
      const r1 = await testFetch(`/combo/decr-gate?key=rate-limit`, { method: "POST" });
      const b1 = await r1.json();
      expect(b1.allowed).toBe(true);
      expect(b1.remaining).toBe(2);
      expect(b1.user_count).toBe(3);
    });

    test("blocks request when quota exhausted", async () => {
      // After previous test: counter is at 2. DECR three more times.
      await testFetch(`/combo/decr-gate?key=rate-limit`, { method: "POST" }); // → 1
      await testFetch(`/combo/decr-gate?key=rate-limit`, { method: "POST" }); // → 0
      const blocked = await testFetch(`/combo/decr-gate?key=rate-limit`, { method: "POST" }); // → -1
      expect(blocked.status).toBe(429);
      const body = await blocked.json();
      expect(body.error).toBe("rate_limited");
    });
  });

  // 4. Hash config → PGrest query
  describe("hash config query", () => {
    test("uses hash field to parametrize PGrest select", async () => {
      const res = await testFetch(`/combo/hash-config?hkey=query-config`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.config_select).toBe("id,name");
      expect(Array.isArray(body.result)).toBe(true);
      if (body.result.length > 0) {
        // Should only have id and name (not email/status)
        expect(body.result[0]).toHaveProperty("id");
        expect(body.result[0]).toHaveProperty("name");
      }
    });
  });

  // 5. MGET batch + PGrest fallback
  describe("MGET batch fallback", () => {
    test("MGETs multiple keys and reports hits/misses", async () => {
      const res = await testFetch(`/combo/mget-fallback?keys=m1,m2,m3`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.mget_values).toEqual(["val1", null, "val3"]);
      expect(body.cache_hits).toBe(2);
      expect(body.cache_misses).toBe(1);
      expect(body.pgrest_fallback).toBe(true);
      expect(body.pgrest_count).toBe(3);
    });
  });

  // 6. EXISTS guard → PGrest write
  describe("EXISTS guard", () => {
    test("allows write when guard key exists", async () => {
      const res = await testFetch(`/combo/exists-guard?key=guard-key`, {
        method: "POST",
        body: JSON.stringify({ name: "Guard-User", email: "guard@test.com" }),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.guard_ok).toBe(true);
      expect(body.post_status === 201 || body.post_status === 200).toBe(true);
    });

    test("denies write when guard key is missing", async () => {
      const res = await testFetch(`/combo/exists-guard?key=no-guard`, {
        method: "POST",
        body: "{}",
      });
      expect(res.status).toBe(403);
      const body = await res.json();
      expect(body.error).toBe("guard_key_missing");
    });
  });

  // 7. PING health → PGrest
  describe("PING health gate", () => {
    test("queries PGrest when Redis is healthy", async () => {
      const res = await testFetch(`/combo/ping-gate`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.redis_healthy).toBe(true);
      expect(body.user_count).toBe(3);
    });
  });

  // 8. STRLEN validation → refresh if short
  describe("STRLEN validation", () => {
    test("refreshes from PGrest when cached value is too short", async () => {
      // Ensure shared key starts short
      redisMock.setValue("str-data", "short");
      redisMock.setValue("_redis/strlen/str-cached", "short");

      const res = await testFetch(`/combo/strlen-refresh?key=str-cached`);
      expect(res.status).toBe(200);
      const body = await res.json();
      // "short" has length 5 < 10, so refresh should trigger
      expect(body.strlen).toBe(5);
      expect(body.refreshed).toBe(true);
      // Shared key str-data should now contain PGrest JSON
      expect(body.value).toBeTruthy();
      const refreshedValue = JSON.parse(body.value);
      expect(Array.isArray(refreshedValue)).toBe(true);
    });
  });
});
