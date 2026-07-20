import { spawnSync } from "bun";
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { existsSync, mkdirSync, rmSync } from "fs";
import { join } from "path";
import {
  startNginz,
  reloadNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "cache-purge";

function createConfigTestRuntime(name) {
  const runtimeDir = join(process.cwd(), "tests", MODULE, `runtime-${name}`);
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
  mkdirSync(join(runtimeDir, "logs"), { recursive: true });
  return runtimeDir;
}

function cleanupConfigTestRuntime(name) {
  const runtimeDir = join(process.cwd(), "tests", MODULE, `runtime-${name}`);
  if (existsSync(runtimeDir)) {
    rmSync(runtimeDir, { recursive: true });
  }
}

function expectConfigTestFailure(configName, expectedMessage) {
  const runtimeName = `config-${configName.replace(/[^a-z0-9]/gi, "-")}`;
  const runtimeDir = createConfigTestRuntime(runtimeName);

  try {
    const result = spawnSync({
      cmd: [
        "./zig-out/bin/nginz",
        "-t",
        "-c",
        join(process.cwd(), "tests", MODULE, configName),
        "-p",
        runtimeDir,
      ],
      cwd: process.cwd(),
      stdout: "pipe",
      stderr: "pipe",
    });

    const stderr = new TextDecoder().decode(result.stderr ?? new Uint8Array());
    const stdout = new TextDecoder().decode(result.stdout ?? new Uint8Array());
    const output = `${stdout}\n${stderr}`;
    expect(output).toContain("test failed");
    expect(output).toContain(expectedMessage);
  } finally {
    cleanupConfigTestRuntime(runtimeName);
  }
}

async function purge(targets) {
  return fetchClose(`${TEST_URL}/cache-purge`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ targets }),
  });
}

async function getWorkerEvents(channel = "cache", since = null) {
  const params = new URLSearchParams({ channel });
  if (since != null) {
    params.set("since", String(since));
  }
  const res = await fetchClose(`${TEST_URL}/worker-events?${params.toString()}`);
  expect(res.status).toBe(200);
  return res.json();
}

