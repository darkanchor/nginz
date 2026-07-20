import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import {
  cleanupRuntime,
  createOIDCMock,
  startNginz,
  stopNginz,
  TEST_URL,
} from "../harness.js";

const MODULE = "oidc";
let oidcMock = null;

function extractCookie(setCookie, name) {
  const match = setCookie?.match(new RegExp(`${name}=([^;]+)`));
  return match?.[1] ?? null;
}

async function beginFlow(path = "/protected", overrides = null) {
  if (overrides) {
    oidcMock.setNextTokenOverrides(overrides);
  }

  const step1 = await fetchClose(`${TEST_URL}${path}`, { redirect: "manual" });
  expect(step1.status).toBe(302);

  const authUrl = step1.headers.get("location");
  const stateCookie = step1.headers.get("set-cookie");
  const stateCookieValue = extractCookie(stateCookie, "oidc_state");

  expect(authUrl).toBeDefined();
  expect(stateCookieValue).toBeDefined();

  const step2 = await fetch(authUrl, { redirect: "manual" });
  expect(step2.status).toBe(302);

  return {
    step1,
    authUrl,
    stateCookie,
    stateCookieValue,
    callbackUrl: step2.headers.get("location"),
  };
}

async function finishFlow(flow) {
  return fetch(flow.callbackUrl, {
    redirect: "manual",
    headers: {
      Cookie: `oidc_state=${flow.stateCookieValue}`,
    },
  });
}

async function createSession(path = "/protected", overrides = null) {
  const flow = await beginFlow(path, overrides);
  const callbackRes = await finishFlow(flow);
  expect(callbackRes.status).toBe(302);

  const setCookie = callbackRes.headers.get("set-cookie");
  const sessionValue = extractCookie(setCookie, "oidc_session");
  expect(sessionValue).toBeDefined();

  return { flow, callbackRes, sessionValue, setCookie };
}


// Always close the connection: nginx closes after some non-2xx module responses
// and Bun's keep-alive pool can race the FIN into the next test's fetch.
function fetchClose(url, init = {}) {
  const headers = { Connection: "close", ...(init.headers || {}) };
  return fetch(url, { ...init, headers });
}

