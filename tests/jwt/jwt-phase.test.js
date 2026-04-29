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
  const sig = createHmac(algo, secret).update(data).digest();
  return `${data}.${base64url(sig)}`;
}

describe("JWT — Phase Selection", () => {
  beforeAll(async () => {
    await startNginz("tests/jwt/nginx.phase.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("access phase route rejects missing token", async () => {
    const res = await fetch(`${TEST_URL}/phase-access`);
    expect(res.status).toBe(401);
  });

  test("preaccess phase route rejects missing token", async () => {
    const res = await fetch(`${TEST_URL}/phase-preaccess`);
    expect(res.status).toBe(401);
  });

  test("access phase route accepts valid token", async () => {
    const token = createToken({ sub: "phase-access-user" }, "phase-secret-hs256");
    const res = await fetch(`${TEST_URL}/phase-access`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("preaccess phase route accepts valid token", async () => {
    const token = createToken({ sub: "phase-preaccess-user" }, "phase-secret-hs256");
    const res = await fetch(`${TEST_URL}/phase-preaccess`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });
});
