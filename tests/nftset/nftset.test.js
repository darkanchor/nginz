import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { ensureBuild, startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";

const MODULE = "nftset";


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("nftset-nginx-module", () => {
  beforeAll(async () => {
    ensureBuild();
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  describe("config loading", () => {
    test("nginx starts with all nftset directives (http/server/location context)", async () => {
      const res = await fetchClose(`${TEST_URL}/unset`);
      expect(res.status).toBe(200);
    });
  });

  describe("fail-open config coverage", () => {
    test("blocklist location passes through when lookup fails and fail_open is inherited", async () => {
      const res = await fetchClose(`${TEST_URL}/blocklist`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("blocklist ok");
    });

    test("allowlist location fails closed when lookup cannot be completed", async () => {
      const res = await fetchClose(`${TEST_URL}/allowlist`);
      expect(res.status).toBe(403);
    });

    test("defaults location inherits fail_open from server block and passes through", async () => {
      const res = await fetchClose(`${TEST_URL}/defaults`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("defaults ok");
    });

    test("ipv6 family location still passes through when fail_open is inherited", async () => {
      const res = await fetchClose(`${TEST_URL}/ipv6`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("ipv6 ok");
    });
  });

  describe("nftset off", () => {
    test("disabled location is not intercepted", async () => {
      const res = await fetchClose(`${TEST_URL}/disabled`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("disabled ok");
    });
  });

  describe("location without nftset directive", () => {
    test("unset location is unaffected by module", async () => {
      const res = await fetchClose(`${TEST_URL}/unset`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("unset ok");
    });
  });

  describe("nftset_status", () => {
    test("custom status location returns configured status when lookup fails closed", async () => {
      const res = await fetchClose(`${TEST_URL}/status-429`);
      expect(res.status).toBe(429);
    });
  });

  describe("nftset_fail_open", () => {
    test("fail_open location passes through", async () => {
      const res = await fetchClose(`${TEST_URL}/fail-open`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("fail-open ok");
    });
  });

  describe("nftset_dryrun", () => {
    test("dryrun location always passes through", async () => {
      const res = await fetchClose(`${TEST_URL}/dryrun`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("dryrun ok");
    });

    test("dryrun location passes through under load", async () => {
      const reqs = Array.from({ length: 5 }, () => fetchClose(`${TEST_URL}/dryrun`));
      const results = await Promise.all(reqs);
      for (const res of results) {
        expect(res.status).toBe(200);
      }
    });
  });

  describe("nftset_cache_ttl", () => {
    test("custom cache TTL location parses and still passes through via inherited fail_open", async () => {
      const res = await fetchClose(`${TEST_URL}/cache-ttl`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("cache-ttl ok");
    });
  });

  describe("nftset_autoadd", () => {
    test("autoadd-only location parses and serves without lookup enforcement", async () => {
      const res = await fetchClose(`${TEST_URL}/autoadd`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("autoadd ok");
    });

    test("autoadd inherits table and family from higher scopes", async () => {
      const res = await fetchClose(`${TEST_URL}/autoadd-inherit`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("autoadd-inherit ok");
    });

    test("autoadd timeout directive parses cleanly", async () => {
      const res = await fetchClose(`${TEST_URL}/autoadd-timeout`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("autoadd-timeout ok");
    });
  });

  describe("nftset_ratelimit", () => {
    test("ratelimit-only location parses and serves", async () => {
      const res = await fetchClose(`${TEST_URL}/ratelimit`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("ratelimit ok");
    });

    test("ratelimit burst location parses and serves", async () => {
      const res = await fetchClose(`${TEST_URL}/ratelimit-burst`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("ratelimit-burst ok");
    });

    test("shared ratelimit budget is enforced across multiple workers", async () => {
      await Bun.sleep(1100);

      const statuses = await Promise.all(
        Array.from({ length: 4 }, () => fetchClose(`${TEST_URL}/ratelimit`).then((res) => res.status))
      );

      expect(statuses.filter((s) => s === 200).length).toBe(3);
      expect(statuses.filter((s) => s === 429).length).toBe(1);
    });

    test("child ratelimit burst can override inherited burst with zero", async () => {
      const res = await fetchClose(`${TEST_URL}/ratelimit-parent/child-zero-burst`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("ratelimit-child-zero-burst ok");
    });

    test("autoban directives parse alongside lookup directives", async () => {
      const res = await fetchClose(`${TEST_URL}/autoban`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-nftset-result")).toBe("error");
      expect(await res.text()).toContain("autoban ok");
    });

  });

  describe("nftset_sets", () => {
    test("multi-set blocklist location parses and still passes through when lookup fails open", async () => {
      const res = await fetchClose(`${TEST_URL}/multi-set`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("multi-set ok");
    });

    test("multi-set allowlist location parses and still passes through when lookup fails open", async () => {
      const res = await fetchClose(`${TEST_URL}/multi-set-allow`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("multi-set-allow ok");
    });
  });

  describe("$nftset_result variable", () => {
    test("result is 'error' when lookup fails but fail_open allows the request", async () => {
      const res = await fetchClose(`${TEST_URL}/variable`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-nftset-result")).toBe("error");
      expect(res.headers.get("x-nftset-matched-set")).toBeNull();
    });

    test("result is 'dryrun' when nftset_dryrun is on", async () => {
      const res = await fetchClose(`${TEST_URL}/variable-dryrun`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-nftset-result")).toBe("dryrun");
      expect(res.headers.get("x-nftset-matched-set")).toBeNull();
    });
  });

  describe("nftset_set combined table:set token", () => {
    test("combined token parses table and set name from a single directive", async () => {
      const res = await fetchClose(`${TEST_URL}/combined-set`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("combined-set ok");
    });
  });

  describe("nftset_blacklist / nftset_whitelist aliases", () => {
    test("nftset_blacklist enables nftset with deny=on and passes through when lookup fails open", async () => {
      const res = await fetchClose(`${TEST_URL}/alias-blacklist`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-nftset-result")).toBe("error");
      expect(await res.text()).toContain("alias-blacklist ok");
    });

    test("nftset_whitelist enables nftset with deny=off and passes through via fail_open", async () => {
      const res = await fetchClose(`${TEST_URL}/alias-whitelist`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-nftset-result")).toBe("error");
      expect(await res.text()).toContain("alias-whitelist ok");
    });
  });

  describe("config inheritance", () => {
    test("child location inherits nftset and fail_open from parent/server and passes through", async () => {
      const res = await fetchClose(`${TEST_URL}/parent/child`);
      expect(res.status).toBe(200);
      expect(await res.text()).toContain("child ok");
    });

    test("location inherits table/set/family/fail_open from server block", async () => {
      const res = await fetchClose(`${TEST_URL}/defaults`);
      expect(res.status).toBe(200);
    });
  });

  describe("IP family auto-detection", () => {
    test("auto-detect: no nftset_family configured — nginx starts and serves requests", async () => {
      const res = await fetchClose(`${TEST_URL}/auto-family`);
      expect(res.status).toBe(200);
      // dryrun is on so result is always "dryrun" regardless of detected family
      expect(res.headers.get("x-nftset-result")).toBe("dryrun");
      expect(await res.text()).toContain("auto-family ok");
    });

    test("explicit nftset_family overrides auto-detect", async () => {
      const res = await fetchClose(`${TEST_URL}/explicit-family`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-nftset-result")).toBe("dryrun");
    });

    test("blocklist without nftset_family set still passes through via inherited fail_open", async () => {
      const res = await fetchClose(`${TEST_URL}/defaults`);
      expect(res.status).toBe(200);
    });
  });

  describe("concurrent requests", () => {
    test("handles concurrent requests across fail-open and dryrun locations", async () => {
      const reqs = [
        ...Array.from({ length: 4 }, () => fetchClose(`${TEST_URL}/blocklist`)),
        ...Array.from({ length: 4 }, () => fetchClose(`${TEST_URL}/dryrun`)),
        ...Array.from({ length: 4 }, () => fetchClose(`${TEST_URL}/variable`)),
      ];
      const results = await Promise.all(reqs);
      for (const res of results) {
        expect(res.status).toBe(200);
      }
    });
  });
});
