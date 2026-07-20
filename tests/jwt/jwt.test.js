import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  ensureBuild,
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";
import { createHmac } from "crypto";

const MODULE_NAME = "jwt";

// Helper to create JWT tokens
function createJWT(payload, secret) {
  const header = { alg: "HS256", typ: "JWT" };
  return createCustomJWT(header, payload, secret);
}

function createCustomJWT(header, payload, secret) {
  
  const base64urlEncode = (obj) => {
    const json = JSON.stringify(obj);
    return Buffer.from(json)
      .toString("base64")
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=/g, "");
  };
  
  const headerB64 = base64urlEncode(header);
  const payloadB64 = base64urlEncode(payload);
  const data = `${headerB64}.${payloadB64}`;
  
  const signature = createHmac("sha256", secret)
    .update(data)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");

  return `${data}.${signature}`;
}

function createRawPayloadJWT(header, rawPayload, secret) {
  const base64urlEncodeString = (value) => Buffer.from(value)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");

  const headerB64 = base64urlEncodeString(JSON.stringify(header));
  const payloadB64 = base64urlEncodeString(rawPayload);
  const data = `${headerB64}.${payloadB64}`;

  const signature = createHmac("sha256", secret)
    .update(data)
    .digest("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");

  return `${data}.${signature}`;
}

const SECRET = "my-secret-key-for-testing-hs256";
const API_SECRET = "api-secret-key-for-testing";

beforeAll(async () => {
  ensureBuild();
  await startNginz(`tests/${MODULE_NAME}/nginx.conf`, MODULE_NAME);
});

afterAll(async () => {
  await stopNginz();
  cleanupRuntime(MODULE_NAME);
});


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("JWT Authentication", () => {
  test("allows access with valid token", async () => {
    const token = createJWT({ sub: "user123", exp: Math.floor(Date.now() / 1000) + 3600 }, SECRET);
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("Access granted");
  });

  test("rejects request without Authorization header", async () => {
    const res = await fetchClose(`${TEST_URL}/protected`);
    expect(res.status).toBe(401);
  });

  test("rejects request with invalid token format", async () => {
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: "Bearer invalid-token" }
    });
    expect(res.status).toBe(401);
  });

  test("rejects request with wrong secret", async () => {
    const token = createJWT({ sub: "user123", exp: Math.floor(Date.now() / 1000) + 3600 }, "wrong-secret");
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(401);
  });

  test("rejects expired token", async () => {
    const token = createJWT({ sub: "user123", exp: Math.floor(Date.now() / 1000) - 3600 }, SECRET);
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(401);
  });

  test("rejects token with nbf in future", async () => {
    const token = createJWT({ 
      sub: "user123", 
      exp: Math.floor(Date.now() / 1000) + 7200,
      nbf: Math.floor(Date.now() / 1000) + 3600  // not valid until 1 hour from now
    }, SECRET);
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(401);
  });

  test("allows access to public endpoints without token", async () => {
    const res = await fetchClose(`${TEST_URL}/public`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("Public content");
  });

  test("supports Bearer prefix case-insensitively", async () => {
    const token = createJWT({ sub: "user123", exp: Math.floor(Date.now() / 1000) + 3600 }, SECRET);
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `bearer ${token}` }  // lowercase bearer
    });
    expect(res.status).toBe(200);
  });

  test("inherits jwt_secret from parent location", async () => {
    const token = createJWT({ sub: "user123", exp: Math.floor(Date.now() / 1000) + 3600 }, API_SECRET);
    const res = await fetchClose(`${TEST_URL}/api/users`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("Users list");
  });

  test("inherits jwt_secret to nested child locations", async () => {
    const token = createJWT({ sub: "admin123", exp: Math.floor(Date.now() / 1000) + 3600 }, API_SECRET);
    const res = await fetchClose(`${TEST_URL}/admin/settings`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("Admin settings");
  });

  test("allows access without token when jwt not enabled", async () => {
    const res = await fetchClose(`${TEST_URL}/api/public`);
    expect(res.status).toBe(200);
    const text = await res.text();
    expect(text.trim()).toBe("Public API");
  });

  test("token without exp claim is allowed", async () => {
    // Token without expiration - should be allowed (no exp check fails)
    const token = createJWT({ sub: "user123" }, SECRET);
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(200);
  });

  test("rejects token whose header algorithm is not HS256", async () => {
    const token = createCustomJWT(
      { alg: "none", typ: "JWT" },
      { sub: "user123", exp: Math.floor(Date.now() / 1000) + 3600 },
      SECRET
    );
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(401);
  });

  test("rejects token with non-JSON payload even if signature matches", async () => {
    const token = createRawPayloadJWT(
      { alg: "HS256", typ: "JWT" },
      "not-json-payload",
      SECRET
    );
    const res = await fetchClose(`${TEST_URL}/protected`, {
      headers: { Authorization: `Bearer ${token}` }
    });
    expect(res.status).toBe(401);
  });
});
