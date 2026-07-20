import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  MOCK_PORTS,
  teardownModule,
  prepareMockPorts,
  testFetch,
} from "../harness.js";

const MODULE = "njs";
const MOCK_PORT = MOCK_PORTS.HTTP;



describe("njs HTTP features", () => {
  let mock;

  beforeAll(async () => {
    await prepareMockPorts(MOCK_PORT);
    mock = createHTTPMock(MOCK_PORT);
    mock.get("/data", () => new Response("fetched-ok"));
    mock.get("/json", () => Response.json({ value: "from-mock" }));
    mock.post("/echo", async (req) => new Response(await req.text()));
    mock.get("/headers-check", (req) => {
      const token = req.headers.get("x-token");
      return new Response(token ? `token=${token}` : "no-token");
    });

    await startNginz("tests/njs/http-features.conf", MODULE);
  });

  afterAll(async () => {
    await teardownModule(MODULE, [mock], [MOCK_PORT]);
  });

  describe("r.subrequest", () => {
    test("subrequest returns body from target location", async () => {
      const res = await testFetch(`/subrequest/echo?msg=hello`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("hello");
    });

    test("subrequest passes different args", async () => {
      const res = await testFetch(`/subrequest/echo?msg=world`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("world");
    });

    test("parallel subrequests via Promise.all complete correctly", async () => {
      const res = await testFetch(`/subrequest/join`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body).toEqual(["foo", "bar"]);
    });

    test("subrequest propagates non-200 status code", async () => {
      const res = await testFetch(`/subrequest/status`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("204");
    });
  });

  describe("ngx.fetch", () => {
    test("GET request returns upstream body", async () => {
      const res = await testFetch(`/fetch/get?port=${MOCK_PORT}`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("fetched-ok");
    });

    test("GET request parses JSON from upstream", async () => {
      const res = await testFetch(`/fetch/json?port=${MOCK_PORT}`);
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.status).toBe(200);
      expect(body.value).toBe("from-mock");
    });

    test("POST request forwards body to upstream", async () => {
      const payload = JSON.stringify({ x: 1 });
      const res = await testFetch(`/fetch/post?port=${MOCK_PORT}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: payload,
      });
      expect(res.status).toBe(200);
      expect(await res.text()).toBe(payload);
    });

    test("request sends custom headers to upstream", async () => {
      const res = await testFetch(`/fetch/headers?port=${MOCK_PORT}`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("token=secret");
    });
  });

  describe("js_shared_dict", () => {
    test("set and get a key", async () => {
      await testFetch(`/dict/set?key=foo&val=bar`);
      const res = await testFetch(`/dict/get?key=foo`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("bar");
    });

    test("get missing key returns empty string", async () => {
      const res = await testFetch(`/dict/get?key=__missing__`);
      expect(res.status).toBe(200);
      expect(await res.text()).toBe("");
    });

    test("overwrite a key", async () => {
      await testFetch(`/dict/set?key=x&val=first`);
      await testFetch(`/dict/set?key=x&val=second`);
      const res = await testFetch(`/dict/get?key=x`);
      expect(await res.text()).toBe("second");
    });

    test("delete removes the key", async () => {
      await testFetch(`/dict/set?key=del_me&val=here`);
      await testFetch(`/dict/delete?key=del_me`);
      const res = await testFetch(`/dict/get?key=del_me`);
      expect(await res.text()).toBe("");
    });

    test("counter increments across requests", async () => {
      const key = "ctr_" + Date.now();
      const r1 = await testFetch(`/dict/incr?key=${key}`);
      const r2 = await testFetch(`/dict/incr?key=${key}`);
      const r3 = await testFetch(`/dict/incr?key=${key}`);
      expect(await r1.text()).toBe("1");
      expect(await r2.text()).toBe("2");
      expect(await r3.text()).toBe("3");
    });

    test("independent keys do not interfere", async () => {
      await testFetch(`/dict/set?key=ka&val=alpha`);
      await testFetch(`/dict/set?key=kb&val=beta`);
      const ra = await testFetch(`/dict/get?key=ka`);
      const rb = await testFetch(`/dict/get?key=kb`);
      expect(await ra.text()).toBe("alpha");
      expect(await rb.text()).toBe("beta");
    });
  });
});
