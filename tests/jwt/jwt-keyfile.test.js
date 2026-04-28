import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz, stopNginz, cleanupRuntime, TEST_URL,
} from "../harness.js";
import { createHmac, generateKeyPairSync, createSign, createPublicKey } from "crypto";
import { writeFileSync, unlinkSync } from "fs";
import { join } from "path";

const MODULE = "jwt";

// ── JWT helpers ────────────────────────────────────────────────────────

function base64url(v) {
  return v
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
}

function base64urlEncode(obj) {
  return base64url(Buffer.from(typeof obj === "string" ? obj : JSON.stringify(obj)));
}

function signHmac(alg, data, secret) {
  const algo = { HS256: "sha256", HS384: "sha384", HS512: "sha512" }[alg];
  const sig = createHmac(algo, secret).update(data).digest();
  return base64url(sig);
}

function createHmacToken(alg, payload, secret) {
  const header = { alg, typ: "JWT" };
  const data = `${base64urlEncode(header)}.${base64urlEncode(payload)}`;
  const sig = signHmac(alg, data, secret);
  return `${data}.${sig}`;
}

const RSA_SIGN_ALGOS = { RS256: "RSA-SHA256", RS384: "RSA-SHA384", RS512: "RSA-SHA512" };

function createRsaToken(alg, payload, privateKey) {
  const header = { alg, typ: "JWT" };
  const data = `${base64urlEncode(header)}.${base64urlEncode(payload)}`;
  const sign = createSign(RSA_SIGN_ALGOS[alg]);
  sign.update(data);
  const sig = base64url(sign.sign(privateKey));
  return `${data}.${sig}`;
}

function createRsaTokenWithKid(alg, kid, payload, privateKey) {
  const header = { alg, typ: "JWT", kid };
  const data = `${base64urlEncode(header)}.${base64urlEncode(payload)}`;
  const sign = createSign(RSA_SIGN_ALGOS[alg]);
  sign.update(data);
  const sig = base64url(sign.sign(privateKey));
  return `${data}.${sig}`;
}

function writeKeyFile(dir, name, content) {
  const p = join(dir, name);
  writeFileSync(p, typeof content === "string" ? content : JSON.stringify(content, null, 2));
}

// ── Generate RSA key pairs ─────────────────────────────────────────────

let rsaKeys = {}; // { RS256: { publicKey, privateKey }, ... }

function generateRsaKeys() {
  for (const alg of ["RS256", "RS384", "RS512"]) {
    const { publicKey, privateKey } = generateKeyPairSync("rsa", {
      modulusLength: 2048,
      publicKeyEncoding: { type: "spki", format: "pem" },
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
    });
    rsaKeys[alg] = { publicKey, privateKey };
  }
}

// ── Suite ──────────────────────────────────────────────────────────────