async function waitForWorkerEvents(predicate, channel = "cache", timeout = 4000, since = null) {
  const started = Date.now();

  while (Date.now() - started < timeout) {
    const body = await getWorkerEvents(channel, since);
    if (predicate(body)) {
      return body;
    }
    await Bun.sleep(75);
  }

  throw new Error(`Timed out waiting for worker-events on channel ${channel}`);
}


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("cache-purge Phase 1 - API contract", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("GET returns 405 method not allowed", async () => {
    const res = await fetchClose(`${TEST_URL}/cache-purge`);
    expect(res.status).toBe(405);
    const body = await res.json();
    expect(body.module).toBe("cache_purge");
    expect(body.status).toBe("error");
  });

  test("HEAD returns 405 method not allowed", async () => {
    const res = await fetchClose(`${TEST_URL}/cache-purge`, { method: "HEAD" });
    expect(res.status).toBe(405);
    expect(await res.text()).toBe("");
  });

  test("POST without JSON content-type returns 415", async () => {
    const res = await fetchClose(`${TEST_URL}/cache-purge`, {
      method: "POST",
      body: '{"targets":["tag1"]}',
    });
    expect(res.status).toBe(415);
  });

  test("POST with missing body returns 400", async () => {
    const res = await fetchClose(`${TEST_URL}/cache-purge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.status).toBe("error");
  });

  test("POST with invalid JSON returns 400", async () => {
    const res = await fetchClose(`${TEST_URL}/cache-purge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "not json",
    });
    expect(res.status).toBe(400);
  });

  test("POST with non-array targets returns 400", async () => {
    const res = await fetchClose(`${TEST_URL}/cache-purge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: '{"targets":"user-123"}',
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain("'targets' must be an array");
  });

  test("POST with non-string target item returns 400", async () => {
    const res = await fetchClose(`${TEST_URL}/cache-purge`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ targets: ["user-123", 42] }),
    });
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain("each target must be a non-empty string");
  });

  test("POST with empty target item returns 400", async () => {
    const res = await purge([""]);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain("each target must be a non-empty string");
  });

  test("POST with target longer than 64 chars returns 400", async () => {
    const res = await purge(["x".repeat(65)]);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain("target too long");
  });

  test("POST with too many targets returns 400 (max_keys=4)", async () => {
    const res = await purge(["a", "b", "c", "d", "e"]);
    expect(res.status).toBe(400);
    const body = await res.json();
    expect(body.error).toContain("max_keys");
  });

  test("POST with empty targets array returns 200 with zero counts", async () => {
    const res = await purge([]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.module).toBe("cache_purge");
    expect(body.match).toBe("exact");
    expect(body.requested).toBe(0);
    expect(body.purged).toBe(0);
    expect(body.missing).toBe(0);
    expect(body.rejected).toBe(0);
    expect(Array.isArray(body.results)).toBe(true);
    expect(body.results).toHaveLength(0);
  });
});

describe("cache-purge Phase 1 - config load validation", () => {
  test("cache_purge_api requires cache_purge_zone", () => {
    expectConfigTestFailure(
      "nginx-missing-zone.conf",
      "cache_purge_api requires cache_purge_zone",
    );
  });

  test("cache_purge_zone rejects unsupported names", () => {
    expectConfigTestFailure(
      "nginx-unsupported-zone.conf",
      "cache_purge_zone currently supports only default or cache_tags_zone",
    );
  });

  test("cache_purge_match accepts prefix when configured", () => {
    const runtimeName = "config-prefix-supported";
    const runtimeDir = createConfigTestRuntime(runtimeName);

    try {
      const result = spawnSync({
        cmd: [
          "./zig-out/bin/nginz",
          "-t",
          "-c",
          join(process.cwd(), "tests", MODULE, "nginx-prefix.conf"),
          "-p",
          runtimeDir,
        ],
        cwd: process.cwd(),
        stdout: "pipe",
        stderr: "pipe",
      });

      const stderr = new TextDecoder().decode(result.stderr ?? new Uint8Array());
      const stdout = new TextDecoder().decode(result.stdout ?? new Uint8Array());
      const output = `${stdout}\n${stderr}`;
      expect(result.exitCode).toBe(0);
      expect(output).toContain("test is successful");
    } finally {
      cleanupConfigTestRuntime(runtimeName);
    }
  });

  test("cache_purge_authorize allowlist requires cache_purge_allowlist", () => {
    expectConfigTestFailure(
      "nginx-allowlist-missing.conf",
      "cache_purge_authorize allowlist requires cache_purge_allowlist",
    );
  });

  test("cache_purge_allowlist rejects invalid CIDR entries", () => {
    expectConfigTestFailure(
      "nginx-allowlist-invalid.conf",
      "cache_purge_allowlist entries must be IP or CIDR",
    );
  });

  test("cache_purge_match still rejects unsupported glob mode", () => {
    expectConfigTestFailure(
      "nginx-glob.conf",
      "cache_purge_match glob is not yet implemented; use exact or prefix",
    );
  });
});

describe("cache-purge Phase 2 - Exact invalidation", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("zero-hit purge is non-error with explicit accounting", async () => {
    const res = await purge(["nonexistent-tag"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.physical_cache_invalidated).toBe(false);
    expect(body.requested).toBe(1);
    expect(body.purged).toBe(0);
    expect(body.missing).toBe(1);
    expect(body.rejected).toBe(0);
    expect(body.results).toHaveLength(1);
    expect(body.results[0].target).toBe("nonexistent-tag");
    expect(body.results[0].purged).toBe(0);
  });

  test("purges an existing tag and returns correct counts", async () => {
    // Register tag via cache-tags header filter
    await fetchClose(`${TEST_URL}/api`);

    const res = await purge(["user-123"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(1);
    expect(body.purged).toBeGreaterThan(0);
    expect(body.missing).toBe(0);
    expect(body.results[0].target).toBe("user-123");
    expect(body.results[0].purged).toBeGreaterThan(0);
  });

  test("second purge of same tag is zero-hit (idempotent)", async () => {
    // Tag already purged from previous test — purging again is a non-error zero-hit
    const res = await purge(["user-123"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.purged).toBe(0);
    expect(body.missing).toBe(1);
  });

  test("batch purge with mixed hit/miss targets", async () => {
    // Re-register tag
    await fetchClose(`${TEST_URL}/api`);

    const res = await purge(["user-123", "no-such-tag"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(2);
    expect(body.missing).toBe(1);
    expect(body.results).toHaveLength(2);
  });

  test("re-registers a purged tag and allows it to be purged again", async () => {
    await purge(["user-123"]);

    await fetchClose(`${TEST_URL}/api`);

    const firstPurge = await purge(["user-123"]);
    expect(firstPurge.status).toBe(200);
    const firstBody = await firstPurge.json();
    expect(firstBody.requested).toBe(1);
    expect(firstBody.purged).toBeGreaterThan(0);
    expect(firstBody.missing).toBe(0);

    await fetchClose(`${TEST_URL}/api`);

    const secondPurge = await purge(["user-123"]);
    expect(secondPurge.status).toBe(200);
    const secondBody = await secondPurge.json();
    expect(secondBody.requested).toBe(1);
    expect(secondBody.purged).toBeGreaterThan(0);
    expect(secondBody.missing).toBe(0);
  });

  test("duplicate targets in one batch are accounted for deterministically", async () => {
    await purge(["user-123"]);
    await fetchClose(`${TEST_URL}/api`);

    const res = await purge(["user-123", "user-123"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(2);
    expect(body.purged).toBeGreaterThan(0);
    expect(body.missing).toBe(1);
    expect(body.rejected).toBe(0);
    expect(body.results).toHaveLength(2);
    expect(body.results[0].target).toBe("user-123");
    expect(body.results[0].purged).toBeGreaterThan(0);
    expect(body.results[1].target).toBe("user-123");
    expect(body.results[1].purged).toBe(0);
  });

  test("other routes remain available", async () => {
    const res = await fetchClose(`${TEST_URL}/`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("ok");
  });
});

describe("cache-purge Phase 2 - Prefix invalidation", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-prefix.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("prefix purge removes all matching tags with stable accounting", async () => {
    await fetchClose(`${TEST_URL}/api`);

    const res = await purge(["user-"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.match).toBe("prefix");
    expect(body.requested).toBe(1);
    expect(body.missing).toBe(0);
    expect(body.purged).toBeGreaterThanOrEqual(2);
    expect(body.results).toHaveLength(1);
    expect(body.results[0].target).toBe("user-");
    expect(body.results[0].purged).toBeGreaterThanOrEqual(2);

    const zeroHit = await purge(["user-"]);
    expect(zeroHit.status).toBe(200);
    const zeroHitBody = await zeroHit.json();
    expect(zeroHitBody.purged).toBe(0);
    expect(zeroHitBody.missing).toBe(1);

    const sibling = await purge(["product-"]);
    expect(sibling.status).toBe(200);
    const siblingBody = await sibling.json();
    expect(siblingBody.purged).toBeGreaterThan(0);
    expect(siblingBody.missing).toBe(0);
  });

  test("duplicate prefix targets remain deterministic", async () => {
    await fetchClose(`${TEST_URL}/api`);

    const res = await purge(["user-", "user-"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(2);
    expect(body.missing).toBe(1);
    expect(body.results[0].purged).toBeGreaterThanOrEqual(2);
    expect(body.results[1].purged).toBe(0);
  });

  test("response remains valid JSON for heavily escaped targets", async () => {
    const escapedTarget = 'x\\"\\n\\r\\t';
    const res = await purge([escapedTarget]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.results).toHaveLength(1);
    expect(body.results[0].target).toBe(escapedTarget);
  });
});

describe("cache-purge Phase 2 - shared metadata with 2 workers", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-multiw.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("exact invalidation works against shared tag metadata with worker_processes 2", async () => {
    await fetchClose(`${TEST_URL}/api`);

    const res = await purge(["user-123", "product-456"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(2);
    expect(body.missing).toBe(0);
    expect(body.purged).toBeGreaterThanOrEqual(2);
    expect(body.results).toHaveLength(2);
    expect(body.results[0].purged).toBeGreaterThan(0);
    expect(body.results[1].purged).toBeGreaterThan(0);
  });

  test("second purge after shared-state mutation is zero-hit", async () => {
    const res = await purge(["user-123", "product-456"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(2);
    expect(body.purged).toBe(0);
    expect(body.missing).toBe(2);
  });

  test("purging one tag does not remove sibling tags from shared metadata", async () => {
    await purge(["user-123", "product-456"]);
    await fetchClose(`${TEST_URL}/api`);

    const firstRes = await purge(["user-123"]);
    expect(firstRes.status).toBe(200);
    const firstBody = await firstRes.json();
    expect(firstBody.requested).toBe(1);
    expect(firstBody.purged).toBeGreaterThan(0);
    expect(firstBody.missing).toBe(0);

    const secondRes = await purge(["product-456"]);
    expect(secondRes.status).toBe(200);
    const secondBody = await secondRes.json();
    expect(secondBody.requested).toBe(1);
    expect(secondBody.purged).toBeGreaterThan(0);
    expect(secondBody.missing).toBe(0);
  });

  test("shared metadata can be repopulated after a 2-worker purge", async () => {
    await purge(["user-123", "product-456"]);
    await fetchClose(`${TEST_URL}/api`);

    const firstPurge = await purge(["user-123", "product-456"]);
    expect(firstPurge.status).toBe(200);
    const firstBody = await firstPurge.json();
    expect(firstBody.requested).toBe(2);
    expect(firstBody.purged).toBeGreaterThanOrEqual(2);
    expect(firstBody.missing).toBe(0);

    await Promise.all(
      Array.from({ length: 8 }, () => fetchClose(`${TEST_URL}/api`)),
    );

    const secondPurge = await purge(["user-123", "product-456"]);
    expect(secondPurge.status).toBe(200);
    const secondBody = await secondPurge.json();
    expect(secondBody.requested).toBe(2);
    expect(secondBody.purged).toBeGreaterThanOrEqual(2);
    expect(secondBody.missing).toBe(0);

    const finalPurge = await purge(["user-123", "product-456"]);
    expect(finalPurge.status).toBe(200);
    const finalBody = await finalPurge.json();
    expect(finalBody.requested).toBe(2);
    expect(finalBody.purged).toBe(0);
    expect(finalBody.missing).toBe(2);
  });
});

describe("cache-purge Phase 2 - prefix invalidation with 2 workers", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-prefix-multiw.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("prefix invalidation works against shared tag metadata with worker_processes 2", async () => {
    await fetchClose(`${TEST_URL}/api`);

    const res = await purge(["user-"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.match).toBe("prefix");
    expect(body.requested).toBe(1);
    expect(body.missing).toBe(0);
    expect(body.purged).toBeGreaterThanOrEqual(2);

    const second = await purge(["product-"]);
    expect(second.status).toBe(200);
    const secondBody = await second.json();
    expect(secondBody.purged).toBeGreaterThan(0);
    expect(secondBody.missing).toBe(0);
  });
});

describe("cache-purge S1 - saturated metadata survives graceful reload", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-capacity-reload.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("purges pre-reload metadata after the shared tag table reaches capacity", async () => {
    for (let i = 0; i < 257; i += 1) {
      const res = await fetchClose(`${TEST_URL}/api?tag=cap-${i}`);
      expect(res.status).toBe(200);
    }

    const beforeRes = await fetchClose(`${TEST_URL}/cache-tags`);
    expect(beforeRes.status).toBe(200);
    const before = await beforeRes.json();
    expect(before.tags).toHaveLength(256);
    expect(before.capture_rejections.tag_capacity).toBeGreaterThanOrEqual(1);

    await reloadNginz();

    const afterRes = await fetchClose(`${TEST_URL}/cache-tags`);
    expect(afterRes.status).toBe(200);
    const after = await afterRes.json();
    expect(after.tags).toHaveLength(256);
    expect(after.capture_rejections).toEqual(before.capture_rejections);

    const purgeRes = await purge(["cap-0", "cap-127", "cap-255"]);
    expect(purgeRes.status).toBe(200);
    const purgeBody = await purgeRes.json();
    expect(purgeBody.physical_cache_invalidated).toBe(false);
    expect(purgeBody.purged).toBe(3);
    expect(purgeBody.missing).toBe(0);
  });
});

describe("cache-purge Phase 3 - allowlist authorization", () => {
  describe("allowed caller", () => {
    beforeAll(async () => {
      await startNginz(`tests/${MODULE}/nginx-allowlist.conf`, MODULE);
    });

    afterAll(async () => {
      await stopNginz();
      cleanupRuntime(MODULE);
    });

    test("allowlisted caller can purge successfully", async () => {
      await fetchClose(`${TEST_URL}/api`);

      const res = await purge(["user-123"]);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.purged).toBeGreaterThan(0);
      expect(body.missing).toBe(0);
    });
  });

  describe("denied caller", () => {
    beforeAll(async () => {
      await startNginz(`tests/${MODULE}/nginx-allowlist-denied.conf`, MODULE);
    });

    afterAll(async () => {
      await stopNginz();
      cleanupRuntime(MODULE);
    });

    test("non-allowlisted caller receives deterministic 403", async () => {
      const res = await purge(["user-123"]);
      expect(res.status).toBe(403);
      const body = await res.json();
      expect(body.module).toBe("cache_purge");
      expect(body.status).toBe("error");
      expect(body.error).toContain("not authorized");
    });
  });
});

describe("cache-purge Phase 3 - worker-events notifications", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-worker-events.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("successful purge emits one event per successful target", async () => {
    await fetchClose(`${TEST_URL}/api`);
    const before = await getWorkerEvents();

    const res = await purge(["user-123", "product-456"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.purged).toBeGreaterThanOrEqual(2);

    const events = await waitForWorkerEvents(
      (state) => state.events.length === 2,
      "cache",
      4000,
      before.newest_generation,
    );
    expect(events.events.map((event) => event.type)).toEqual(["purged", "purged"]);
    const payloads = events.events.map((event) => JSON.parse(event.payload));
    expect(payloads).toEqual([
      expect.objectContaining({ match: "exact", target: "user-123" }),
      expect.objectContaining({ match: "exact", target: "product-456" }),
    ]);
    expect(payloads[0].purged).toBeGreaterThan(0);
    expect(payloads[1].purged).toBeGreaterThan(0);
  });

  test("zero-hit purge does not emit worker-events notifications", async () => {
    const before = await getWorkerEvents();
    const res = await purge(["missing-tag"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.purged).toBe(0);

    await Bun.sleep(250);
    const events = await getWorkerEvents("cache", before.newest_generation);
    expect(events.events).toEqual([]);
  });

  test("mixed hit-miss purge emits notifications only for mutated targets", async () => {
    await fetchClose(`${TEST_URL}/api`);
    const before = await getWorkerEvents();

    const res = await purge(["user-123", "missing-tag"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.requested).toBe(2);
    expect(body.missing).toBe(1);

    const events = await waitForWorkerEvents(
      (state) => state.events.length === 1,
      "cache",
      4000,
      before.newest_generation,
    );
    expect(events.events[0].type).toBe("purged");
    const payload = JSON.parse(events.events[0].payload);
    expect(payload).toEqual(
      expect.objectContaining({ match: "exact", target: "user-123" }),
    );
    expect(payload.purged).toBeGreaterThan(0);
  });
});

describe("cache-purge S1 - worker-events publish outcome", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-worker-events-overflow.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("reports accepted publishes and retained-history eviction separately", async () => {
    for (let i = 0; i < 4; i += 1) {
      const res = await fetchClose(`${TEST_URL}/api?tag=event-${i}`);
      expect(res.status).toBe(200);
    }

    const fillRes = await purge(["event-0", "event-1", "event-2", "event-3"]);
    expect(fillRes.status).toBe(200);
    const fill = await fillRes.json();
    expect(fill.worker_events).toEqual({
      attempted: 4,
      published: 4,
      retention_evicted: 0,
      failed: 0,
    });

    const tagRes = await fetchClose(`${TEST_URL}/api?tag=event-overflow`);
    expect(tagRes.status).toBe(200);
    const overflowRes = await purge(["event-overflow"]);
    expect(overflowRes.status).toBe(200);
    const overflow = await overflowRes.json();
    expect(overflow.worker_events).toEqual({
      attempted: 1,
      published: 1,
      retention_evicted: 1,
      failed: 0,
    });

    const events = await getWorkerEvents("cache");
    expect(events.dropped_events).toBe(1);
    expect(events.events).toHaveLength(4);

    await reloadNginz();

    const afterReload = await getWorkerEvents("cache");
    expect(afterReload.dropped_events).toBe(1);
    expect(afterReload.events).toHaveLength(4);

    const afterReloadTag = await fetchClose(`${TEST_URL}/api?tag=event-after-reload`);
    expect(afterReloadTag.status).toBe(200);
    const afterReloadPurge = await purge(["event-after-reload"]);
    expect(afterReloadPurge.status).toBe(200);
    const afterReloadOutcome = await afterReloadPurge.json();
    expect(afterReloadOutcome.worker_events).toEqual({
      attempted: 1,
      published: 1,
      retention_evicted: 1,
      failed: 0,
    });

    const finalEvents = await getWorkerEvents("cache");
    expect(finalEvents.dropped_events).toBe(2);
    expect(finalEvents.events).toHaveLength(4);
  });
});

describe("cache-purge Phase 3 - escaped worker-events payloads", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-worker-events-escaped.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("worker-events payload stays valid JSON for quoted tag values", async () => {
    const quotedTag = 'user-"quoted';
    await fetchClose(`${TEST_URL}/api`);
    const before = await getWorkerEvents();

    const res = await purge([quotedTag]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.results[0].target).toBe(quotedTag);
    expect(body.results[0].purged).toBeGreaterThan(0);

    const events = await waitForWorkerEvents(
      (state) => state.events.length === 1,
      "cache",
      4000,
      before.newest_generation,
    );
    const payload = JSON.parse(events.events[0].payload);
    expect(payload).toEqual(
      expect.objectContaining({ match: "exact", target: quotedTag }),
    );
    expect(payload.purged).toBeGreaterThan(0);
  });
});

describe("cache-purge Phase 3 - prefix worker-events notifications", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx-prefix-worker-events.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("prefix purge emits one event per mutated tag entry", async () => {
    await fetchClose(`${TEST_URL}/api`);
    const before = await getWorkerEvents();

    const res = await purge(["user-"]);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.match).toBe("prefix");
    expect(body.purged).toBeGreaterThanOrEqual(2);

    const events = await waitForWorkerEvents(
      (state) => state.events.length === 1,
      "cache",
      4000,
      before.newest_generation,
    );
    expect(events.events[0].type).toBe("purged");
    const payload = JSON.parse(events.events[0].payload);
    expect(payload).toEqual(
      expect.objectContaining({ match: "prefix", target: "user-" }),
    );
    expect(payload.purged).toBeGreaterThanOrEqual(2);
  });
});
