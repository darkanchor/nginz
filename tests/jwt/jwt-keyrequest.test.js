import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";
import { createHmac } from "crypto";
import { writeFileSync, unlinkSync } from "fs";

const MODULE = "jwt";

// These must match the JWKS/keyval secrets in nginx.keyrequest.conf
const SUBREQ_SECRET = "subreq-secret-hs256-test-32bytes!";
const SUBREQ_SECRET_A = "subreq-secret-a-hs256-test-32bytes!!";
const SUBREQ_SECRET_B = "subreq-secret-b-hs256-test-32bytes!!";
const SUBREQ_SECRET_C = "subreq-secret-c-hs256-test-32bytes!!";
const SUBREQ_KEYVAL_SECRET = "subreq-keyval-secret-hs256-32bytes!!";
const DUP_SECRET_VALID = "dup-secret-valid-hs256-32bytes!!";
const HTTP_SCOPE_SECRET = "subreq-http-secret-hs256-32bytes!!";
const SERVER_SCOPE_SECRET = "subreq-server-secret-hs256-32bytes!!";
const LOCATION_SCOPE_SECRET = "subreq-location-secret-hs256-32bytes";
const ORDER_SECRET_A = "order-secret-a-hs256-32bytes!!!!";
const ORDER_SECRET_C = "order-secret-c-hs256-32bytes!!!!";
let compressedServer;

function buildKeyvalSet(prefix, count, firstSecret) {
  const obj = {};
  for (let i = 0; i < count; i++) {
    obj[`${prefix}-kid-${i}`] = i === 0 ? firstSecret : `${prefix}-filler-secret-${i}-hs256!!`;
  }
  return JSON.stringify(obj);
}

function createHS256Token(payload, secret, extraHeader = {}) {
  const header = { alg: "HS256", typ: "JWT", ...extraHeader };
  const headerB64 = Buffer.from(JSON.stringify(header)).toString("base64url");
  const payloadB64 = Buffer.from(JSON.stringify(payload)).toString("base64url");
  const data = `${headerB64}.${payloadB64}`;
  const sig = createHmac("sha256", secret)
    .update(data)
    .digest()
    .toString("base64url");
  return `${data}.${sig}`;
}

const FAR_FUTURE = 9999999999;

