import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL } from "../harness.js";
import { createHmac } from "crypto";
import { writeFileSync, unlinkSync } from "fs";

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

function createTokenWithHeader(payload, secret, header, alg = "HS256") {
  const fullHeader = { alg, typ: "JWT", ...header };
  const data = `${base64url(Buffer.from(JSON.stringify(fullHeader)))}.${base64url(Buffer.from(JSON.stringify(payload)))}`;
  const algo = { HS256: "sha256", HS384: "sha384", HS512: "sha512" }[alg];
  const sig = createHmac(algo, secret).update(data).digest();
  return `${data}.${base64url(sig)}`;
}

const SECRET = "require-test-secret-hs256";

// ── Suite ──────────────────────────────────────────────────────────────

describe("JWT — Rich Claim Validation", () => {
  beforeAll(async () => {
    writeFileSync("tests/jwt/revoked-subs.json", JSON.stringify(["revoked-user"], null, 2));
    writeFileSync("tests/jwt/revoked-kids.json", JSON.stringify(["revoked-kid"], null, 2));
    await startNginz("tests/jwt/nginx.require.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    try { unlinkSync("tests/jwt/revoked-subs.json"); } catch {}
    try { unlinkSync("tests/jwt/revoked-kids.json"); } catch {}
  });

  // =====================================================================
  // jwt_require_claim eq
  // =====================================================================

  test("eq: allows when claim matches", async () => {
    const token = createToken({ sub: "u1", role: "admin" }, SECRET);
    const res = await fetch(`${TEST_URL}/require-eq`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("eq: rejects when claim differs", async () => {
    const token = createToken({ sub: "u2", role: "user" }, SECRET);
    const res = await fetch(`${TEST_URL}/require-eq`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("eq: rejects when claim is missing", async () => {
    const token = createToken({ sub: "u3" }, SECRET);
    const res = await fetch(`${TEST_URL}/require-eq`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // jwt_require_claim !eq
  // =====================================================================

  test("!eq: allows when claim does not match", async () => {
    const token = createToken({ sub: "u4", role: "user" }, SECRET);
    const res = await fetch(`${TEST_URL}/require-neq`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("!eq: rejects when claim matches banned value", async () => {
    const token = createToken({ sub: "u5", role: "banned" }, SECRET);
    const res = await fetch(`${TEST_URL}/require-neq`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // jwt_require_claim gt / lt (numeric)
  // =====================================================================

  test("gt: allows when numeric value exceeds threshold", async () => {
    const token = createToken({ sub: "u6", level: 10 }, SECRET);
    const res = await fetch(`${TEST_URL}/require-gt`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("gt: rejects when value is below threshold", async () => {
    const token = createToken({ sub: "u7", level: 3 }, SECRET);
    const res = await fetch(`${TEST_URL}/require-gt`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("lt: allows when value is below threshold", async () => {
    const token = createToken({ sub: "u8", level: 50 }, SECRET);
    const res = await fetch(`${TEST_URL}/require-lt`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("lt: rejects when value exceeds threshold", async () => {
    const token = createToken({ sub: "u9", level: 200 }, SECRET);
    const res = await fetch(`${TEST_URL}/require-lt`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // Multiple require_claim rules
  // =====================================================================

  test("multi: allows when all claims pass", async () => {
    const token = createToken({ sub: "u10", role: "admin", department: "engineering", level: 5 }, SECRET);
    const res = await fetch(`${TEST_URL}/require-multi`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("multi: rejects when one claim fails", async () => {
    const token = createToken({ sub: "u11", role: "admin", department: "marketing", level: 5 }, SECRET);
    const res = await fetch(`${TEST_URL}/require-multi`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("multi: rejects when numeric claim too low", async () => {
    const token = createToken({ sub: "u12", role: "admin", department: "engineering", level: 2 }, SECRET);
    const res = await fetch(`${TEST_URL}/require-multi`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("nested claim paths: allows when nested values match", async () => {
    const token = createToken({ sub: "u12b", profile: { name: "Alice" }, roles: ["admin", "user"] }, SECRET);
    const res = await fetch(`${TEST_URL}/require-nested`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("nested claim paths: rejects when nested values differ", async () => {
    const token = createToken({ sub: "u12c", profile: { name: "Bob" }, roles: ["user"] }, SECRET);
    const res = await fetch(`${TEST_URL}/require-nested`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // Missing claim: eq fails, !eq passes
  // =====================================================================

  test("missing claim: eq on absent claim rejects", async () => {
    const token = createToken({ sub: "u13" }, SECRET);
    const res = await fetch(`${TEST_URL}/require-missing-eq`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("missing claim: !eq on absent claim passes", async () => {
    const token = createToken({ sub: "u14" }, SECRET);
    const res = await fetch(`${TEST_URL}/require-missing-neq`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  // =====================================================================
  // jwt_validate_exp off
  // =====================================================================

  test("validate_exp off: accepts expired token", async () => {
    const token = createToken({
      sub: "u15",
      exp: Math.floor(Date.now() / 1000) - 3600,
    }, SECRET);
    const res = await fetch(`${TEST_URL}/no-exp-check`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  // =====================================================================
  // jwt_leeway
  // =====================================================================

  test("leeway: accepts token expired within leeway window", async () => {
    // Token expired 60 seconds ago, but leeway is 300s
    const token = createToken({
      sub: "u16",
      exp: Math.floor(Date.now() / 1000) - 60,
    }, SECRET);
    const res = await fetch(`${TEST_URL}/leeway`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("leeway: rejects token expired beyond leeway window", async () => {
    const token = createToken({
      sub: "u17",
      exp: Math.floor(Date.now() / 1000) - 600,
    }, SECRET);
    const res = await fetch(`${TEST_URL}/leeway`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("require_header: allows when jose header matches", async () => {
    const token = createTokenWithHeader({ sub: "u18" }, SECRET, { typ: "JWT" });
    const res = await fetch(`${TEST_URL}/require-header-typ`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("require_header: rejects when jose header differs", async () => {
    const token = createTokenWithHeader({ sub: "u19" }, SECRET, { typ: "JOSE" });
    const res = await fetch(`${TEST_URL}/require-header-typ`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("jwt_audience: allows string aud claim match", async () => {
    const token = createToken({ sub: "u19b", aud: "my-service" }, SECRET);
    const res = await fetch(`${TEST_URL}/audience`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("jwt_audience: allows array aud claim match", async () => {
    const token = createToken({ sub: "u19c", aud: ["other-service", "my-service"] }, SECRET);
    const res = await fetch(`${TEST_URL}/audience`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("jwt_audience: rejects aud mismatch", async () => {
    const token = createToken({ sub: "u19d", aud: "other-service" }, SECRET);
    const res = await fetch(`${TEST_URL}/audience`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("revocation sub: rejects revoked subject", async () => {
    const token = createToken({ sub: "revoked-user" }, SECRET);
    const res = await fetch(`${TEST_URL}/revoke-sub`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("revocation sub: allows non-revoked subject", async () => {
    const token = createToken({ sub: "active-user" }, SECRET);
    const res = await fetch(`${TEST_URL}/revoke-sub`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("revocation kid: rejects revoked kid", async () => {
    const token = createTokenWithHeader({ sub: "u20" }, SECRET, { kid: "revoked-kid" });
    const res = await fetch(`${TEST_URL}/revoke-kid`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("revocation kid: rejects when kid header missing", async () => {
    const token = createToken({ sub: "u21" }, SECRET);
    const res = await fetch(`${TEST_URL}/revoke-kid`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("revocation kid: allows non-revoked kid", async () => {
    const token = createTokenWithHeader({ sub: "u22" }, SECRET, { kid: "active-kid" });
    const res = await fetch(`${TEST_URL}/revoke-kid`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });
});
