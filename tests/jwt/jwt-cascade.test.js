import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";
import { createHmac } from "crypto";

const MODULE = "jwt";

function base64url(v) {
  return v.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}
function createToken(payload, secret, alg = "HS256") {
  const header = { alg, typ: "JWT" };
  const data = `${base64url(Buffer.from(JSON.stringify(header)))}.${base64url(Buffer.from(JSON.stringify(payload)))}`;
  const algo = { HS256: "sha256", HS384: "sha384", HS512: "sha512" }[alg];
  return `${data}.${base64url(createHmac(algo, secret).update(data).digest())}`;
}

describe("JWT Config Cascade", () => {
  beforeAll(async () => {
    await startNginz("tests/jwt/nginx.cascade.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  // =====================================================================
  // http-level defaults cascade to location
  // =====================================================================

  test("inherits jwt_secret from http level", async () => {
    const token = createToken({ sub: "cascade-user", role: "user" }, "cascade-secret-hs256");
    const res = await fetch(`${TEST_URL}/inherit-all`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("inherits jwt_claim from http level", async () => {
    const token = createToken({ sub: "cascade-sub", role: "user" }, "cascade-secret-hs256");
    const res = await fetch(`${TEST_URL}/inherit-all`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-sub")).toBe("cascade-sub");
  });

  test("inherits jwt_validate_exp=off from http level", async () => {
    const token = createToken({
      sub: "expired-user",
      role: "user",
      exp: Math.floor(Date.now() / 1000) - 3600,
    }, "cascade-secret-hs256");
    const res = await fetch(`${TEST_URL}/inherit-all`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200); // expired but validate_exp is off
  });

  test("inherits jwt_leeway from http level", async () => {
    // Expired 30s ago, leeway=60 → still valid
    const token = createToken({
      sub: "leeway-user",
      role: "user",
      exp: Math.floor(Date.now() / 1000) - 30,
    }, "cascade-secret-hs256");
    const res = await fetch(`${TEST_URL}/inherit-all`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  // =====================================================================
  // Location overrides http-level defaults
  // =====================================================================

  test("location overrides jwt_validate_exp", async () => {
    const token = createToken({
      sub: "exp-user",
      role: "user",
      exp: Math.floor(Date.now() / 1000) - 3600,
    }, "cascade-secret-hs256");
    const res = await fetch(`${TEST_URL}/override-exp`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401); // validate_exp=on at location level
  });

  test("location overrides jwt_require_claim", async () => {
    const token = createToken({ sub: "user-1", role: "user" }, "cascade-secret-hs256");
    const res = await fetch(`${TEST_URL}/override-require`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401); // requires role=admin at location level
  });

  // =====================================================================
  // Explicit location secret still inherits claim vars from http
  // =====================================================================

  test("explicit secret uses location-level secret", async () => {
    const token = createToken({ sub: "explicit-sub", name: "Bob" }, "override-secret-hs256");
    const res = await fetch(`${TEST_URL}/explicit-secret`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-name")).toBe("Bob");
  });

  test("explicit secret rejects http-level secret (location override)", async () => {
    const token = createToken({ sub: "bad", name: "Eve" }, "cascade-secret-hs256");
    const res = await fetch(`${TEST_URL}/explicit-secret`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // Public endpoint
  // =====================================================================

  test("public endpoint accessible without token", async () => {
    const res = await fetch(`${TEST_URL}/public`);
    expect(res.status).toBe(200);
  });
});
