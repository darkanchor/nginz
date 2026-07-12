import { describe, test, expect, beforeAll, afterAll, beforeEach } from "bun:test";
import http from "http";
import net from "net";
import { readFileSync } from "fs";
import { join } from "path";
import {
  constants,
  privateDecrypt,
} from "node:crypto";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createHTTPMock,
  MOCK_PORTS,
} from "../harness.js";
import {
  buildWechatpayHeaders as buildWechatpayHeadersBase,
  signedUpstreamResponse as signedUpstreamResponseBase,
  encryptWechatpayResource,
  verifyProxyAuthorization as verifyProxyAuthorizationBase,
} from "../mocks/wechatpay.js";

const MODULE = "wechatpay";
const FIXTURES_DIR = join(process.cwd(), "tests", MODULE, "fixtures");
const PRIVATE_KEY = readFileSync(join(FIXTURES_DIR, "test_private.pem"), "utf8");
const PUBLIC_KEY = readFileSync(join(FIXTURES_DIR, "test_public.pem"), "utf8");
const APICLIENT_SERIAL = "APICLIENTSERIAL123";
const PLATFORM_SERIAL = "PLATFORMSERIAL456";
const MCH_ID = "1900001111";
const AES_SECRET = "0123456789abcdef0123456789abcdef";

let upstreamMock = null;

function withRawGateway(rawResponseFactory, testFn) {
  return new Promise((resolve, reject) => {
    const server = net.createServer((socket) => {
      socket.once("data", () => {
        socket.write(rawResponseFactory());
        socket.end();
      });
    });

    server.on("error", reject);
    server.listen(19005, "127.0.0.1", async () => {
      try {
        await testFn();
        server.close((err) => (err ? reject(err) : resolve()));
      } catch (error) {
        server.close(() => reject(error));
      }
    });
  });
}

function httpRequest(options, steps) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port: 8888,
        path: "/notify",
        method: "POST",
        ...options,
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
        res.on("end", () => {
          resolve({
            status: res.statusCode,
            headers: new Map(
              Object.entries(res.headers).map(([key, value]) => [
                key.toLowerCase(),
                Array.isArray(value) ? value.join(", ") : String(value ?? ""),
              ])
            ),
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      }
    );

    req.on("error", reject);

    (async () => {
      try {
        await steps(req);
      } catch (error) {
        req.destroy(error);
      }
    })();
  });
}

function httpRequestWithContinue(options, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(
      {
        host: "127.0.0.1",
        port: 8888,
        path: "/notify",
        method: "POST",
        ...options,
      },
      (res) => {
        const chunks = [];
        res.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
        res.on("end", () => {
          resolve({
            status: res.statusCode,
            headers: new Map(
              Object.entries(res.headers).map(([key, value]) => [
                key.toLowerCase(),
                Array.isArray(value) ? value.join(", ") : String(value ?? ""),
              ])
            ),
            body: Buffer.concat(chunks).toString("utf8"),
          });
        });
      }
    );

    req.on("continue", () => {
      req.end(body);
    });
    req.on("error", reject);
    req.flushHeaders();
  });
}

function buildWechatpayHeaders(body, overrides = {}) {
  return buildWechatpayHeadersBase(body, {
    privateKey: PRIVATE_KEY,
    serial: PLATFORM_SERIAL,
    ...overrides,
  });
}

function verifyProxyAuthorization(header, { method, path, query, body }) {
  expect(verifyProxyAuthorizationBase(header, {
    method,
    path,
    query,
    body,
    publicKey: PUBLIC_KEY,
    mchId: MCH_ID,
    serial: APICLIENT_SERIAL,
  })).toBe(true);
}

function signedUpstreamResponse(body, overrides = {}) {
  return signedUpstreamResponseBase(body, {
    privateKey: PRIVATE_KEY,
    serial: PLATFORM_SERIAL,
    ...overrides,
  });
}