describe("JWT — Key Request (Subrequest)", () => {
  beforeAll(async () => {
    compressedServer = Bun.serve({
      port: 19005,
      async fetch(req) {
        const url = new URL(req.url);
        if (url.pathname === "/order-a") {
          await Bun.sleep(80);
          return new Response(buildKeyvalSet("order-a", 8, ORDER_SECRET_A), {
            headers: { "content-type": "application/json" },
          });
        }
        if (url.pathname === "/order-b") {
          await Bun.sleep(20);
          return new Response(buildKeyvalSet("order-b", 8, "order-secret-b-hs256-32bytes!!!!"), {
            headers: { "content-type": "application/json" },
          });
        }
        if (url.pathname === "/order-c") {
          return new Response(buildKeyvalSet("order-c", 8, ORDER_SECRET_C), {
            headers: { "content-type": "application/json" },
          });
        }
        return new Response(
          '{"keys":[{"kty":"oct","kid":"compressed-kid","k":"Y29tcHJlc3NlZC1zZWNyZXQtaHMyNTYtMzJieXRlcyEh","alg":"HS256"}]}',
          {
            headers: {
              "content-type": "application/json",
              "content-encoding": "gzip",
            },
          },
        );
      },
    });
    writeFileSync("tests/jwt/dup-local.json", JSON.stringify({ "dup-kid": DUP_SECRET_VALID }, null, 2));
    writeFileSync("tests/jwt/dup-local-invalid.json", JSON.stringify({ "dup-kid": "dup-secret-wrong-hs256-32bytes!!" }, null, 2));
    await startNginz("tests/jwt/nginx.keyrequest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    compressedServer?.stop(true);
    try { unlinkSync("tests/jwt/dup-local.json"); } catch {}
    try { unlinkSync("tests/jwt/dup-local-invalid.json"); } catch {}
    cleanupRuntime(MODULE);
  });

  test("accepts token signed with key fetched via subrequest", async () => {
    const token = createHS256Token({ sub: "test-user", exp: FAR_FUTURE }, SUBREQ_SECRET);
    const res = await fetch(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("KEYREQUEST OK");
  });

  test("rejects token with wrong secret (subrequest-loaded key mismatch)", async () => {
    const token = createHS256Token({ sub: "test-user", exp: FAR_FUTURE }, "wrong-secret-for-testing!!");
    const res = await fetch(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("rejects request without token on subrequest-protected location", async () => {
    const res = await fetch(`${TEST_URL}/protected`);
    expect(res.status).toBe(401);
  });

  test("accepts token on variable-based key_request URL", async () => {
    const token = createHS256Token({ sub: "test-var", exp: FAR_FUTURE }, SUBREQ_SECRET);
    const res = await fetch(`${TEST_URL}/protected-var`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("KEYREQUEST OK");
  });

  test("accepts token from the first of multiple jwt_key_request sources", async () => {
    const token = createHS256Token({ sub: "multi-a", exp: FAR_FUTURE }, SUBREQ_SECRET_A, { kid: "kid-a" });
    const res = await fetch(`${TEST_URL}/protected-multi`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MULTI OK");
  });

  test("accepts token from the second of multiple jwt_key_request sources", async () => {
    const token = createHS256Token({ sub: "multi-b", exp: FAR_FUTURE }, SUBREQ_SECRET_B, { kid: "kid-b" });
    const res = await fetch(`${TEST_URL}/protected-multi`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MULTI OK");
  });

  // Key accumulation order parity + request-key append semantics
  // Three jwt_key_request entries; each source provides one unique kid.
  // All three accumulate into the shared request_keys array regardless of
  // declaration or subrequest completion order, because all keys are tried.
  test("accumulates keys from all three jwt_key_request sources (first source)", async () => {
    const token = createHS256Token({ sub: "triple-a", exp: FAR_FUTURE }, SUBREQ_SECRET_A, { kid: "kid-a" });
    const res = await fetch(`${TEST_URL}/protected-triple`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST TRIPLE OK");
  });

  test("accumulates keys from all three jwt_key_request sources (second source)", async () => {
    const token = createHS256Token({ sub: "triple-b", exp: FAR_FUTURE }, SUBREQ_SECRET_B, { kid: "kid-b" });
    const res = await fetch(`${TEST_URL}/protected-triple`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST TRIPLE OK");
  });

  test("accumulates keys from all three jwt_key_request sources (third/last source)", async () => {
    const token = createHS256Token({ sub: "triple-c", exp: FAR_FUTURE }, SUBREQ_SECRET_C, { kid: "kid-c" });
    const res = await fetch(`${TEST_URL}/protected-triple`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST TRIPLE OK");
  });

  test("preserves declaration-order accumulation under parallel completion (first source retained)", async () => {
    const token = createHS256Token({ sub: "order-a", exp: FAR_FUTURE }, ORDER_SECRET_A, { kid: "order-a-kid-0" });
    const res = await fetch(`${TEST_URL}/protected-order`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST ORDER OK");
  });

  test("preserves declaration-order accumulation under parallel completion (last source trimmed by MAX_KEYS)", async () => {
    const token = createHS256Token({ sub: "order-c", exp: FAR_FUTURE }, ORDER_SECRET_C, { kid: "order-c-kid-0" });
    const res = await fetch(`${TEST_URL}/protected-order`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("accepts token on keyval-format jwt_key_request", async () => {
    const token = createHS256Token({ sub: "keyval-user", exp: FAR_FUTURE }, SUBREQ_KEYVAL_SECRET, { kid: "keyval-kid" });
    const res = await fetch(`${TEST_URL}/protected-keyval`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST KEYVAL OK");
  });

  test("rejects malformed subrequest body", async () => {
    const token = createHS256Token({ sub: "bad-body", exp: FAR_FUTURE }, SUBREQ_SECRET, { kid: "subreq-key" });
    const res = await fetch(`${TEST_URL}/protected-bad-body`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("rejects compressed subrequest response", async () => {
    const token = createHS256Token({ sub: "compressed", exp: FAR_FUTURE }, "compressed-secret-hs256-32bytes!!", { kid: "compressed-kid" });
    const res = await fetch(`${TEST_URL}/protected-compressed`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("child location accepts token from inherited parent key_request source", async () => {
    const token = createHS256Token({ sub: "inherit-a", exp: FAR_FUTURE }, DUP_SECRET_VALID, { kid: "dup-kid" });
    const res = await fetch(`${TEST_URL}/inherit-parent/child`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST INHERIT OK");
  });

  test("child location accepts token from child-added key_request source", async () => {
    const token = createHS256Token({ sub: "inherit-b", exp: FAR_FUTURE }, DUP_SECRET_VALID, { kid: "dup-kid" });
    const res = await fetch(`${TEST_URL}/inherit-parent/child`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST INHERIT OK");
  });

  test("duplicate kid works when valid subrequest source is declared after invalid one", async () => {
    const token = createHS256Token({ sub: "dup-a", exp: FAR_FUTURE }, DUP_SECRET_VALID, { kid: "dup-kid" });
    const res = await fetch(`${TEST_URL}/protected-dup-a`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST DUP A OK");
  });

  test("duplicate kid works when valid subrequest source is declared before invalid one", async () => {
    const token = createHS256Token({ sub: "dup-b", exp: FAR_FUTURE }, DUP_SECRET_VALID, { kid: "dup-kid" });
    const res = await fetch(`${TEST_URL}/protected-dup-b`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST DUP B OK");
  });

  test("mixed key_file and jwt_key_request accepts token from subrequest-loaded source", async () => {
    const token = createHS256Token({ sub: "mixed-a", exp: FAR_FUTURE }, DUP_SECRET_VALID, { kid: "dup-kid" });
    const res = await fetch(`${TEST_URL}/protected-mixed-a`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MIXED A OK");
  });

  test("mixed key_file and jwt_key_request accepts token from local key_file source", async () => {
    const token = createHS256Token({ sub: "mixed-b", exp: FAR_FUTURE }, DUP_SECRET_VALID, { kid: "dup-kid" });
    const res = await fetch(`${TEST_URL}/protected-mixed-b`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MIXED B OK");
  });

  test("inherited-only location accepts token from http-scope key_request source", async () => {
    const token = createHS256Token({ sub: "http-scope", exp: FAR_FUTURE }, HTTP_SCOPE_SECRET, { kid: "http-kid" });
    const res = await fetch(`${TEST_URL}/matrix-inherited`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MATRIX INHERITED OK");
  });

  test("inherited-only location accepts token from server-scope variable key_request source", async () => {
    const token = createHS256Token({ sub: "server-scope", exp: FAR_FUTURE }, SERVER_SCOPE_SECRET, { kid: "server-kid" });
    const res = await fetch(`${TEST_URL}/matrix-inherited`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MATRIX INHERITED OK");
  });

  test("override location still accepts token from http-scope inherited key_request source", async () => {
    const token = createHS256Token({ sub: "override-http", exp: FAR_FUTURE }, HTTP_SCOPE_SECRET, { kid: "http-kid" });
    const res = await fetch(`${TEST_URL}/matrix-override`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MATRIX OVERRIDE OK");
  });

  test("override location still accepts token from server-scope inherited variable key_request source", async () => {
    const token = createHS256Token({ sub: "override-server", exp: FAR_FUTURE }, SERVER_SCOPE_SECRET, { kid: "server-kid" });
    const res = await fetch(`${TEST_URL}/matrix-override`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MATRIX OVERRIDE OK");
  });

  test("override location accepts token from location-scope key_request source", async () => {
    const token = createHS256Token({ sub: "override-location", exp: FAR_FUTURE }, LOCATION_SCOPE_SECRET, { kid: "location-kid" });
    const res = await fetch(`${TEST_URL}/matrix-override`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST MATRIX OVERRIDE OK");
  });

  test("rejects token with wrong secret on variable-based key_request URL", async () => {
    const token = createHS256Token({ sub: "test-var", exp: FAR_FUTURE }, "wrong-secret-for-testing!!");
    const res = await fetch(`${TEST_URL}/protected-var`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("expired token rejected even with subrequest-loaded keys", async () => {
    const token = createHS256Token({
      sub: "expired-user",
      exp: Math.floor(Date.now() / 1000) - 3600,
    }, SUBREQ_SECRET);
    const res = await fetch(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("public endpoint accessible without token", async () => {
    const res = await fetch(`${TEST_URL}/public`);
    expect(res.status).toBe(200);
  });

  test("nested subrequest probe shows jwt_key_request is skipped inside subrequests", async () => {
    const res = await fetch(`${TEST_URL}/nested-probe`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("200");
  });

  test("nested subrequest probe fails closed when inner jwt location opts into preaccess", async () => {
    const res = await fetch(`${TEST_URL}/nested-probe-preaccess`);
    expect(res.status).toBe(200);
    expect(await res.text()).toBe("401");
  });

  test("preaccess jwt_key_request route accepts valid token from query-variable token source", async () => {
    const token = createHS256Token({ sub: "nested-preaccess", exp: FAR_FUTURE }, SUBREQ_SECRET);
    const res = await fetch(`${TEST_URL}/protected-sub-inner-preaccess?token=${encodeURIComponent(token)}`);
    expect(res.status).toBe(200);
    expect((await res.text()).trim()).toBe("KEYREQUEST SUB INNER PREACCESS OK");
  });

  // Missing/empty variable URL behavior
  test("empty variable URL rejects token (no keys loaded)", async () => {
    const token = createHS256Token({ sub: "empty-var", exp: FAR_FUTURE }, SUBREQ_SECRET);
    const res = await fetch(`${TEST_URL}/protected-empty-var-url`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("empty variable URL rejects request without token", async () => {
    const res = await fetch(`${TEST_URL}/protected-empty-var-url`);
    expect(res.status).toBe(401);
  });

  test("missing variable URL (header not sent) rejects token", async () => {
    const token = createHS256Token({ sub: "missing-var", exp: FAR_FUTURE }, SUBREQ_SECRET);
    const res = await fetch(`${TEST_URL}/protected-missing-var-url`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("invalid runtime URI rejects when ngx_http_subrequest creation fails", async () => {
    const token = createHS256Token({ sub: "invalid-uri", exp: FAR_FUTURE }, SUBREQ_SECRET);
    const res = await fetch(`${TEST_URL}/protected-invalid-var-url`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });
});