describe("oidc module", () => {
  beforeAll(async () => {
    oidcMock = createOIDCMock(9999);
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    oidcMock?.stop();
    cleanupRuntime(MODULE);
  });

  describe("authorization redirect", () => {
    test("fails closed when remote JWKS metadata exceeds the 1 MiB bound", async () => {
      const flow = await beginFlow("/oversized-metadata");
      const res = await finishFlow(flow);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Failed to validate id_token");
    });

    test("redirects unauthenticated request using discovery-backed authorize endpoint", async () => {
      const res = await fetchClose(`${TEST_URL}/protected`, { redirect: "manual" });
      expect(res.status).toBe(302);

      const location = new URL(res.headers.get("location"));
      expect(location.origin).toBe("http://127.0.0.1:9999");
      expect(location.pathname).toBe("/authorize");
      expect(location.searchParams.get("response_type")).toBe("code");
      expect(location.searchParams.get("client_id")).toBe("test-client");
      expect(location.searchParams.get("nonce")).toBeDefined();
      expect(location.searchParams.get("state")).toMatch(/^[a-f0-9]{64}$/);
      expect(location.searchParams.get("code_challenge")).toBeDefined();
      expect(location.searchParams.get("code_challenge_method")).toBe("S256");
    });

    test("sets encrypted state cookie on redirect", async () => {
      const res = await fetchClose(`${TEST_URL}/protected`, { redirect: "manual" });
      expect(res.status).toBe(302);

      const setCookie = res.headers.get("set-cookie");
      expect(setCookie).toContain("oidc_state=");
      expect(setCookie).toContain("HttpOnly");
      expect(setCookie).toContain("SameSite=Lax");
    });

    test("omits PKCE parameters when disabled", async () => {
      const res = await fetchClose(`${TEST_URL}/no-pkce`, { redirect: "manual" });
      const location = res.headers.get("location");
      expect(location).not.toContain("code_challenge=");
      expect(location).not.toContain("code_challenge_method=");
    });
  });

  describe("callback validation", () => {
    test("callback without code returns error", async () => {
      const res = await fetchClose(`${TEST_URL}/callback?state=abc123`, { redirect: "manual" });
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Missing authorization code");
    });

    test("callback with mismatched state returns error", async () => {
      const flow = await beginFlow();
      const res = await fetchClose(`${TEST_URL}/callback?code=abc123&state=wrong-state`, {
        redirect: "manual",
        headers: { Cookie: `oidc_state=${flow.stateCookieValue}` },
      });

      expect(res.status).toBe(400);
      expect(await res.text()).toContain("State mismatch");
    });

    test("IdP error params remain surfaced as callback errors", async () => {
      const flow = await beginFlow();
      const authUrl = new URL(flow.authUrl);
      const state = authUrl.searchParams.get("state");

      const res = await fetchClose(`${TEST_URL}/callback?error=access_denied&error_description=user_cancelled&state=${state}`,
        {
          redirect: "manual",
          headers: { Cookie: `oidc_state=${flow.stateCookieValue}` },
        }
      );

      expect(res.status).toBe(400);
      expect(await res.text()).toContain("OIDC error: access_denied");
    });
  });

  describe("secure token validation", () => {
    test("successful signed-token flow creates a session and clears state", async () => {
      const { callbackRes, setCookie } = await createSession();
      expect(callbackRes.headers.get("location")).toBe("http://localhost:8888/protected");
      expect(setCookie).toContain("oidc_session=");
      expect(setCookie).toContain("oidc_state=; Path=/; Max-Age=0");
    });

    test("signed session grants access to protected resource", async () => {
      const { sessionValue } = await createSession();

      const res = await fetchClose(`${TEST_URL}/protected`, {
        headers: { Cookie: `oidc_session=${sessionValue}` },
      });

      expect(res.status).toBe(200);
      expect((await res.json()).status).toBe("protected_content");
    });

    test("tampered signature is rejected", async () => {
      const flow = await beginFlow("/protected", { tamperSignature: true });
      const res = await finishFlow(flow);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Failed to validate id_token");
    });

    test("wrong issuer is rejected", async () => {
      const flow = await beginFlow("/protected", { issuer: "http://127.0.0.1:9999/wrong" });
      const res = await finishFlow(flow);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Failed to validate id_token");
    });

    test("wrong audience is rejected", async () => {
      const flow = await beginFlow("/protected", { audience: "other-client" });
      const res = await finishFlow(flow);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Failed to validate id_token");
    });

    test("nonce mismatch is rejected", async () => {
      const flow = await beginFlow("/protected", { nonce: "bad-nonce" });
      const res = await finishFlow(flow);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Failed to validate id_token");
    });

    test("expired token is rejected", async () => {
      const flow = await beginFlow("/protected", { expiresInSec: -120 });
      const res = await finishFlow(flow);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Failed to validate id_token");
    });

    test("unknown kid is rejected after JWKS refresh attempt", async () => {
      const flow = await beginFlow("/protected", { kid: "unknown-key" });
      const res = await finishFlow(flow);
      expect(res.status).toBe(400);
      expect(await res.text()).toContain("Failed to validate id_token");
    });

    test("authorization flow survives original URIs containing quotes", async () => {
      const { callbackRes } = await createSession("/protected-quote%22path");
      expect(callbackRes.headers.get("location")).toBe('http://localhost:8888/protected-quote"path');
    });
  });

  describe("claim variables", () => {
    test("claim headers are populated from validated session claims", async () => {
      const { sessionValue } = await createSession("/claims");

      const res = await fetchClose(`${TEST_URL}/claims`, {
        headers: { Cookie: `oidc_session=${sessionValue}` },
      });

      expect(res.status).toBe(200);
      expect(res.headers.get("X-OIDC-Sub")).toBe("user1");
      expect(res.headers.get("X-OIDC-Email")).toBe("test@example.com");
      expect(res.headers.get("X-OIDC-Name")).toBe("Test User");
    });
  });

  describe("subrequest hardening", () => {
    test("auth_request fails closed without redirect when session is missing", async () => {
      const res = await fetchClose(`${TEST_URL}/auth-gate`, { redirect: "manual" });
      expect(res.status).toBe(401);
      expect(res.headers.get("location")).toBeNull();
    });

    test("auth_request grants access when a valid session cookie is present", async () => {
      const { sessionValue } = await createSession();

      const res = await fetchClose(`${TEST_URL}/auth-gate`, {
        headers: { Cookie: `oidc_session=${sessionValue}` },
      });

      expect(res.status).toBe(200);
      expect(await res.text()).toBe("oidc-granted");
    });

    test("SSI include fails closed without trying browser redirect flow", async () => {
      const res = await fetchClose(`${TEST_URL}/ssi-protected`, { redirect: "manual" });
      expect(res.status).toBe(200);
      expect(res.headers.get("location")).toBeNull();
      expect(await res.text()).toContain("401 Authorization Required");
    });

    test("SSI include can render protected content with a valid session", async () => {
      const { sessionValue } = await createSession();

      const res = await fetchClose(`${TEST_URL}/ssi-protected`, {
        headers: { Cookie: `oidc_session=${sessionValue}` },
      });

      expect(res.status).toBe(200);
      expect(await res.text()).toContain('"status":"protected_content"');
    });

    test("mirror subrequest returns parent response cleanly", async () => {
      const res = await fetchClose(`${TEST_URL}/mirror-protected`, { redirect: "manual" });
      expect(res.status).toBe(200);
      expect(res.headers.get("location")).toBeNull();
      expect(await res.text()).toBe("oidc-mirror-ok");
    });
  });

  describe("public endpoints", () => {
    test("public endpoint allows access without OIDC", async () => {
      const res = await fetchClose(`${TEST_URL}/public`);
      expect(res.status).toBe(200);
      expect((await res.json()).status).toBe("public_content");
    });

    test("health endpoint works", async () => {
      const res = await fetchClose(`${TEST_URL}/`);
      expect(res.status).toBe(200);
      expect((await res.json()).status).toBe("ok");
    });
  });

});
