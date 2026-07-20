import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";

const MODULE = "prometheus";


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("prometheus module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  describe("/metrics endpoint", () => {
    test("returns 200 status", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      expect(res.status).toBe(200);
    });

    test("returns correct content type", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const contentType = res.headers.get("content-type");
      expect(contentType).toContain("text/plain");
    });

    test("HEAD returns headers without a response body", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`, { method: "HEAD" });
      expect(res.status).toBe(200);
      const contentType = res.headers.get("content-type");
      expect(contentType).toContain("text/plain");
      const body = await res.text();
      expect(body).toBe("");
    });

    test("contains nginx_up metric", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();
      expect(body).toContain("# HELP nginx_up");
      expect(body).toContain("# TYPE nginx_up gauge");
      expect(body).toContain("nginx_up 1");
    });

    test("contains nginx_http_requests_total metric", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();
      expect(body).toContain("# HELP nginx_http_requests_total");
      expect(body).toContain("# TYPE nginx_http_requests_total counter");
      expect(body).toMatch(/nginx_http_requests_total \d+/);
    });

    test("contains nginx_http_requests_by_status metrics", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();
      expect(body).toContain("# HELP nginx_http_requests_by_status");
      expect(body).toContain("# TYPE nginx_http_requests_by_status counter");
      expect(body).toContain('nginx_http_requests_by_status{status="2xx"}');
      expect(body).toContain('nginx_http_requests_by_status{status="4xx"}');
      expect(body).toContain('nginx_http_requests_by_status{status="5xx"}');
    });

    test("contains nginx_http_request_duration_seconds histogram", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();
      expect(body).toContain("# HELP nginx_http_request_duration_seconds");
      expect(body).toContain("# TYPE nginx_http_request_duration_seconds histogram");
      // Check for histogram buckets
      expect(body).toContain('nginx_http_request_duration_seconds_bucket{le="0.005"}');
      expect(body).toContain('nginx_http_request_duration_seconds_bucket{le="0.1"}');
      expect(body).toContain('nginx_http_request_duration_seconds_bucket{le="1"}');
      expect(body).toContain('nginx_http_request_duration_seconds_bucket{le="+Inf"}');
      // Check for sum and count
      expect(body).toMatch(/nginx_http_request_duration_seconds_sum [\d.]+/);
      expect(body).toMatch(/nginx_http_request_duration_seconds_count \d+/);
    });
  });

  describe("request counting", () => {
    test("counts 2xx responses", async () => {
      // Make some 2xx requests
      for (let i = 0; i < 5; i++) {
        await fetchClose(`${TEST_URL}/api`);
      }

      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();

      // Extract 2xx count
      const match = body.match(/nginx_http_requests_by_status\{status="2xx"\} (\d+)/);
      expect(match).not.toBeNull();
      const count = parseInt(match[1]);
      expect(count).toBeGreaterThanOrEqual(5);
    });

    test("counts 4xx responses", async () => {
      // Make some 4xx requests
      for (let i = 0; i < 3; i++) {
        await fetchClose(`${TEST_URL}/notfound`);
      }

      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();

      // Extract 4xx count
      const match = body.match(/nginx_http_requests_by_status\{status="4xx"\} (\d+)/);
      expect(match).not.toBeNull();
      const count = parseInt(match[1]);
      expect(count).toBeGreaterThanOrEqual(3);
    });

    test("counts 5xx responses", async () => {
      // Make some 5xx requests
      for (let i = 0; i < 2; i++) {
        await fetchClose(`${TEST_URL}/error`);
      }

      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();

      // Extract 5xx count
      const match = body.match(/nginx_http_requests_by_status\{status="5xx"\} (\d+)/);
      expect(match).not.toBeNull();
      const count = parseInt(match[1]);
      expect(count).toBeGreaterThanOrEqual(2);
    });

    test("counts 3xx responses", async () => {
      // Make some 3xx requests (don't follow redirects)
      for (let i = 0; i < 2; i++) {
        await fetchClose(`${TEST_URL}/redirect`, { redirect: "manual" });
      }

      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();

      // Extract 3xx count
      const match = body.match(/nginx_http_requests_by_status\{status="3xx"\} (\d+)/);
      expect(match).not.toBeNull();
      const count = parseInt(match[1]);
      expect(count).toBeGreaterThanOrEqual(2);
    });

    test("total requests increases", async () => {
      // Get initial count
      const res1 = await fetchClose(`${TEST_URL}/metrics`);
      const body1 = await res1.text();
      const match1 = body1.match(/nginx_http_requests_total (\d+)/);
      const initialCount = parseInt(match1[1]);

      // Make more requests
      for (let i = 0; i < 10; i++) {
        await fetchClose(`${TEST_URL}/`);
      }

      // Get new count
      const res2 = await fetchClose(`${TEST_URL}/metrics`);
      const body2 = await res2.text();
      const match2 = body2.match(/nginx_http_requests_total (\d+)/);
      const newCount = parseInt(match2[1]);

      // Should have increased by at least 10
      expect(newCount).toBeGreaterThanOrEqual(initialCount + 10);
    });

    test("does not count /metrics endpoint itself", async () => {
      // Get initial count
      const res1 = await fetchClose(`${TEST_URL}/metrics`);
      const body1 = await res1.text();
      const match1 = body1.match(/nginx_http_requests_total (\d+)/);
      const initialCount = parseInt(match1[1]);

      // Make multiple metrics requests
      for (let i = 0; i < 5; i++) {
        await fetchClose(`${TEST_URL}/metrics`);
      }

      // Get new count
      const res2 = await fetchClose(`${TEST_URL}/metrics`);
      const body2 = await res2.text();
      const match2 = body2.match(/nginx_http_requests_total (\d+)/);
      const newCount = parseInt(match2[1]);

      // Count should not have increased (metrics endpoint excluded)
      expect(newCount).toBe(initialCount);
    });

    test("metrics endpoint requests do not change histogram count", async () => {
      const res1 = await fetchClose(`${TEST_URL}/metrics`);
      const body1 = await res1.text();
      const match1 = body1.match(/nginx_http_request_duration_seconds_count (\d+)/);
      const initialCount = parseInt(match1[1]);

      for (let i = 0; i < 5; i++) {
        await fetchClose(`${TEST_URL}/metrics`);
      }

      const res2 = await fetchClose(`${TEST_URL}/metrics`);
      const body2 = await res2.text();
      const match2 = body2.match(/nginx_http_request_duration_seconds_count (\d+)/);
      const newCount = parseInt(match2[1]);

      expect(newCount).toBe(initialCount);
    });

    test("non-metrics requests increase histogram count cumulatively", async () => {
      const res1 = await fetchClose(`${TEST_URL}/metrics`);
      const body1 = await res1.text();
      const match1 = body1.match(/nginx_http_request_duration_seconds_count (\d+)/);
      const initialCount = parseInt(match1[1]);

      await fetchClose(`${TEST_URL}/`);
      await fetchClose(`${TEST_URL}/api`);
      await fetchClose(`${TEST_URL}/notfound`);
      await fetchClose(`${TEST_URL}/error`);

      const res2 = await fetchClose(`${TEST_URL}/metrics`);
      const body2 = await res2.text();
      const match2 = body2.match(/nginx_http_request_duration_seconds_count (\d+)/);
      const newCount = parseInt(match2[1]);

      expect(newCount).toBeGreaterThanOrEqual(initialCount + 4);
    });

    test("aggregates request counts across multiple workers", async () => {
      const beforeRes = await fetchClose(`${TEST_URL}/metrics`);
      const beforeBody = await beforeRes.text();
      const beforeMatch = beforeBody.match(/nginx_http_requests_total (\d+)/);
      const initialCount = parseInt(beforeMatch[1]);

      const requestCount = 40;
      await Promise.all(
        Array.from({ length: requestCount }, () => fetchClose(`${TEST_URL}/api`))
      );

      const afterRes = await fetchClose(`${TEST_URL}/metrics`);
      const afterBody = await afterRes.text();
      const afterMatch = afterBody.match(/nginx_http_requests_total (\d+)/);
      const newCount = parseInt(afterMatch[1]);

      expect(newCount).toBe(initialCount + requestCount);
    });
  });

  describe("nginx variables", () => {
    test("prometheus_requests_total tracks non-metrics traffic", async () => {
      const before = await fetchClose(`${TEST_URL}/vars`);
      expect(before.status).toBe(200);
      const initialCount = Number(before.headers.get("x-prometheus-requests-total"));

      await fetchClose(`${TEST_URL}/`);
      await fetchClose(`${TEST_URL}/api`);
      await fetchClose(`${TEST_URL}/notfound`);

      const after = await fetchClose(`${TEST_URL}/vars`);
      expect(after.status).toBe(200);
      const nextCount = Number(after.headers.get("x-prometheus-requests-total"));

      expect(nextCount).toBeGreaterThanOrEqual(initialCount + 4);
    });

    test("prometheus_error_rate is 0.000 before error traffic", async () => {
      await stopNginz();
      await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);

      const res = await fetchClose(`${TEST_URL}/vars`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-prometheus-error-rate")).toBe("0.000");
    });

    test("prometheus_error_rate reflects 4xx and 5xx responses", async () => {
      await stopNginz();
      await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);

      const before = await fetchClose(`${TEST_URL}/vars`);
      const initialCount = Number(before.headers.get("x-prometheus-requests-total"));

      await fetchClose(`${TEST_URL}/notfound`);
      await fetchClose(`${TEST_URL}/error`);

      const after = await fetchClose(`${TEST_URL}/vars`);
      expect(after.status).toBe(200);

      const total = Number(after.headers.get("x-prometheus-requests-total"));
      const expected = (2 / total).toFixed(3);

      expect(total).toBeGreaterThanOrEqual(initialCount + 3);
      expect(after.headers.get("x-prometheus-error-rate")).toBe(expected);
    });
  });

  describe("Prometheus format compliance", () => {
    test("HELP lines start with # HELP", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();
      const helpLines = body.split("\n").filter((l) => l.includes("HELP"));
      for (const line of helpLines) {
        expect(line).toMatch(/^# HELP /);
      }
    });

    test("TYPE lines start with # TYPE", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();
      const typeLines = body.split("\n").filter((l) => l.includes("TYPE"));
      for (const line of typeLines) {
        expect(line).toMatch(/^# TYPE /);
      }
    });

    test("metric values are numeric", async () => {
      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();
      const lines = body.split("\n").filter((l) => l && !l.startsWith("#"));
      for (const line of lines) {
        // Each metric line should end with a number (integer or decimal)
        expect(line).toMatch(/\s[\d.]+$/);
      }
    });

    test("histogram buckets stay cumulative and +Inf matches count", async () => {
      await fetchClose(`${TEST_URL}/`);
      await fetchClose(`${TEST_URL}/api`);
      await fetchClose(`${TEST_URL}/error`);

      const res = await fetchClose(`${TEST_URL}/metrics`);
      const body = await res.text();

      const bucketMatches = [...body.matchAll(/nginx_http_request_duration_seconds_bucket\{le="([^"]+)"\} (\d+)/g)];
      const counts = bucketMatches.map(([, , count]) => parseInt(count));
      for (let i = 1; i < counts.length; i++) {
        expect(counts[i]).toBeGreaterThanOrEqual(counts[i - 1]);
      }

      const infMatch = body.match(/nginx_http_request_duration_seconds_bucket\{le="\+Inf"\} (\d+)/);
      const countMatch = body.match(/nginx_http_request_duration_seconds_count (\d+)/);
      expect(infMatch).not.toBeNull();
      expect(countMatch).not.toBeNull();
      expect(parseInt(infMatch[1])).toBe(parseInt(countMatch[1]));
    });
  });
});
