import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";
import { createHmac } from "crypto";

const MODULE = "jwt";

// This must match the JWKS oct key in nginx.keyrequest.conf
const SUBREQ_SECRET = "subreq-secret-hs256-test-32bytes!";

function createHS256Token(payload, secret) {
  const header = { alg: "HS256", typ: "JWT" };
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
    await startNginz("tests/jwt/nginx.keyrequest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
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
    const res = await fetch(`${TEST_URL}/`);
    expect(res.status).toBe(200);
  });
});
