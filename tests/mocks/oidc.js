/**
 * Mock OIDC/OAuth2 Provider with RS256-signed ID tokens.
 */

import { createHash, createPrivateKey, createPublicKey, randomBytes, sign } from "crypto";

const PRIVATE_KEY_PEM = `-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC+d7npgnxZpnjy
0r6jVxkMI7qeLTRi5iqqo8d8DI0ttyN1o8POLgDo0L5df6zn/N5rX2Ai5ZQR4+cO
Tp5A3SKZTQ+7GIEfTJHVSoZN7OTFIZu87S8zHvn2/gsLdRYGVm49QxI917wQSxjI
8xxb0WR0Y2qIA0NWjLsCDB+qHCUDgSaohKcpXOE5zADCOkZcwbOjKR6ALcwES4DS
P4+1Xypp+Ovao2oO4+0JXfBTx/FPTdgwoYPNn4f/NpDHWlEwaUktcRuPKiL9o8Tp
vKazLBSkknHETMcQzN7G+K3vXHU0MaT7YG+TF14j8bsnVqhmSUG9IlwB/KIcamz5
eR/JMJ+BAgMBAAECggEAAmy7JFmvuDM0Jti3mjQalrbJelgmWqQ2GrckK+xLu49R
W2742BoKM0yNgNqWTpt/sB+eJWGVcosbgtlNvtMF3MxgKPRHWAj5Mg09Y5ZyhN8w
OK3vD/Q678nVBYnBfJYK+BsPi1Og0ncHRy8fnzxdnlTx6y558+sNmimB+XAbaUWM
7vQebIVcPItf1DyOzozsZOE4LCWVFjfFZBdGRG3OHYjPI37B8u6GCFYH+NJlGSvq
N62ru0r9cn68/rmZeMwsfr22d/rHdLWKw3ItRiEPqBNM/7p+Uhg+SR90o0FuxDpl
Fswfq8n2l8xLZ0lMlRmWaUZBiqSAwL4j2B93oFNdwQKBgQDu/QfetpQIGhZvzcSg
hvJfW23pkwQlW9RsEYISD7FZWB/8K/xAfIHltYT9Qhk/Hmov1nvDn7fsXa1MX1Jt
oy5kOECMJAerZezNkJnv8Mx81nD6kd4BDw58rLNtMm2hg59DizSTJRTWb1kkgquZ
oVo3NvMsXbdCNxZaaZbuCVKVIQKBgQDMBoaom/eepIR91t12FqLCNVMOnM7BPea3
0qihgRDucPi8p00uAFEMYDxZAQnyoESYbOYg2Ek5aJlSYPucx7IgdAXw6k0UgZqN
uO0aWY/GZyRDC2PFCkIN1uwEUlx+/bYqEkVM0TsyiOzUrTxi7oj5puhESd+6TLpR
uojYxaReYQKBgQDkLvgKr6zbp3zwtzkcRHy6i2OAdvyoZuuFW5ojgJRGyBuR/LVX
JQopt40I+sl8OKAOmO2GtMM5jZ/focvkHsA2tHb815HzFtho1b4FGJdGQsGQnSGp
RSUB6StQAawnYLL6HLnQHMGulJY6hAEwKJ0oxvCb1ccaE9rl7JdNI92TwQKBgCtc
F7Its2pbvGyiBV7bYKu1eXlZifc3mJjohD4Ol/KUv8gYJibomlDvAuRHfD28Idfj
DOVeEfHJcQw44EBpkEmlXr3cjZUWFiqYaot3DT81HFfDS+jMTU1zp6Uje9ThRp2a
VHAG53XN88cfKf48g4/LEQGyUYHeXJqR8hNfrZcBAoGAQhfkGnVOcHvLbWZcbtNi
drQJ3gHBFyGMF/WOjGhGbr9C1r+shE+oS0lOa34pMXB/WeKKOrwXqkrcQjJkdwrh
WfwfAry/uZdccrgVj1X8niiuopcRWLrFLsXRI2yZddUyv3R0oG4dPKPp0rorSnaS
NVrMBFiaJjC7CPH6DScxnrw=
-----END PRIVATE KEY-----`;

