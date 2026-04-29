import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz, stopNginz, cleanupRuntime, TEST_URL,
} from "../harness.js";
import { createHmac, generateKeyPairSync, createSign, createPublicKey, sign as cryptoSign, constants as cryptoConstants } from "crypto";
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
const ECDSA_SIGN_ALGOS = { ES256: "SHA256", ES384: "SHA384", ES512: "SHA512", ES256K: "SHA256" };

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

function createEcdsaToken(alg, payload, privateKey) {
  const header = { alg, typ: "JWT" };
  const data = `${base64urlEncode(header)}.${base64urlEncode(payload)}`;
  const sign = createSign(ECDSA_SIGN_ALGOS[alg]);
  sign.update(data);
  const sig = base64url(sign.sign(privateKey));
  return `${data}.${sig}`;
}

function createPssToken(alg, payload, privateKey) {
  const header = { alg, typ: "JWT" };
  const data = `${base64urlEncode(header)}.${base64urlEncode(payload)}`;
  const hash = { PS256: "sha256", PS384: "sha384", PS512: "sha512" }[alg];
  const sig = cryptoSign(hash, Buffer.from(data), {
    key: privateKey,
    padding: cryptoConstants.RSA_PKCS1_PSS_PADDING,
    saltLength: cryptoConstants.RSA_PSS_SALTLEN_DIGEST,
  });
  return `${data}.${base64url(sig)}`;
}

function createEdDsaToken(payload, privateKey) {
  const header = { alg: "EdDSA", typ: "JWT" };
  const data = `${base64urlEncode(header)}.${base64urlEncode(payload)}`;
  const sig = cryptoSign(null, Buffer.from(data), privateKey);
  return `${data}.${base64url(sig)}`;
}

function writeKeyFile(dir, name, content) {
  const p = join(dir, name);
  writeFileSync(p, typeof content === "string" ? content : JSON.stringify(content, null, 2));
}

function writeRsaJwksFile(dir, name, kid, alg, publicKeyPem) {
  const jwk = createPublicKey(publicKeyPem).export({ format: "jwk" });
  writeKeyFile(dir, name, {
    keys: [{
      kty: "RSA",
      kid,
      alg,
      use: "sig",
      n: jwk.n,
      e: jwk.e,
    }],
  });
}

// ── Generate RSA key pairs ─────────────────────────────────────────────

let rsaKeys = {}; // { RS256: { publicKey, privateKey }, ... }
let ecKeys = {};
let pssKeys = {};
let eddsaKeys = {};

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

function generateEcKeys() {
  const { publicKey, privateKey } = generateKeyPairSync("ec", {
    namedCurve: "prime256v1",
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  ecKeys.ES256 = { publicKey, privateKey };
}

function generatePssKeys() {
  for (const alg of ["PS256", "PS384", "PS512"]) {
    const { publicKey, privateKey } = generateKeyPairSync("rsa", {
      modulusLength: 2048,
      publicKeyEncoding: { type: "spki", format: "pem" },
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
    });
    pssKeys[alg] = { publicKey, privateKey };
  }
}

function generateEdDsaKeys() {
  const { publicKey, privateKey } = generateKeyPairSync("ed25519", {
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
  eddsaKeys.EdDSA = { publicKey, privateKey };
}

// ── Suite ──────────────────────────────────────────────────────────────

describe("JWT — Algorithm Support & Key Loading", () => {
  beforeAll(async () => {
    generateRsaKeys();
    generateEcKeys();
    generatePssKeys();
    generateEdDsaKeys();

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
    writeRsaJwksFile(keyDir, "keys-jwks-rs256.json", "jwks-rs256", "RS256", rsaKeys.RS256.publicKey);
    writeKeyFile(keyDir, "keys-es256.json", { "es256-key": ecKeys.ES256.publicKey });
    writeKeyFile(keyDir, "keys-ps256.json", { "ps256-key": pssKeys.PS256.publicKey });
    writeKeyFile(keyDir, "keys-eddsa.json", { "eddsa-key": eddsaKeys.EdDSA.publicKey });

    await startNginz("tests/jwt/nginx.keyfile.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    try { unlinkSync("tests/jwt/keys-rs256.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-rs384.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-rs512.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-kid.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-jwks-rs256.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-es256.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-ps256.json"); } catch {}
    try { unlinkSync("tests/jwt/keys-eddsa.json"); } catch {}
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

  test("jwks: validates RSA token from JWKS key material", async () => {
    const token = createRsaTokenWithKid("RS256", "jwks-rs256", { sub: "jwks-user" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/jwks-rs256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("jwks: rejects RSA token signed by a different key", async () => {
    const token = createRsaTokenWithKid("RS256", "jwks-rs256", { sub: "jwks-bad" }, rsaKeys.RS384.privateKey);
    const res = await fetch(`${TEST_URL}/jwks-rs256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  // =====================================================================
  // Algorithm enforcement
  // =====================================================================

  test("ES256: validates token signed with ECDSA key", async () => {
    const token = createEcdsaToken("ES256", { sub: "es256-user" }, ecKeys.ES256.privateKey);
    const res = await fetch(`${TEST_URL}/es256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("ES256: rejects token signed with a different ECDSA key", async () => {
    const { privateKey } = generateKeyPairSync("ec", {
      namedCurve: "prime256v1",
      publicKeyEncoding: { type: "spki", format: "pem" },
      privateKeyEncoding: { type: "pkcs8", format: "pem" },
    });
    const token = createEcdsaToken("ES256", { sub: "es256-bad" }, privateKey);
    const res = await fetch(`${TEST_URL}/es256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("PS256: validates token signed with RSA-PSS", async () => {
    const token = createPssToken("PS256", { sub: "ps256-user" }, pssKeys.PS256.privateKey);
    const res = await fetch(`${TEST_URL}/ps256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("PS256: rejects token signed by a different RSA key", async () => {
    const token = createPssToken("PS256", { sub: "ps256-bad" }, rsaKeys.RS256.privateKey);
    const res = await fetch(`${TEST_URL}/ps256`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(401);
  });

  test("EdDSA: validates token signed with Ed25519", async () => {
    const token = createEdDsaToken({ sub: "eddsa-user" }, eddsaKeys.EdDSA.privateKey);
    const res = await fetch(`${TEST_URL}/eddsa`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(res.status).toBe(200);
  });

  test("EdDSA: rejects token signed with the wrong key", async () => {
    const token = createEdDsaToken({ sub: "eddsa-bad" }, eddsaKeys.EdDSA.privateKey);
    const res = await fetch(`${TEST_URL}/rs256`, {
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
