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

function createTokenWithHeader(payload, secret, header, alg = "HS256") {
    const fullHeader = { alg, typ: "JWT", ...header };
    const data = `${base64url(Buffer.from(JSON.stringify(fullHeader)))}.${base64url(Buffer.from(JSON.stringify(payload)))}`;
    const algo = { HS256: "sha256", HS384: "sha384", HS512: "sha512" }[alg];
    const sig = createHmac(algo, secret).update(data).digest();
    return `${data}.${base64url(sig)}`;
}

// ── Suite ──────────────────────────────────────────────────────────────

describe("JWT — Claim Variable Extraction", () => {
  beforeAll(async () => {
    await startNginz("tests/jwt/nginx.claims.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  // =====================================================================
  // $jwt_claim_* via jwt_claim directive
  // =====================================================================

  test("extracts string claim via jwt_claim directive", async () => {
    const token = createToken(
      { sub: "user-123", iss: "my-issuer", name: "Alice", role: "admin" },
      "my-claim-test-secret-hs256"
    );
    const res = await fetch(`${TEST_URL}/claim-sub`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-sub")).toBe("user-123");
    expect(res.headers.get("x-jwt-iss")).toBe("my-issuer");
    expect(res.headers.get("x-jwt-name")).toBe("Alice");
    expect(res.headers.get("x-jwt-role")).toBe("admin");
  });

  test("missing claim returns empty header", async () => {
    const token = createToken(
      { sub: "user-456" },
      "my-claim-test-secret-hs256"
    );
    const res = await fetch(`${TEST_URL}/claim-sub`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-sub")).toBe("user-456");
    // iss, name, role are not in token → should be empty/missing
    expect(res.headers.get("x-jwt-iss") || "").toBe("");
    expect(res.headers.get("x-jwt-name") || "").toBe("");
  });

  test("integer claim extracted as string", async () => {
    const iat = Math.floor(Date.now() / 1000);
    const token = createToken(
      { sub: "int-user", iat },
      "my-int-claim-secret-hs256"
    );
    const res = await fetch(`${TEST_URL}/claim-int`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-iat")).toBe(String(iat));
  });

  test("extracts nested claim values via dot paths and array indices", async () => {
    const token = createToken(
      { sub: "nested-user", profile: { name: "Nested Alice" }, roles: ["admin", "user"] },
      "my-claim-test-secret-hs256"
    );
    const res = await fetch(`${TEST_URL}/claim-nested`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-profile-name")).toBe("Nested Alice");
    expect(res.headers.get("x-jwt-role0")).toBe("admin");
  });

  test("missing nested claim path returns empty header", async () => {
    const token = createToken(
      { sub: "nested-missing", profile: {} },
      "my-claim-test-secret-hs256"
    );
    const res = await fetch(`${TEST_URL}/claim-nested`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-profile-name") || "").toBe("");
    expect(res.headers.get("x-jwt-role0") || "").toBe("");
  });

  test("extracts jose headers via jwt_header directive", async () => {
    const token = createTokenWithHeader(
      { sub: "header-user" },
      "my-claim-test-secret-hs256",
      { kid: "kid-123", typ: "JWT" }
    );
    const res = await fetch(`${TEST_URL}/header-values`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-typ")).toBe("JWT");
    expect(res.headers.get("x-jwt-kid")).toBe("kid-123");
  });

  test("missing jose header returns empty header", async () => {
    const token = createToken(
      { sub: "header-missing" },
      "my-claim-test-secret-hs256"
    );
    const res = await fetch(`${TEST_URL}/header-values`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-typ")).toBe("JWT");
    expect(res.headers.get("x-jwt-kid") || "").toBe("");
  });

  test("extracts nested jose header values via dot paths", async () => {
    const token = createTokenWithHeader(
      { sub: "header-nested-user" },
      "my-claim-test-secret-hs256",
      { meta: { inner: "nested-header" } }
    );
    const res = await fetch(`${TEST_URL}/header-nested`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    expect(res.headers.get("x-jwt-nested-value")).toBe("nested-header");
  });

  // =====================================================================
  // $jwt_claims (full payload JSON)
  // =====================================================================

  test("$jwt_claims returns full payload JSON", async () => {
    const payload = { sub: "json-user", email: "json@test.com", exp: Math.floor(Date.now() / 1000) + 3600 };
    const token = createToken(payload, "my-claims-json-secret-hs256");
    const res = await fetch(`${TEST_URL}/claims-json`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const claimsHeader = res.headers.get("x-jwt-claims");
    expect(claimsHeader).toBeTruthy();
    const claims = JSON.parse(claimsHeader);
    expect(claims.sub).toBe("json-user");
    expect(claims.email).toBe("json@test.com");
  });

  test("$jwt_claims not set when no token", async () => {
    const res = await fetch(`${TEST_URL}/claims-json`);
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // $jwt_nowtime
  // =====================================================================

  test("$jwt_nowtime returns current Unix timestamp", async () => {
    const before = Math.floor(Date.now() / 1000);
    const token = createToken(
      { sub: "time-user", exp: before + 3600 },
      "my-nowtime-secret-hs256"
    );
    const res = await fetch(`${TEST_URL}/nowtime`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
    const nowtime = Number(res.headers.get("x-jwt-nowtime"));
    const after = Math.floor(Date.now() / 1000);
    expect(nowtime).toBeGreaterThanOrEqual(before);
    expect(nowtime).toBeLessThanOrEqual(after + 1);
  });
});
