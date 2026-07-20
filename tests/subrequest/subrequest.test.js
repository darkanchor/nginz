import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { readFileSync } from "fs";
import { join } from "path";
import {
  startNginz,
  teardownModule,
  prepareMockPorts,
  testFetch,
  createRedisMock,
  createPostgresMock,
  createConsulMock,
  createHTTPMock,
  MOCK_PORTS,
} from "../harness.js";
import { signedUpstreamResponse } from "../mocks/wechatpay.js";

const WECHATPAY_FIXTURES = join(process.cwd(), "tests", "wechatpay", "fixtures");
const PLATFORM_PRIVATE_KEY = readFileSync(
  join(WECHATPAY_FIXTURES, "test_private.pem"),
  "utf8",
);
const PLATFORM_SERIAL = "PLATFORMSERIAL456";

const MODULE = "subrequest";
const MOCK_PORT_LIST = [
  MOCK_PORTS.REDIS,
  MOCK_PORTS.POSTGRES,
  MOCK_PORTS.CONSUL,
  MOCK_PORTS.HTTP,
];

let redisMock;
let pgMock;
let consulMock;
let httpMock;

async function waitFor(check, timeoutMs = 3000, intervalMs = 25) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (check()) return;
    await Bun.sleep(intervalMs);
  }
  expect(check()).toBe(true);
}

beforeAll(async () => {
  // njs/subrequest suites share these fixed mock ports across files.
  await prepareMockPorts(...MOCK_PORT_LIST);

  redisMock = createRedisMock(MOCK_PORTS.REDIS);
  redisMock.setValue("_redis/get/session-token", "active");

  pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);
  pgMock.setQueryHandler(
    /pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i,
    () => ({ columns: ["dummy"], rows: [] }),
  );
  pgMock.setQueryHandler(/permissions/i, () => ({
    columns: ["id", "action"],
    rows: [["1", "read"]],
  }));

  consulMock = createConsulMock(MOCK_PORTS.CONSUL);
  consulMock.setKV("feature-flag", "enabled");
  consulMock.registerService({
    Name: "api-service",
    ID: "api-svc-1",
    Address: "127.0.0.1",
    Port: 8001,
  });

  httpMock = createHTTPMock(MOCK_PORTS.HTTP);
  // Properly signed response → wechatpay sig verification succeeds → 200
  httpMock.get("/_wechatpay/pay", () =>
    signedUpstreamResponse('{"result":"ok"}', {
      privateKey: PLATFORM_PRIVATE_KEY,
      serial: PLATFORM_SERIAL,
    }),
  );
  // Upstream error → wechatpay forwards 401 upstream status → auth_request denies
  httpMock.get("/_wechatpay/fail", {
    status: 401,
    body: '{"error":"unauthorized"}',
    headers: { "Content-Type": "application/json" },
  });

  await startNginz("tests/subrequest/nginx.conf", MODULE);
}, 60000);

afterAll(async () => {
  await teardownModule(
    MODULE,
    [redisMock, pgMock, consulMock, httpMock],
    MOCK_PORT_LIST,
  );
});

describe("upstream modules as native auth_request subrequest targets", () => {
  test("redis GET subrequest via auth_request completes and allows main request", async () => {
    const res = await testFetch("/redis-gate");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("redis-granted");
  });

  test("pgrest GET subrequest via auth_request completes and allows main request", async () => {
    const res = await testFetch("/pg-gate");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("pg-granted");
  });

  test("consul KV subrequest via auth_request completes and allows main request", async () => {
    const res = await testFetch("/consul-kv-gate");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("consul-granted");
  });

  test("consul services subrequest via auth_request completes and allows main request", async () => {
    const res = await testFetch("/consul-svc-gate");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("consul-svc-granted");
  });

  test("consul catalog subrequest via auth_request completes and allows main request", async () => {
    const res = await testFetch("/consul-catalog-gate");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("consul-catalog-granted");
  });

  test("wechatpay proxy subrequest with signed upstream response allows main request", async () => {
    const res = await testFetch("/wechatpay-gate");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("wechatpay-granted");
  });

  test("wechatpay proxy subrequest with upstream 4xx response denies main request", async () => {
    const res = await testFetch("/wechatpay-deny-gate");
    expect(res.status).toBe(401);
  });
});

describe("upstream modules under SSI subrequests", () => {
  test("redis GET subrequest via SSI returns upstream body", async () => {
    const res = await testFetch("/ssi/redis");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("active");
  });

  test("pgrest GET subrequest via SSI returns upstream body", async () => {
    const res = await testFetch("/ssi/pgrest");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("read");
  });

  test("consul KV subrequest via SSI returns upstream body", async () => {
    const res = await testFetch("/ssi/consul-kv");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("enabled");
  });

  test("consul services subrequest via SSI returns upstream body", async () => {
    const res = await testFetch("/ssi/consul-services");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("api-svc-1");
  });

  test("consul catalog subrequest via SSI returns upstream body", async () => {
    const res = await testFetch("/ssi/consul-catalog");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("api-service");
  });

  test("wechatpay proxy subrequest via SSI returns verified upstream body", async () => {
    const res = await testFetch("/ssi/wechatpay");
    expect(res.status).toBe(200);
    expect(await res.text()).toContain('"result":"ok"');
  });
});

describe("upstream modules under mirror subrequests", () => {
  test("redis mirror subrequest executes in background", async () => {
    for (let i = 0; i < 3; i++) {
      const res = await testFetch("/mirror/redis");
      expect(res.status).toBe(200);
      expect((await res.text()).trim()).toContain("redis");
    }
  });

  test("pgrest mirror subrequest executes in background", async () => {
    for (let i = 0; i < 3; i++) {
      const res = await testFetch("/mirror/pgrest");
      expect(res.status).toBe(200);
      expect((await res.text()).trim()).toContain("pgrest");
    }
  });

  test("consul KV mirror subrequest executes in background", async () => {
    consulMock.clearLog();

    const res = await testFetch("/mirror/consul-kv");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toContain("consul-kv");

    await waitFor(() =>
      consulMock.getRequests().some((req) => req.path === "/v1/kv/feature-flag"),
    );
  });

  test("consul catalog mirror subrequest executes in background", async () => {
    consulMock.clearLog();

    const res = await testFetch("/mirror/consul-catalog");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toContain("consul-catalog");

    await waitFor(() =>
      consulMock.getRequests().some((req) => req.path === "/v1/catalog/services"),
    );
  });

  test("wechatpay mirror subrequest executes in background", async () => {
    httpMock.clearLog();

    const res = await testFetch("/mirror/wechatpay");
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toContain("wechatpay");

    await waitFor(() => httpMock.getRequestsFor("/_wechatpay/pay", "GET").length === 1);
  });
});