describe("JWT Batch 1 — Algorithm Expansion & Key Loading", () => {
  beforeAll(async () => {
    generateRsaKeys();

    // Write key files alongside the config (conf_prefix=0 resolves to config dir)
    const keyDir = "tests/jwt";
    writeKeyFile(keyDir, "keys-rs256.json", {
      "rs256-key": rsaKeys.RS256.publicKey,
    });
    writeKeyFile(keyDir, "keys-rs384.json", {
      "rs384-key": rsaKeys.RS384.publicKey,
    });
    writeKeyFile(keyDir, "keys-rs512.json", {
      "rs512-key": rsaKeys.RS512.publicKey,
    });
    writeKeyFile(keyDir, "keys-kid.json", {
      "key-alpha": rsaKeys.RS256.publicKey,
      "key-beta": rsaKeys.RS384.publicKey,
    });

    await startNginz("tests/jwt/nginx.keyfile.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    try { unlinkSync("tests/jwt/keys-rs256.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-rs384.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-rs512.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-kid.json"); } catch {}
  });

  // =====================================================================
  // Legacy HS256 (backwards compat)
  // =====================================================================

  test("HS256: legacy jwt_secret still works", async () => {
    const token = createHmacToken("HS256", { sub: "test" }, "my-secret-key-for-testing-hs256");
    const res = await fetch(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  // =====================================================================
  // HS384 via inline secret
  // =====================================================================

  test("HS384: validates token with SHA-384 HMAC", async () => {
    const secret = "hs384-test-secret-32-bytes-long!!";
    const token = createHmacToken("HS384", { sub: "test" }, secret);
    const res = await fetch(`${TEST_URL}/hs384`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("HS384: rejects token with wrong secret", async () => {
    const token = createHmacToken("HS384", { sub: "test" }, "wrong-secret-for-hs384-testing!!");
    const res = await fetch(`${TEST_URL}/hs384`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("HS384: also accepts HS256 tokens (inline secret accepts all HMAC)", async () => {
    const secret = "hs384-test-secret-32-bytes-long!!";
    const token = createHmacToken("HS256", { sub: "test" }, secret);
    const res = await fetch(`${TEST_URL}/hs384`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  // =====================================================================
  // HS512 via inline secret
  // =====================================================================

  test("HS512: validates token with SHA-512 HMAC", async () => {
    const secret = "hs512-test-secret-64-bytes-long!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
    const token = createHmacToken("HS512", { sub: "test" }, secret);
    const res = await fetch(`${TEST_URL}/hs512`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("HS512: rejects token with wrong signature", async () => {
    const secret = "hs512-test-secret-64-bytes-long!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!";
    const token = createHmacToken("HS512", { sub: "test" }, "wrong-secret-for-hs512-testing!!!!!!!!!!!!!!!!!");
    const res = await fetch(`${TEST_URL}/hs512`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // RS256 via keyval file
  // =====================================================================

  test("RS256: validates RSA-SHA256 signed token", async () => {
    const token = createRsaToken("RS256", { sub: "rs256-user" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/rs256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("RS256: rejects token signed with different key", async () => {
    const token = createRsaToken("RS256", { sub: "bad" }, rsaKeys.RS384.privateKey);
    const res = await fetch(`${TEST_URL}/rs256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("RS256: rejects token with HS256 alg on RSA endpoint", async () => {
    const token = createHmacToken("HS256", { sub: "test" }, "some-secret");
    const res = await fetch(`${TEST_URL}/rs256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("RS256: rejects expired token", async () => {
    const token = createRsaToken("RS256", {
      sub: "rs256-user",
      exp: Math.floor(Date.now() / 1000) - 3600,
    }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/rs256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // RS384 via keyval file
  // =====================================================================

  test("RS384: validates RSA-SHA384 signed token", async () => {
    const token = createRsaToken("RS384", { sub: "rs384-user" }, rsaKeys.RS384.privateKey);
    const res = await fetch(`${TEST_URL}/rs384`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("RS384: rejects wrong key", async () => {
    const token = createRsaToken("RS384", { sub: "bad" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/rs384`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // RS512 via keyval file
  // =====================================================================

  test("RS512: validates RSA-SHA512 signed token", async () => {
    const token = createRsaToken("RS512", { sub: "rs512-user" }, rsaKeys.RS512.privateKey);
    const res = await fetch(`${TEST_URL}/rs512`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("RS512: rejects wrong key", async () => {
    const token = createRsaToken("RS512", { sub: "bad" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/rs512`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // Multi-key with kid matching
  // =====================================================================

  test("kid: matches token to correct key by kid", async () => {
    const token = createRsaTokenWithKid("RS256", "key-alpha", { sub: "alpha-user" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/kid-match`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("kid: matches different kid to different key", async () => {
    const token = createRsaTokenWithKid("RS384", "key-beta", { sub: "beta-user" }, rsaKeys.RS384.privateKey);
    const res = await fetch(`${TEST_URL}/kid-match`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("kid: falls back to first key when kid is unknown", async () => {
    // Unknown kid falls back to first key (key-alpha = RS256)
    const token = createRsaTokenWithKid("RS256", "key-unknown", { sub: "test" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/kid-match`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("kid: defaults to first key when kid header absent", async () => {
    const token = createRsaToken("RS256", { sub: "no-kid-user" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/kid-match`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  // =====================================================================
  // Algorithm enforcement
  // =====================================================================

  test("alg: rejects unsupported algorithm (none / ES256)", async () => {
    // Create a token with an unsupported alg header
    const header = { alg: "ES256", typ: "JWT" };
    const data = `${base64urlEncode(header)}.${base64urlEncode({ sub: "test" })}`;
    // Sign with RS256 key but claim ES256 in header
    const sign = createSign("RSA-SHA256");
    sign.update(data);
    const sig = base64url(sign.sign(rsaKeys.RS256.privateKey));
    const token = `${data}.${sig}`;
    const res = await fetch(`${TEST_URL}/alg-rs256-only`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("alg: RSA key rejects wrong key even with matching RSA alg type", async () => {
    // RS256 token signed with RS256 key, verified against RS384 key → rejected
    const token = createRsaToken("RS256", { sub: "test" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/rs384`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // Missing token / no auth
  // =====================================================================

  test("returns 401 when no Authorization header", async () => {
    const res = await fetch(`${TEST_URL}/rs256`);
    expect(res.status).toBe(401);
  });

  test("public endpoint accessible without token", async () => {
    const res = await fetch(`${TEST_URL}/public`);
    expect(res.status).toBe(200);
    expect(await res.text()).toContain("Public");
  });
});
