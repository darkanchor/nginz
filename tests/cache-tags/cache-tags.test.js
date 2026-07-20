import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  reloadNginz,
  stopNginz,
  cleanupRuntime,
  createHTTPMock,
  createMockManager,
  MOCK_PORTS,
  TEST_URL,
} from "../harness.js";

const MODULE = "cache-tags";


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("cache-tags module", () => {
  let mocks;
  let backend;

  beforeAll(async () => {
    mocks = createMockManager();

    // Create mock backend that returns Cache-Tag headers
    backend = mocks.add(
      "backend",
      createHTTPMock(MOCK_PORTS.HTTP_UPSTREAM_1)
    );

    // API endpoints return product,api tags
    backend.get("/api/*", () => ({
      body: { id: 123, name: "Product" },
      headers: { "Cache-Tag": "product,api" },
    }));

    // Products endpoints return product,catalog tags
    backend.get("/products/*", () => ({
      body: { products: [] },
      headers: { "Cache-Tag": "product,catalog" },
    }));

    // Categories endpoints return category,catalog tags
    backend.get("/categories/*", () => ({
      body: { categories: [] },
      headers: { "Cache-Tag": "category,catalog" },
    }));

    backend.get("/spaced/*", () => ({
      body: { ok: true },
      headers: { "Cache-Tag": " product , spaced-tag , catalog  " },
    }));

    backend.get("/custom/*", () => ({
      body: { custom: true },
      headers: { "X-Cache-Tags": "custom,secondary" },
    }));

    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    await mocks.stopAll();
    cleanupRuntime(MODULE);
  });

  test("health check", async () => {
    const res = await fetchClose(`${TEST_URL}/health`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("ok");
  });

  test("backend returns Cache-Tag header via proxy", async () => {
    const res = await fetchClose(`${TEST_URL}/api/test`);
    expect(res.status).toBe(200);
    expect(res.headers.get("Cache-Tag")).toBe("product,api");
    expect(res.headers.get("x-cache-tags-last-purged")).toBeNull();
    expect(res.headers.get("x-cache-tags-last-tag")).toBeNull();
    expect(res.headers.get("x-cache-tags-last-error")).toBeNull();
  });

  describe("/cache/purge endpoint", () => {
    test("returns JSON response", async () => {
      const res = await fetchClose(`${TEST_URL}/cache/purge`);
      expect(res.status).toBe(200);
      const contentType = res.headers.get("content-type");
      expect(contentType).toContain("application/json");
    });

    test("lists tags when no tag parameter", async () => {
      const res = await fetchClose(`${TEST_URL}/cache/purge`);
      const json = await res.json();
      expect(json).toHaveProperty("tags");
      expect(Array.isArray(json.tags)).toBe(true);
      expect(res.headers.get("x-cache-tags-last-purged")).toBeNull();
      expect(res.headers.get("x-cache-tags-last-tag")).toBeNull();
      expect(res.headers.get("x-cache-tags-last-error")).toBeNull();
    });

    test("allows DELETE requests for purge operations", async () => {
      await fetchClose(`${TEST_URL}/api/delete-method-${Date.now()}`);

      const res = await fetchClose(`${TEST_URL}/cache/purge?tag=api`, {
        method: "DELETE",
      });

      expect(res.status).toBe(200);
      const json = await res.json();
      expect(json.tag).toBe("api");
      expect(json.purged).toBeGreaterThanOrEqual(1);
      expect(res.headers.get("x-cache-tags-last-tag")).toBe("api");
      expect(Number(res.headers.get("x-cache-tags-last-purged"))).toBeGreaterThanOrEqual(1);
      expect(res.headers.get("x-cache-tags-last-error")).toBeNull();
    });

    test("rejects POST requests", async () => {
      const res = await fetchClose(`${TEST_URL}/cache/purge?tag=api`, {
        method: "POST",
      });

      expect(res.status).toBe(405);
      expect(res.headers.get("x-cache-tags-last-error")).toBe("method_not_allowed");
      expect(res.headers.get("x-cache-tags-last-tag")).toBeNull();
      expect(res.headers.get("x-cache-tags-last-purged")).toBeNull();
    });
  });

  describe("tag capture", () => {
    test("captures tags from proxied response headers", async () => {
      // Make requests to populate tags
      await fetchClose(`${TEST_URL}/api/item1`);
      await fetchClose(`${TEST_URL}/products/list`);

      // Check tags were captured
      const res = await fetchClose(`${TEST_URL}/cache/purge`);
      const json = await res.json();

      expect(json.tags.length).toBeGreaterThan(0);

      // Find the product tag (common to both endpoints)
      const productTag = json.tags.find((t) => t.tag === "product");
      expect(productTag).toBeDefined();
      expect(productTag.uris).toBeGreaterThanOrEqual(1);
    });

    test("multiple tags per response are captured", async () => {
      // /api/ returns "product,api" tags
      await fetchClose(`${TEST_URL}/api/multi`);

      const res = await fetchClose(`${TEST_URL}/cache/purge`);
      const json = await res.json();

      const productTag = json.tags.find((t) => t.tag === "product");
      const apiTag = json.tags.find((t) => t.tag === "api");

      expect(productTag).toBeDefined();
      expect(apiTag).toBeDefined();
    });

    test("trims surrounding whitespace around tags", async () => {
      await fetchClose(`${TEST_URL}/spaced/trimmed`);

      const res = await fetchClose(`${TEST_URL}/cache/purge`);
      const json = await res.json();

      const spacedTag = json.tags.find((t) => t.tag === "spaced-tag");
      const productTag = json.tags.find((t) => t.tag === "product");
      expect(spacedTag).toBeDefined();
      expect(productTag).toBeDefined();
    });

    test("same URI with same tag is not duplicated", async () => {
      // Make unique request and get initial count
      const uniqueUri = `/api/dedup-${Date.now()}`;
      await fetchClose(`${TEST_URL}${uniqueUri}`);

      let res = await fetchClose(`${TEST_URL}/cache/purge`);
      let json = await res.json();
      const apiTag = json.tags.find((t) => t.tag === "api");
      const initialCount = apiTag ? apiTag.uris : 0;

      // Request same URI again
      await fetchClose(`${TEST_URL}${uniqueUri}`);

      // Count should not increase for same URI
      res = await fetchClose(`${TEST_URL}/cache/purge`);
      json = await res.json();
      const apiTagAfter = json.tags.find((t) => t.tag === "api");
      expect(apiTagAfter.uris).toBe(initialCount);
    });
  });

  describe("purge by tag", () => {
    test("purge removes tag and returns count", async () => {
      // Make request to create category tag
      await fetchClose(`${TEST_URL}/categories/all`);

      // Verify category tag exists
      let res = await fetchClose(`${TEST_URL}/cache/purge`);
      let json = await res.json();
      const categoryTag = json.tags.find((t) => t.tag === "category");
      expect(categoryTag).toBeDefined();

      // Purge the category tag
      res = await fetchClose(`${TEST_URL}/cache/purge?tag=category`);
      json = await res.json();
      expect(json.tag).toBe("category");
      expect(json.purged).toBeGreaterThanOrEqual(1);

      // Verify tag is gone
      res = await fetchClose(`${TEST_URL}/cache/purge`);
      json = await res.json();
      const removedTag = json.tags.find((t) => t.tag === "category");
      expect(removedTag).toBeUndefined();
    });

    test("purge non-existent tag returns zero", async () => {
      const res = await fetchClose(`${TEST_URL}/cache/purge?tag=nonexistent`);
      const json = await res.json();
      expect(json.tag).toBe("nonexistent");
      expect(json.purged).toBe(0);
      expect(res.headers.get("x-cache-tags-last-tag")).toBe("nonexistent");
      expect(res.headers.get("x-cache-tags-last-purged")).toBe("0");
      expect(res.headers.get("x-cache-tags-last-error")).toBeNull();
    });

    test("purge uses exact tag matching only", async () => {
      await fetchClose(`${TEST_URL}/products/exact-match`);

      const res = await fetchClose(`${TEST_URL}/cache/purge?tag=prod*`);
      const json = await res.json();
      expect(json.tag).toBe("prod*");
      expect(json.purged).toBe(0);

      const listRes = await fetchClose(`${TEST_URL}/cache/purge`);
      const listJson = await listRes.json();
      const productTag = listJson.tags.find((t) => t.tag === "product");
      expect(productTag).toBeDefined();
    });

    test("purge one tag does not affect others", async () => {
      // Populate multiple tags
      await fetchClose(`${TEST_URL}/api/preserve1`);
      await fetchClose(`${TEST_URL}/categories/preserve2`);

      // Get initial state
      let res = await fetchClose(`${TEST_URL}/cache/purge`);
      let json = await res.json();
      const apiTagBefore = json.tags.find((t) => t.tag === "api");
      expect(apiTagBefore).toBeDefined();

      // Purge category only
      await fetchClose(`${TEST_URL}/cache/purge?tag=category`);

      // api tag should still exist
      res = await fetchClose(`${TEST_URL}/cache/purge`);
      json = await res.json();
      const apiTagAfter = json.tags.find((t) => t.tag === "api");
      expect(apiTagAfter).toBeDefined();
    });
  });

  describe("catalog tag (shared between products and categories)", () => {
    test("catalog tag captures URIs from multiple locations", async () => {
      await fetchClose(`${TEST_URL}/products/cat1`);
      await fetchClose(`${TEST_URL}/categories/cat2`);

      const res = await fetchClose(`${TEST_URL}/cache/purge`);
      const json = await res.json();

      const catalogTag = json.tags.find((t) => t.tag === "catalog");
      expect(catalogTag).toBeDefined();
      expect(catalogTag.uris).toBeGreaterThanOrEqual(2);
    });

    test("captured tags are visible and purgeable across workers", async () => {
      const sharedPrefix = `shared-${Date.now()}`;
      const uris = Array.from({ length: 24 }, (_, i) =>
        `/products/${sharedPrefix}-${i}`
      );

      await Promise.all(uris.map((uri) => fetchClose(`${TEST_URL}${uri}`)));

      const listRes = await fetchClose(`${TEST_URL}/cache/purge`);
      const listJson = await listRes.json();
      const productTag = listJson.tags.find((t) => t.tag === "product");
      expect(productTag).toBeDefined();
      expect(productTag.uris).toBeGreaterThanOrEqual(uris.length);

      const purgeRes = await fetchClose(`${TEST_URL}/cache/purge?tag=product`, {
        method: "DELETE",
      });
      const purgeJson = await purgeRes.json();
      expect(purgeJson.tag).toBe("product");
      expect(purgeJson.purged).toBeGreaterThanOrEqual(uris.length);
    });
  });

  test("reports URI-capacity rejection without losing existing tag mappings", async () => {
    const beforeRes = await fetchClose(`${TEST_URL}/cache/purge`);
    const before = await beforeRes.json();
    const beforeRejected = before.capture_rejections.uri_capacity;
    const prefix = `capacity-${Date.now()}`;

    for (let i = 0; i < 80; i += 1) {
      const res = await fetchClose(`${TEST_URL}/api/${prefix}-${i}`);
      expect(res.status).toBe(200);
    }

    const afterRes = await fetchClose(`${TEST_URL}/cache/purge`);
    const after = await afterRes.json();
    const apiTag = after.tags.find((tag) => tag.tag === "api");
    expect(apiTag).toBeDefined();
    expect(apiTag.uris).toBeLessThanOrEqual(64);
    expect(after.capture_rejections.uri_capacity).toBeGreaterThan(beforeRejected);
    expect(after.capture_rejections.invalid).toBeGreaterThanOrEqual(0);
    expect(after.capture_rejections.tag_capacity).toBeGreaterThanOrEqual(0);
  });

  test("preserves saturated shared metadata and counters across graceful reload", async () => {
    const beforeRes = await fetchClose(`${TEST_URL}/cache/purge`);
    const before = await beforeRes.json();
    const beforeApi = before.tags.find((tag) => tag.tag === "api");
    expect(beforeApi).toBeDefined();
    expect(before.capture_rejections.uri_capacity).toBeGreaterThan(0);

    await reloadNginz();

    const afterRes = await fetchClose(`${TEST_URL}/cache/purge`);
    const after = await afterRes.json();
    const afterApi = after.tags.find((tag) => tag.tag === "api");
    expect(afterApi).toBeDefined();
    expect(afterApi.uris).toBe(beforeApi.uris);
    expect(after.capture_rejections).toEqual(before.capture_rejections);
  });

  describe("custom tag header", () => {
    test("captures tags from the configured alternate response header", async () => {
      await stopNginz();
      await startNginz(`tests/${MODULE}/nginx-custom-header.conf`, MODULE);

      try {
        await fetchClose(`${TEST_URL}/custom/example`);

        const res = await fetchClose(`${TEST_URL}/cache/purge`);
        const json = await res.json();

        const customTag = json.tags.find((t) => t.tag === "custom");
        const secondaryTag = json.tags.find((t) => t.tag === "secondary");
        expect(customTag).toBeDefined();
        expect(secondaryTag).toBeDefined();
      } finally {
        await stopNginz();
      }
    });
  });
});
