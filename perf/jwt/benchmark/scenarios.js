// JWT benchmark scenarios.
//
// All HS256 tokens use the shared secret "benchmark-secret-hs256".
// RS256 tokens use a pre-generated RSA key pair.
// Tokens are pre-computed once and reused across all requests to
// avoid crypto overhead inside the measurement loop.

import { createHmac, generateKeyPairSync, createSign } from "crypto";

const SECRET = "benchmark-secret-hs256";
const WRONG_SECRET = "different-secret-hs256";

// ── Token helpers ──────────────────────────────────────────────────────

function base64url(v) {
  return Buffer.from(v).toString("base64")
    .replace(/\+/g, "-").replace(/\//g, "_").replace(/=/g, "");
}

function createToken(payload, secret = SECRET) {
  const header = JSON.stringify({ alg: "HS256", typ: "JWT" });
  const data = `${base64url(header)}.${base64url(JSON.stringify(payload))}`;
  const sig = base64url(createHmac("sha256", secret).update(data).digest());
  return `${data}.${sig}`;
}

// ── RSA key generation ──────────────────────────────────────────────────

export function generateRsaKeyPair() {
  return generateKeyPairSync("rsa", {
    modulusLength: 2048,
    publicKeyEncoding: { type: "spki", format: "pem" },
    privateKeyEncoding: { type: "pkcs8", format: "pem" },
  });
}

export function createRsaToken(payload, privateKey) {
  const header = JSON.stringify({ alg: "RS256", typ: "JWT" });
  const data = `${base64url(header)}.${base64url(JSON.stringify(payload))}`;
  const sign = createSign("RSA-SHA256");
  sign.update(data);
  const sig = base64url(sign.sign(privateKey));
  return `${data}.${sig}`;
}

// ── Pre-computed tokens ────────────────────────────────────────────────

const now = Math.floor(Date.now() / 1000);
const FAR_FUTURE = 1777383810; // 2026-04-28 + 10 years

const TOKEN_VALID = createToken({ sub: "bench-user", exp: FAR_FUTURE });
const TOKEN_CLAIMS = createToken({ sub: "claim-user", name: "Bench", exp: FAR_FUTURE });
const TOKEN_WRONG_SECRET = createToken({ sub: "wrong-user", exp: FAR_FUTURE });

// ── Scenario definitions ───────────────────────────────────────────────

export const SCENARIOS = [
  {
    name: "valid-hs256",
    description: "Valid HS256 token → 200 OK (JWT parse + base64 decode + HMAC verify)",
    path: "/bench/valid-hs256",
    method: "GET",
    headers: { Authorization: `Bearer ${TOKEN_VALID}` },
    expectedStatus: 200,
  },
  {
    name: "valid-claims",
    description: "Valid HS256 token + claim extraction → 200 OK + X-Jwt-Sub header (adds CJSON decode)",
    path: "/bench/valid-claims",
    method: "GET",
    headers: { Authorization: `Bearer ${TOKEN_CLAIMS}` },
    expectedStatus: 200,
  },
  {
    name: "reject-no-token",
    description: "No Authorization header → 401 (fastest rejection path)",
    path: "/bench/valid-hs256",
    method: "GET",
    headers: {},
    expectedStatus: 401,
  },
  {
    name: "reject-wrong-secret",
    description: "Wrong secret → 401 (HMAC verify failure after full parse)",
    path: "/bench/reject-wrong-secret",
    method: "GET",
    headers: { Authorization: `Bearer ${TOKEN_WRONG_SECRET}` },
    expectedStatus: 401,
  },
];

export function getScenario(name) {
  return SCENARIOS.find((scenario) => scenario.name === name) ?? null;
}
