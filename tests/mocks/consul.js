/**
 * Mock Consul HTTP API server
 * Supports service discovery, health checks, and KV store
 */

export class ConsulMock {
  constructor(port = 8500) {
    this.port = port;
    this.server = null;
    this.services = new Map(); // service_name -> [instances]
    this.kv = new Map(); // key -> value
    this.health = new Map(); // service_name -> health status
    this.kvErrors = new Map(); // key -> { status, body, headers }
    this.requestLog = [];
    this.healthBehavior = null;
  }

  start() {
    this.server = Bun.serve({
      port: this.port,
      fetch: (req) => this.handleRequest(req),
    });
    return this;
  }

  stop() {
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
    this.services.clear();
    this.kv.clear();
    this.health.clear();
    this.kvErrors.clear();
    this.requestLog = [];
    this.healthBehavior = null;
  }

  async handleRequest(req) {
    const url = new URL(req.url);
    const path = url.pathname;
    const method = req.method;

    this.requestLog.push({
      method,
      path,
      query: Object.fromEntries(url.searchParams.entries()),
      headers: Object.fromEntries(req.headers.entries()),
    });

    // Agent API
    if (path === "/v1/agent/self") {
      return this.jsonResponse({
        Config: { Datacenter: "dc1", NodeName: "mock-node" },
      });
    }

    // Service Registration
    if (path === "/v1/agent/service/register" && method === "PUT") {
      const body = await req.json();
      this.registerService(body);
      return new Response(null, { status: 200 });
    }

    // Service Deregistration
    const deregisterMatch = path.match(
      /^\/v1\/agent\/service\/deregister\/(.+)$/
    );
    if (deregisterMatch && method === "PUT") {
      this.deregisterService(deregisterMatch[1]);
      return new Response(null, { status: 200 });
    }

    // Catalog Services
    if (path === "/v1/catalog/services") {
      const services = {};
      for (const [name, instances] of this.services) {
        services[name] = instances[0]?.tags || [];
      }
      return this.jsonResponse(services);
    }

    // Catalog Service by Name
    const catalogServiceMatch = path.match(/^\/v1\/catalog\/service\/(.+)$/);
    if (catalogServiceMatch) {
      const serviceName = catalogServiceMatch[1];
      const instances = this.services.get(serviceName) || [];
      return this.jsonResponse(
        instances.map((inst) => ({
          ID: inst.id,
          Node: "mock-node",
          Address: inst.address || "127.0.0.1",
          Datacenter: "dc1",
          ServiceID: inst.id,
          ServiceName: serviceName,
          ServiceAddress: inst.address || "127.0.0.1",
          ServicePort: inst.port,
          ServiceTags: inst.tags || [],
          ServiceMeta: inst.meta || {},
        }))
      );
    }

    // Health Check - Service
    const healthServiceMatch = path.match(/^\/v1\/health\/service\/(.+)$/);
    if (healthServiceMatch) {
      const serviceName = healthServiceMatch[1];
      const passing = url.searchParams.get("passing") === "true";
      const tag = url.searchParams.get("tag");
      const instances = this.services.get(serviceName) || [];

      const results = instances
        .filter((inst) => {
          if (tag && !(inst.tags || []).includes(tag)) {
            return false;
          }
          if (!passing) return true;
          const health = this.health.get(`${serviceName}:${inst.id}`);
          return health !== "critical";
        })
        .map((inst) => ({
          Node: {
            ID: "mock-node-id",
            Node: "mock-node",
            Address: "127.0.0.1",
            Datacenter: "dc1",
          },
          Service: {
            ID: inst.id,
            Service: serviceName,
            Address: inst.address || "127.0.0.1",
            Port: inst.port,
            Tags: inst.tags || [],
            Meta: inst.meta || {},
          },
          Checks: [
            {
              Node: "mock-node",
              CheckID: `service:${inst.id}`,
              Name: "Service health",
              Status:
                this.health.get(`${serviceName}:${inst.id}`) || "passing",
              ServiceID: inst.id,
              ServiceName: serviceName,
            },
          ],
        }));

      const behavior = this.healthBehavior;
      if (behavior?.delayMs) {
        await Bun.sleep(behavior.delayMs);
      }
      if (behavior?.rawBody !== undefined || behavior?.status !== undefined) {
        if (behavior.chunked) {
          const raw = behavior.rawBody ?? JSON.stringify(results);
          const midpoint = Math.max(1, Math.floor(raw.length / 2));
          const encoder = new TextEncoder();
          return new Response(new ReadableStream({
            start(controller) {
              controller.enqueue(encoder.encode(raw.slice(0, midpoint)));
              controller.enqueue(encoder.encode(raw.slice(midpoint)));
              controller.close();
            },
          }), {
            status: behavior.status ?? 200,
            headers: behavior.headers || { "Content-Type": "application/json" },
          });
        }
        return new Response(behavior.rawBody ?? JSON.stringify(results), {
          status: behavior.status ?? 200,
          headers:
            behavior.headers ||
            {
              "Content-Type": "application/json",
              "X-Consul-Index": "1",
            },
        });
      }

      return this.jsonResponse(results);
    }

    // Health Checks
    if (path === "/v1/health/state/passing") {
      return this.jsonResponse([]);
    }

    // KV Store - GET
    const kvMatch = path.match(/^\/v1\/kv\/(.+)$/);
    if (kvMatch && method === "GET") {
      const key = kvMatch[1];
      const recurse = url.searchParams.has("recurse");
      const keys = url.searchParams.has("keys");

       const kvError = this.kvErrors.get(key);
       if (kvError) {
        return new Response(kvError.body ?? "", {
          status: kvError.status,
          headers: kvError.headers || { "Content-Type": "application/json" },
        });
      }

      if (keys) {
        const matchingKeys = [...this.kv.keys()].filter((k) =>
          k.startsWith(key)
        );
        return this.jsonResponse(matchingKeys);
      }

      if (recurse) {
        const results = [];
        for (const [k, v] of this.kv) {
          if (k.startsWith(key)) {
            results.push({
              Key: k,
              Value: Buffer.from(v).toString("base64"),
              CreateIndex: 1,
              ModifyIndex: 1,
              LockIndex: 0,
              Flags: 0,
            });
          }
        }
        if (results.length === 0) {
          return new Response("", { status: 404, headers: { "Content-Length": "0" } });
        }
        return this.jsonResponse(results);
      }

      const value = this.kv.get(key);
      if (value === undefined) {
        return new Response("", { status: 404, headers: { "Content-Length": "0" } });
      }

      return this.jsonResponse([
        {
          Key: key,
          Value: Buffer.from(value).toString("base64"),
          CreateIndex: 1,
          ModifyIndex: 1,
          LockIndex: 0,
          Flags: 0,
        },
      ]);
    }

    // KV Store - PUT
    if (kvMatch && method === "PUT") {
      const key = kvMatch[1];
      const body = await req.text();
      this.kv.set(key, body);
      return new Response("true", { status: 200 });
    }

    // KV Store - DELETE
    if (kvMatch && method === "DELETE") {
      const key = kvMatch[1];
      const recurse = url.searchParams.has("recurse");

      if (recurse) {
        for (const k of [...this.kv.keys()]) {
          if (k.startsWith(key)) {
            this.kv.delete(k);
          }
        }
      } else {
        this.kv.delete(key);
      }
      return new Response("true", { status: 200 });
    }

    // Status - Leader
    if (path === "/v1/status/leader") {
      return new Response('"127.0.0.1:8300"', {
        headers: { "Content-Type": "application/json" },
      });
    }

    // Not found
    return new Response("", { status: 404, headers: { "Content-Length": "0" } });
  }