function base64urlJson(value) {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

export class OIDCMock {
  constructor(port = 9000) {
    this.port = port;
    this.server = null;
    this.issuer = `http://127.0.0.1:${port}`;
    this.authorizationCodes = new Map();
    this.tokens = new Map();
    this.refreshTokens = new Map();
    this.users = new Map();
    this.clients = new Map();
    this.nextTokenOverrides = null;

    this.privateKey = createPrivateKey(PRIVATE_KEY_PEM);
    this.publicKey = createPublicKey(this.privateKey);
    this.keyId = "test-key-1";

    this.registerClient("test-client", "test-secret", [
      "http://localhost:8888/callback",
      "http://localhost:8888/callback-oversized",
      "http://127.0.0.1:8888/callback",
    ]);

    this.registerUser("user1", {
      sub: "user1",
      name: "Test User",
      email: "test@example.com",
      email_verified: true,
    });
  }

  start() {
    this.server = Bun.serve({
      port: this.port,
      fetch: (req) => this.handleRequest(req),
    });
    return this;
  }

  stop() {
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
    this.authorizationCodes.clear();
    this.tokens.clear();
    this.refreshTokens.clear();
    this.nextTokenOverrides = null;
  }

  setNextTokenOverrides(overrides) {
    this.nextTokenOverrides = { ...overrides };
  }

  getJwks() {
    const jwk = this.publicKey.export({ format: "jwk" });
    return {
      keys: [
        {
          kty: "RSA",
          kid: this.keyId,
          use: "sig",
          alg: "RS256",
          n: jwk.n,
          e: jwk.e,
        },
      ],
    };
  }

  async handleRequest(req) {
    const url = new URL(req.url);
    const path = url.pathname;
    const method = req.method;

    if (path === "/.well-known/openid-configuration") {
      return this.jsonResponse({
        issuer: this.issuer,
        authorization_endpoint: `${this.issuer}/authorize`,
        token_endpoint: `${this.issuer}/token`,
        userinfo_endpoint: `${this.issuer}/userinfo`,
        jwks_uri: `${this.issuer}/.well-known/jwks.json`,
        response_types_supported: ["code"],
        subject_types_supported: ["public"],
        id_token_signing_alg_values_supported: ["RS256"],
        scopes_supported: ["openid", "profile", "email"],
        token_endpoint_auth_methods_supported: [
          "client_secret_post",
          "client_secret_basic",
        ],
        claims_supported: ["sub", "iss", "aud", "exp", "iat", "nonce", "email", "name"],
        code_challenge_methods_supported: ["S256", "plain"],
        grant_types_supported: ["authorization_code", "refresh_token"],
      });
    }

    if (path === "/.well-known/jwks.json") {
      return this.jsonResponse(this.getJwks());
    }

    if (path === "/.well-known/oversized-jwks.json") {
      return new Response("x".repeat(1024 * 1024 + 1), {
        status: 200,
        headers: { "Content-Type": "application/json" },
      });
    }

    if (path === "/authorize") {
      return this.handleAuthorize(url);
    }

    if (path === "/token" && method === "POST") {
      return await this.handleToken(req);
    }

    if (path === "/userinfo") {
      return this.handleUserInfo(req);
    }

    return new Response("Not Found", { status: 404 });
  }

  handleAuthorize(url) {
    const clientId = url.searchParams.get("client_id");
    const redirectUri = url.searchParams.get("redirect_uri");
    const scope = url.searchParams.get("scope") || "openid";
    const state = url.searchParams.get("state");
    const nonce = url.searchParams.get("nonce");
    const codeChallenge = url.searchParams.get("code_challenge");
    const codeChallengeMethod =
      url.searchParams.get("code_challenge_method") || "plain";

    const client = this.clients.get(clientId);
    if (!client) {
      return this.errorRedirect(redirectUri, "invalid_client", "Unknown client", state);
    }

    if (!client.redirectUris.includes(redirectUri)) {
      return new Response("Invalid redirect_uri", { status: 400 });
    }

    const code = this.generateCode();
    this.authorizationCodes.set(code, {
      clientId,
      redirectUri,
      scope,
      nonce,
      codeChallenge,
      codeChallengeMethod,
      sub: "user1",
      exp: Date.now() + 600_000,
      tokenOverrides: this.nextTokenOverrides,
    });
    this.nextTokenOverrides = null;

    const redirectUrl = new URL(redirectUri);
    redirectUrl.searchParams.set("code", code);
    if (state) redirectUrl.searchParams.set("state", state);
    return Response.redirect(redirectUrl.toString(), 302);
  }

  async handleToken(req) {
    const contentType = req.headers.get("content-type") || "";
    let params;

    if (contentType.includes("application/x-www-form-urlencoded")) {
      params = new URLSearchParams(await req.text());
    } else if (contentType.includes("application/json")) {
      params = new URLSearchParams(await req.json());
    } else {
      return this.jsonError("invalid_request", "Invalid content type");
    }

    let clientId = params.get("client_id");
    let clientSecret = params.get("client_secret");
    const authHeader = req.headers.get("authorization");
    if (authHeader?.startsWith("Basic ")) {
      const decoded = atob(authHeader.slice(6));
      const [id, secret] = decoded.split(":");
      clientId ||= id;
      clientSecret ||= secret;
    }

    const client = this.clients.get(clientId);
    if (!client || client.secret !== clientSecret) {
      return this.jsonError("invalid_client", "Invalid client credentials");
    }

    const grantType = params.get("grant_type");
    if (grantType === "authorization_code") {
      return this.handleAuthCodeGrant(params, clientId);
    }
    if (grantType === "refresh_token") {
      return this.handleRefreshTokenGrant(params, clientId);
    }
    return this.jsonError("unsupported_grant_type", "Unsupported grant type");
  }

  handleAuthCodeGrant(params, clientId) {
    const code = params.get("code");
    const redirectUri = params.get("redirect_uri");
    const codeVerifier = params.get("code_verifier");

    const authCode = this.authorizationCodes.get(code);
    if (!authCode) {
      return this.jsonError("invalid_grant", "Invalid authorization code");
    }

    if (Date.now() > authCode.exp) {
      this.authorizationCodes.delete(code);
      return this.jsonError("invalid_grant", "Authorization code expired");
    }

    if (authCode.clientId !== clientId) {
      return this.jsonError("invalid_grant", "Client ID mismatch");
    }

    if (authCode.redirectUri !== redirectUri) {
      return this.jsonError("invalid_grant", "Redirect URI mismatch");
    }

    if (authCode.codeChallenge) {
      if (!codeVerifier) {
        return this.jsonError("invalid_grant", "Code verifier required");
      }
      const challenge = this.computeCodeChallenge(
        codeVerifier,
        authCode.codeChallengeMethod
      );
      if (challenge !== authCode.codeChallenge) {
        return this.jsonError("invalid_grant", "Invalid code verifier");
      }
    }

    this.authorizationCodes.delete(code);
    return this.generateTokenResponse(
      authCode.sub,
      authCode.scope,
      authCode.nonce,
      authCode.clientId,
      authCode.tokenOverrides || {}
    );
  }

  handleRefreshTokenGrant(params) {
    const refreshToken = params.get("refresh_token");
    const tokenData = this.refreshTokens.get(refreshToken);
    if (!tokenData) {
      return this.jsonError("invalid_grant", "Invalid refresh token");
    }

    return this.generateTokenResponse(
      tokenData.sub,
      tokenData.scope,
      null,
      tokenData.clientId,
      {}
    );
  }

  generateTokenResponse(sub, scope, nonce, clientId, overrides = {}) {
    const accessToken = this.generateToken();
    const refreshToken = this.generateToken();
    const expiresIn = 3600;

    this.tokens.set(accessToken, {
      sub,
      scope,
      exp: Date.now() + expiresIn * 1000,
    });
    this.refreshTokens.set(refreshToken, { sub, scope, clientId });

    return this.jsonResponse({
      access_token: accessToken,
      token_type: "Bearer",
      expires_in: expiresIn,
      refresh_token: refreshToken,
      id_token: this.generateIdToken(sub, nonce, clientId, overrides),
      scope,
    });
  }

  generateIdToken(sub, nonce, clientId, overrides = {}) {
    const now = Math.floor(Date.now() / 1000);
    const user = this.users.get(overrides.sub || sub) || {};
    const header = {
      alg: overrides.alg || "RS256",
      typ: "JWT",
      kid: overrides.kid || this.keyId,
    };

    const payload = {
      iss: overrides.issuer || this.issuer,
      sub: overrides.sub || sub,
      aud: overrides.audience || clientId,
      exp:
        overrides.exp ??
        now + (overrides.expiresInSec !== undefined ? overrides.expiresInSec : 3600),
      iat: overrides.iat || now,
      nonce: overrides.nonce ?? nonce,
      ...(user.email && { email: user.email }),
      ...(user.email_verified !== undefined && {
        email_verified: user.email_verified,
      }),
      ...(user.name && { name: user.name }),
    };

    if (overrides.removeNonce) {
      delete payload.nonce;
    }
    if (overrides.removeSub) {
      delete payload.sub;
    }

    const signingInput = `${base64urlJson(header)}.${base64urlJson(payload)}`;
    const signature = sign("RSA-SHA256", Buffer.from(signingInput), this.privateKey);

    let signatureB64 = Buffer.from(signature).toString("base64url");
    if (overrides.tamperSignature) {
      // Mutate the first base64url character, not the trailing one: for RSA signatures,
      // the last unpadded base64url character can affect only ignored padding bits.
      const first = signatureB64[0];
      signatureB64 = `${first === "A" ? "B" : "A"}${signatureB64.slice(1)}`;
    }

    return `${signingInput}.${signatureB64}`;
  }

  handleUserInfo(req) {
    const authHeader = req.headers.get("authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response("Unauthorized", { status: 401 });
    }

    const token = authHeader.slice(7);
    const tokenData = this.tokens.get(token);
    if (!tokenData || Date.now() > tokenData.exp) {
      return new Response("Invalid token", { status: 401 });
    }

    const user = this.users.get(tokenData.sub);
    return this.jsonResponse(user || { sub: tokenData.sub });
  }

  computeCodeChallenge(verifier, method) {
    if (method === "plain") {
      return verifier;
    }
    return Buffer.from(createHash("sha256").update(verifier).digest()).toString(
      "base64url"
    );
  }

  generateCode() {
    return randomBytes(32).toString("hex");
  }

  generateToken() {
    return randomBytes(32).toString("hex");
  }

  jsonResponse(data) {
    return new Response(JSON.stringify(data), {
      headers: { "Content-Type": "application/json" },
    });
  }

  jsonError(error, description) {
    return new Response(JSON.stringify({ error, error_description: description }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  errorRedirect(redirectUri, error, description, state) {
    const url = new URL(redirectUri);
    url.searchParams.set("error", error);
    url.searchParams.set("error_description", description);
    if (state) url.searchParams.set("state", state);
    return Response.redirect(url.toString(), 302);
  }

  registerClient(clientId, secret, redirectUris) {
    this.clients.set(clientId, { secret, redirectUris });
  }

  registerUser(sub, userInfo) {
    this.users.set(sub, { sub, ...userInfo });
  }
}

export function createOIDCMock(port = 9000) {
  return new OIDCMock(port).start();
}