describe("wechatpay module", () => {
  beforeAll(async () => {
    upstreamMock = createHTTPMock(MOCK_PORTS.HTTP);
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    if (upstreamMock) {
      upstreamMock.stop();
    }
    cleanupRuntime(MODULE);
  });

  beforeEach(() => {
    upstreamMock.reset();
  });

  describe("OAEP handlers", () => {
    test("encrypts request bodies and decrypts them back", async () => {
      const plaintext = "wechatpay secret payload";

      const encryptRes = await fetch(`${TEST_URL}/encrypt`, {
        method: "POST",
        body: plaintext,
      });
      expect(encryptRes.status).toBe(200);

      const ciphertext = await encryptRes.text();
      expect(ciphertext).not.toBe(plaintext);

      const nodePlaintext = privateDecrypt(
        {
          key: PRIVATE_KEY,
          padding: constants.RSA_PKCS1_OAEP_PADDING,
        },
        Buffer.from(ciphertext, "base64")
      ).toString("utf8");
      expect(nodePlaintext).toBe(plaintext);

      const decryptRes = await fetch(`${TEST_URL}/decrypt`, {
        method: "POST",
        body: ciphertext,
      });
      expect(decryptRes.status).toBe(200);
      expect(await decryptRes.text()).toBe(plaintext);
    });

    test("returns 400 for invalid OAEP ciphertext", async () => {
      const res = await fetch(`${TEST_URL}/decrypt`, {
        method: "POST",
        body: "not-valid-base64-or-rsa",
      });
      expect(res.status).toBe(400);
    });
  });

  describe("access verification", () => {
    test("rejects requests with invalid signatures", async () => {
      const body = JSON.stringify({ event: "bad" });
      const headers = buildWechatpayHeaders(body, {
        signature: "invalid-signature",
      });

      const res = await fetch(`${TEST_URL}/notify`, {
        method: "POST",
        headers,
        body,
      });

      expect(res.status).toBe(401);
    });

    test("accepts valid signed requests and preserves request body", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-1" });
      const headers = buildWechatpayHeaders(body);

      const res = await fetch(`${TEST_URL}/notify`, {
        method: "POST",
        headers,
        body,
      });

      expect(res.status).toBe(200);
      expect(await res.text()).toBe(`verified:${body}`);
    });

    test("accepts valid signed requests split across writes", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-split" });
      const res = await httpRequest(
        {
          path: "/notify",
          headers: buildWechatpayHeaders(body),
        },
        async (req) => {
          req.write(body.slice(0, 12));
          await Bun.sleep(20);
          req.end(body.slice(12));
        }
      );

      expect(res.status).toBe(200);
      expect(res.body).toBe(`verified:${body}`);
    });

    test("accepts valid signed chunked requests", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-chunked" });
      const res = await httpRequest(
        {
          path: "/notify",
          headers: {
            ...buildWechatpayHeaders(body),
            "Transfer-Encoding": "chunked",
          },
        },
        async (req) => {
          req.write(body.slice(0, 10));
          await Bun.sleep(10);
          req.write(body.slice(10, 24));
          await Bun.sleep(10);
          req.end(body.slice(24));
        }
      );

      expect(res.status).toBe(200);
      expect(res.body).toBe(`verified:${body}`);
    });

    test("accepts valid signed requests with Expect 100-continue", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-continue" });
      const res = await httpRequestWithContinue(
        {
          path: "/notify",
          headers: {
            ...buildWechatpayHeaders(body),
            Expect: "100-continue",
          },
        },
        body
      );

      expect(res.status).toBe(200);
      expect(res.body).toBe(`verified:${body}`);
    });

    test("accepts valid signed requests when nginx spills body to a temp file", async () => {
      const body = JSON.stringify({
        event: "payment.succeeded",
        id: "evt-spill",
        payload: "x".repeat(6000),
      });
      const headers = buildWechatpayHeaders(body);

      const res = await fetch(`${TEST_URL}/notify-spill`, {
        method: "POST",
        headers,
        body,
      });

      expect(res.status).toBe(200);
      expect(await res.text()).toBe(`verified:${body}`);
    });

    test("rejects requests when Request-ID is missing", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-no-request-id" });
      const headers = buildWechatpayHeaders(body);
      delete headers["Request-ID"];

      const res = await fetch(`${TEST_URL}/notify`, {
        method: "POST",
        headers,
        body,
      });

      expect(res.status).toBe(401);
    });

    test("rejects requests when Wechatpay-Serial does not match configured platform serial", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-bad-serial" });
      const headers = buildWechatpayHeaders(body, {
        serial: "WRONGSERIAL999",
      });

      const res = await fetch(`${TEST_URL}/notify`, {
        method: "POST",
        headers,
        body,
      });

      expect(res.status).toBe(401);
    });

    test("rejects a correctly signed request outside the freshness window", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-stale" });
      const headers = buildWechatpayHeaders(body, {
        timestamp: String(Math.floor(Date.now() / 1000) - 301),
      });

      const res = await fetch(`${TEST_URL}/notify`, {
        method: "POST",
        headers,
        body,
      });

      expect(res.status).toBe(401);
    });

    test("rejects replay of a previously accepted signed nonce", async () => {
      const body = JSON.stringify({ event: "payment.succeeded", id: "evt-replay" });
      const headers = buildWechatpayHeaders(body, { nonce: "one-time-replay-nonce" });

      const first = await fetch(`${TEST_URL}/notify`, { method: "POST", headers, body });
      expect(first.status).toBe(200);
      const replayHeaders = { ...headers, Connection: "close" };
      const replays = await Promise.all(Array.from({ length: 12 }, () =>
        fetch(`${TEST_URL}/notify`, { method: "POST", headers: replayHeaders, body })
      ));
      for (const replay of replays) expect(replay.status).toBe(401);
    });

    test("decrypts AES-GCM resource bodies during access verification", async () => {
      const plaintext = JSON.stringify({ order_id: "order-123", amount: 88 });
      const resource = encryptWechatpayResource(plaintext, {
        aesKey: AES_SECRET,
        associatedData: "transaction",
        nonce: "nonce-123456",
      });
      const body = JSON.stringify({
        id: "notify-1",
        event_type: "TRANSACTION.SUCCESS",
        resource,
      });
      const headers = buildWechatpayHeaders(body);

      const res = await fetch(`${TEST_URL}/notify-aes`, {
        method: "POST",
        headers,
        body,
      });

      expect(res.status).toBe(200);
      const text = await res.text();
      expect(text).toContain('"plaintxt":"');
      expect(text).toContain('\\"order_id\\":\\"order-123\\"');
      expect(text).toContain('"associated_data":"transaction"');
    });
  });

  describe("proxy signing and response verification", () => {
    test("signs upstream requests and forwards verified responses", async () => {
      let observedRequest = null;

      upstreamMock.post("/proxy", async (req, url) => {
        const body = await req.text();
        observedRequest = {
          authorization: req.headers.get("authorization"),
          xTestHeader: req.headers.get("x-test-header"),
          method: req.method,
          path: url.pathname,
          query: url.searchParams.toString(),
          body,
        };

        return signedUpstreamResponse(JSON.stringify({ ok: true, echoedBody: body }));
      });

      const requestBody = JSON.stringify({ amount: 88, currency: "CNY" });
      const res = await fetch(`${TEST_URL}/proxy?foo=bar`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Test-Header": "present",
        },
        body: requestBody,
      });

      expect(res.status).toBe(200);
      await expect(res.json()).resolves.toEqual({
        ok: true,
        echoedBody: requestBody,
      });

      expect(observedRequest).toBeTruthy();
      expect(observedRequest.xTestHeader).toBe("present");
      expect(observedRequest.authorization).toBeTruthy();
      verifyProxyAuthorization(observedRequest.authorization, observedRequest);

      const logged = upstreamMock.getLastRequest();
      expect(logged.path).toBe("/proxy");
      expect(logged.query).toEqual({ foo: "bar" });
      expect(logged.body).toEqual({ amount: 88, currency: "CNY" });
    });

    test("turns upstream responses into 401 when signature verification fails", async () => {
      let observedBody = null;

      upstreamMock.post("/proxy-bad", async (req) => {
        observedBody = await req.text();

        return signedUpstreamResponse(JSON.stringify({ ok: false }), {
          signature: "broken-signature",
        });
      });

      const res = await fetch(`${TEST_URL}/proxy-bad`, {
        method: "POST",
        headers: {
          "Content-Type": "text/plain",
        },
        body: "tamper-check",
      });

      expect(observedBody).toBe("tamper-check");
      expect(res.status).toBe(401);
    });

    test("forwards verified chunked upstream responses", async () => {
      upstreamMock.post("/proxy", async (req) => {
        const body = await req.text();
        const responseBody = JSON.stringify({ ok: true, echoedBody: body });
        const signed = signedUpstreamResponse(responseBody);
        const encoder = new TextEncoder();
        const chunks = [
          responseBody.slice(0, 8),
          responseBody.slice(8, 21),
          responseBody.slice(21),
        ];
        let index = 0;
        return new Response(
          new ReadableStream({
            pull(controller) {
              if (index >= chunks.length) {
                controller.close();
                return;
              }
              controller.enqueue(encoder.encode(chunks[index++]));
            },
          }),
          {
            status: signed.status,
            headers: signed.headers,
          }
        );
      });

      const res = await fetch(`${TEST_URL}/proxy`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ amount: 66 }),
      });

      expect(res.status).toBe(200);
      await expect(res.json()).resolves.toEqual({
        ok: true,
        echoedBody: JSON.stringify({ amount: 66 }),
      });
    });

    test("turns upstream responses into 401 when platform serial mismatches", async () => {
      upstreamMock.post("/proxy-bad", async (req) => {
        const body = await req.text();
        return signedUpstreamResponse(JSON.stringify({ ok: true, echoedBody: body }), {
          serial: "WRONGSERIAL999",
        });
      });

      const res = await fetch(`${TEST_URL}/proxy-bad`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ amount: 12 }),
      });

      expect(res.status).toBe(401);
    });

    test("treats malformed upstream status lines as bad gateway", async () => {
      await withRawGateway(
        () =>
          "HTTP/1.1 TWOHUNDRED OK\r\n" +
          "Content-Length: 2\r\n" +
          "\r\n" +
          "ok",
        async () => {
          const res = await fetch(`${TEST_URL}/proxy-raw`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ amount: 1 }),
          });

          expect(res.status).toBe(502);
        }
      );
    });

    test("passes verified Wechat Pay response headers downstream", async () => {
      upstreamMock.post("/proxy", async (req) => {
        const body = await req.text();
        return signedUpstreamResponse(JSON.stringify({ ok: true, echoedBody: body }), {
          requestId: "wechatpay-resp-123",
          extraHeaders: {
            "Wechatpay-Signature-Type": "WECHATPAY2-SHA256-RSA2048",
          },
        });
      });

      const res = await fetch(`${TEST_URL}/proxy`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ amount: 10 }),
      });

      expect(res.status).toBe(200);
      expect(res.headers.get("request-id")).toBe("wechatpay-resp-123");
      expect(res.headers.get("wechatpay-serial")).toBe(PLATFORM_SERIAL);
      expect(res.headers.get("wechatpay-signature")).toBeTruthy();
      expect(res.headers.get("wechatpay-signature-type")).toBe("WECHATPAY2-SHA256-RSA2048");
    });

    test("signs spilled request bodies with the full body content", async () => {
      let observedRequest = null;

      upstreamMock.post("/proxy-spill", async (req, url) => {
        const body = await req.text();
        observedRequest = {
          authorization: req.headers.get("authorization"),
          method: req.method,
          path: url.pathname,
          query: url.searchParams.toString(),
          body,
        };
        return signedUpstreamResponse(JSON.stringify({ ok: true, echoedBody: body }));
      });

      const requestBody = JSON.stringify({
        amount: 88,
        currency: "CNY",
        note: "x".repeat(6000),
      });
      const res = await fetch(`${TEST_URL}/proxy-spill?foo=bar`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: requestBody,
      });

      expect(res.status).toBe(200);
      await expect(res.json()).resolves.toEqual({
        ok: true,
        echoedBody: requestBody,
      });

      expect(observedRequest).toBeTruthy();
      verifyProxyAuthorization(observedRequest.authorization, observedRequest);
      expect(observedRequest.body).toBe(requestBody);
    });
  });
});