  jsonResponse(data) {
    return new Response(JSON.stringify(data), {
      headers: {
        "Content-Type": "application/json",
        "X-Consul-Index": "1",
      },
    });
  }

  // Helper methods for test setup
  registerService(service) {
    const name = service.Name || service.Service;
    const instances = this.services.get(name) || [];
    instances.push({
      id: service.ID || name,
      address: service.Address || "127.0.0.1",
      port: service.Port || 8080,
      tags: service.Tags || [],
      meta: service.Meta || {},
    });
    this.services.set(name, instances);
  }

  deregisterService(serviceId) {
    for (const [name, instances] of this.services) {
      const filtered = instances.filter((inst) => inst.id !== serviceId);
      if (filtered.length !== instances.length) {
        this.services.set(name, filtered);
        break;
      }
    }
  }

  addService(name, instances) {
    this.services.set(
      name,
      instances.map((inst) => ({
        id: inst.id || `${name}-${Math.random().toString(36).slice(2, 8)}`,
        address: inst.address || "127.0.0.1",
        port: inst.port || 8080,
        tags: inst.tags || [],
        meta: inst.meta || {},
      }))
    );
  }

  setServiceHealth(serviceName, instanceId, status) {
    this.health.set(`${serviceName}:${instanceId}`, status);
  }

  setKV(key, value) {
    this.kv.set(key, value);
    this.kvErrors.delete(key);
  }

  setKVError(key, status, body = "", headers = { "Content-Type": "application/json" }) {
    this.kvErrors.set(key, { status, body, headers });
  }

  getKV(key) {
    return this.kv.get(key);
  }

  clearServices() {
    this.services.clear();
    this.health.clear();
  }

  clearKV() {
    this.kv.clear();
  }

  getRequests() {
    return [...this.requestLog];
  }

  getLastRequest() {
    return this.requestLog[this.requestLog.length - 1];
  }

  clearLog() {
    this.requestLog = [];
  }

  setHealthBehavior(behavior) {
    this.healthBehavior = behavior;
  }

  clearHealthBehavior() {
    this.healthBehavior = null;
  }
}

export function createConsulMock(port = 8500) {
  return new ConsulMock(port).start();
}
