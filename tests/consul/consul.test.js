import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createConsulMock,
  MOCK_PORTS,
} from "../harness.js";

const MODULE = "consul";
let consulMock;

describe("consul module", () => {
  beforeAll(async () => {
    // Start Consul mock
    consulMock = createConsulMock(MOCK_PORTS.CONSUL);

    // Register test services
    consulMock.addService("api-service", [
      { id: "api-1", address: "127.0.0.1", port: 9001, tags: ["v1", "primary"] },
      { id: "api-2", address: "127.0.0.1", port: 9002, tags: ["v1"] },
    ]);

    consulMock.addService("backend-service", [
      { id: "backend-1", address: "10.0.0.1", port: 8080, tags: ["production"] },
    ]);

    consulMock.addService("cache-service", [
      { id: "cache-1", address: "10.0.0.5", port: 6379, tags: ["redis"] },
    ]);

    consulMock.addService("large-service", Array.from({ length: 80 }, (_, i) => ({
      id: `instance-${i}-\"quoted\"`,
      address: `10.0.1.${(i % 250) + 1}`,
      port: 7000 + i,
      tags: ["large", `tag-${i}-\\escaped`],
    })));

    // Set some KV data
    consulMock.setKV("config/app/timeout", "30");
    consulMock.setKV("config/app/retries", "3");
    consulMock.setKV("config/db/host", "localhost");
    consulMock.setKV("config/app/empty", "");
    consulMock.setKV("config/app/json", '{"mode":"safe","enabled":true}');

    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    if (consulMock) {
      consulMock.stop();
    }
    cleanupRuntime(MODULE);
  });

  describe("service discovery", () => {
    test("fetches service instances by name from URI", async () => {
      const res = await fetch(`${TEST_URL}/services/api-service`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.services).toBeDefined();
      expect(body.services.length).toBe(2);

      // Check first service instance
      const svc1 = body.services.find(s => s.id === "api-1");
      expect(svc1).toBeDefined();
      expect(svc1.address).toBe("127.0.0.1");
      expect(svc1.port).toBe(9001);
      expect(svc1.tags).toContain("v1");
    });

    test("fetches service with fixed name from config", async () => {
      const res = await fetch(`${TEST_URL}/api-service`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.services).toBeDefined();
      expect(body.services.length).toBe(2);
    });

    test("returns empty array for non-existent service", async () => {
      const res = await fetch(`${TEST_URL}/services/non-existent`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.services).toEqual([]);
    });

    test("fetches another service", async () => {
      const res = await fetch(`${TEST_URL}/services/backend-service`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.services.length).toBe(1);
      expect(body.services[0].address).toBe("10.0.0.1");
      expect(body.services[0].port).toBe(8080);
    });

    test("decodes bounded chunked Consul responses split across writes", async () => {
      const rawBody = JSON.stringify([{
        Node: { ID: "node", Node: "mock", Address: "127.0.0.1", Datacenter: "dc1" },
        Service: { ID: "chunked-1", Service: "chunked-service", Address: "10.2.0.1", Port: 9443, Tags: ["chunked"], Meta: {} },
        Checks: [{ Status: "passing" }],
      }]);
      consulMock.setHealthBehavior({ rawBody, chunked: true });
      try {
        const res = await fetch(`${TEST_URL}/services/chunked-service`);
        expect(res.status).toBe(200);
        const body = await res.json();
        expect(body.services).toEqual([{
          id: "chunked-1",
          address: "10.2.0.1",
          port: 9443,
          tags: ["chunked"],
        }]);
      } finally {
        consulMock.clearHealthBehavior();
      }
    });

    test("renders responses larger than the old 8 KiB scratch buffer safely", async () => {
      const res = await fetch(`${TEST_URL}/services/large-service`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.services).toHaveLength(80);
      expect(body.services[0].id).toBe('instance-0-"quoted"');
      expect(body.services[0].tags[1]).toBe("tag-0-\\escaped");

      const followup = await fetch(`${TEST_URL}/services/api-service`);
      expect(followup.status).toBe(200);
    });

    test("applies configured tag filter and forwards dc/token query metadata", async () => {
      consulMock.clearLog();

      const res = await fetch(`${TEST_URL}/api-primary`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.services).toHaveLength(1);
      expect(body.services[0].id).toBe("api-1");
      expect(body.services[0].tags).toContain("primary");

      const lastRequest = consulMock.getLastRequest();
      expect(lastRequest.path).toBe("/v1/health/service/api-service");
      expect(lastRequest.query.passing).toBe("true");
      expect(lastRequest.query.tag).toBe("primary");
      expect(lastRequest.query.dc).toBe("dc-west");
      expect(lastRequest.headers["x-consul-token"]).toBe("test-token-123");
    });

    test("filters out critical instances when passing-only query is used", async () => {
      consulMock.setServiceHealth("api-service", "api-2", "critical");

      const res = await fetch(`${TEST_URL}/services/api-service`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.services).toHaveLength(1);
      expect(body.services[0].id).toBe("api-1");

      consulMock.setServiceHealth("api-service", "api-2", "passing");
    });

    test("exposes healthy service count variable on service responses", async () => {
      const res = await fetch(`${TEST_URL}/services/api-service`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-consul-service-healthy-count")).toBe("2");
      expect(res.headers.get("x-consul-lookup-error")).toBeNull();
    });
  });

  describe("KV store", () => {
    test("fetches value by key from URI", async () => {
      const res = await fetch(`${TEST_URL}/kv/config/app/timeout`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.value).toBe("30");
    });

    test("fetches value with fixed key from config", async () => {
      const res = await fetch(`${TEST_URL}/config/timeout`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.value).toBe("30");
    });

    test("fetches another KV value", async () => {
      const res = await fetch(`${TEST_URL}/kv/config/app/retries`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.value).toBe("3");
    });

    test("returns null for non-existent key", async () => {
      const res = await fetch(`${TEST_URL}/kv/config/non-existent`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.value).toBeNull();
      expect(res.headers.get("x-consul-kv-found")).toBe("0");
      expect(res.headers.get("x-consul-kv-value")).toBeNull();
      expect(res.headers.get("x-consul-lookup-error")).toBeNull();
    });

    test("preserves empty string KV values instead of converting them to null", async () => {
      const res = await fetch(`${TEST_URL}/config/empty`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.value).toBe("");
      expect(res.headers.get("x-consul-kv-found")).toBe("1");
      expect(res.headers.get("x-consul-kv-value")).toBeNull();
    });

    test("returns JSON-safe escaped KV values", async () => {
      const res = await fetch(`${TEST_URL}/config/json`);
      expect(res.status).toBe(200);

      const text = await res.text();
      expect(() => JSON.parse(text)).not.toThrow();

      const body = JSON.parse(text);
      expect(body.value).toBe('{"mode":"safe","enabled":true}');
    });

    test("exposes KV hit variables on successful lookups", async () => {
      const res = await fetch(`${TEST_URL}/config/timeout`);
      expect(res.status).toBe(200);
      expect(res.headers.get("x-consul-kv-found")).toBe("1");
      expect(res.headers.get("x-consul-kv-value")).toBe("30");
      expect(res.headers.get("x-consul-lookup-error")).toBeNull();
    });

    test("exposes lookup_error on upstream failure", async () => {
      consulMock.setKVError("config/app/error", 500, '{"error":"boom"}');

      const res = await fetch(`${TEST_URL}/config/error`);
      expect(res.status).toBe(502);
      expect(res.headers.get("x-consul-lookup-error")).toBe("consul_error");
      expect(res.headers.get("x-consul-kv-found")).toBe("0");

      const body = await res.json();
      expect(body).toEqual({ error: "consul_error" });
    });
  });

  describe("catalog", () => {
    test("lists all registered services", async () => {
      const res = await fetch(`${TEST_URL}/catalog`);
      expect(res.status).toBe(200);

      const body = await res.json();
      expect(body.services).toBeDefined();
      expect(body.services).toContain("api-service");
      expect(body.services).toContain("backend-service");
      expect(body.services).toContain("cache-service");
    });
  });

  describe("error handling", () => {
    test("only allows GET requests", async () => {
      const res = await fetch(`${TEST_URL}/services/api-service`, {
        method: "POST",
      });
      expect(res.status).toBe(405);
    });
  });
});
