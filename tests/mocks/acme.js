import { spawnSync } from "bun";
/**
 * Mock ACME (Let's Encrypt) server
 * Implements RFC 8555 ACME protocol for testing certificate automation
 */

import { randomBytes } from "crypto";


function killStaleListeners(port) {
  for (const cmd of [
    ["ss", "-ltnp", `sport = :${port}`],
    ["sudo", "-n", "ss", "-ltnp", `sport = :${port}`],
  ]) {
    try {
      const ss = spawnSync(cmd, { stdout: "pipe", stderr: "ignore" });
      const raw = ss.stdout;
      const text = raw == null
        ? ""
        : typeof raw === "string"
          ? raw
          : Buffer.from(raw).toString();
      for (const match of text.matchAll(/pid=(\d+)/g)) {
        const pid = Number(match[1]);
        if (pid > 0 && pid !== process.pid) {
          try {
            process.kill(pid, "SIGKILL");
          } catch {}
          try {
            spawnSync(["sudo", "-n", "kill", "-9", String(pid)], {
              stdout: "ignore",
              stderr: "ignore",
            });
          } catch {}
        }
      }
    } catch {}
  }
}

function stopStaleAcmeDocker() {
  // Live Pebble suite uses host networking. Orphans must not pin ports for the
  // next run; docker rm is reliable even when unprivileged ss hides pids.
  // Do not use interactive `sudo docker` — password prompts hang beforeAll.
  for (const docker of [["sudo", "-n", "docker"], ["docker"]]) {
    try {
      const listed = spawnSync(
        [...docker, "ps", "-aq", "--filter", "name=nginz-acme"],
        { stdout: "pipe", stderr: "ignore" },
      );
      if (listed.exitCode !== 0 && listed.exitCode != null) continue;
      const raw = listed.stdout;
      const text = raw == null
        ? ""
        : typeof raw === "string"
          ? raw
          : Buffer.from(raw).toString();
      for (const id of text.trim().split(/\s+/).filter(Boolean)) {
        try {
          spawnSync([...docker, "rm", "-f", id], {
            stdout: "ignore",
            stderr: "ignore",
          });
        } catch {}
      }
      return;
    } catch {}
  }
}

export class ACMEMock {
  // Default 14001: keep unit mock off Pebble's host-network :14000.
  constructor(port = 14001) {
    this.port = port;
    this.server = null;
    this.baseUrl = `http://127.0.0.1:${port}`;

    // State
    this.accounts = new Map(); // kid -> account
    this.orders = new Map(); // orderId -> order
    this.authorizations = new Map(); // authzId -> authorization
    this.challenges = new Map(); // challengeId -> challenge
    this.certificates = new Map(); // certId -> certificate
    this.nonces = new Set();

    // Generate some nonces
    for (let i = 0; i < 10; i++) {
      this.nonces.add(this.generateNonce());
    }
  }

  start() {
    killStaleListeners(this.port);
    this.server = Bun.serve({
      port: this.port,
      fetch: (req) => this.handleRequest(req),
    });
    return this;
  }

  stop() {
    if (this.server) {
      // Force-close so the listen port is released promptly for the next suite.
      try {
        this.server.stop(true);
      } catch {
        try {
          this.server.stop();
        } catch {}
      }
      this.server = null;
    }
    this.accounts.clear();
    this.orders.clear();
    this.authorizations.clear();
    this.challenges.clear();
    this.certificates.clear();
  }

  async handleRequest(req) {
    const url = new URL(req.url);
    const path = url.pathname;
    const method = req.method;

    // Add CORS headers for testing
    const headers = {
      "Content-Type": "application/json",
      "Replay-Nonce": this.getNewNonce(),
      "Cache-Control": "no-store",
    };

    // Directory
    if (path === "/directory") {
      return this.jsonResponse(
        {
          newNonce: `${this.baseUrl}/new-nonce`,
          newAccount: `${this.baseUrl}/new-account`,
          newOrder: `${this.baseUrl}/new-order`,
          revokeCert: `${this.baseUrl}/revoke-cert`,
          keyChange: `${this.baseUrl}/key-change`,
          meta: {
            termsOfService: `${this.baseUrl}/terms`,
            website: "https://example.com",
            caaIdentities: ["example.com"],
            externalAccountRequired: false,
          },
        },
        headers
      );
    }

    // New Nonce
    if (path === "/new-nonce") {
      if (method === "HEAD" || method === "GET") {
        return new Response(null, {
          status: 200,
          headers,
        });
      }
    }

    // For POST requests, validate nonce
    if (method === "POST") {
      // In real implementation, we'd verify JWS and nonce
      // For testing, we just accept the request
    }

    // New Account
    if (path === "/new-account" && method === "POST") {
      return await this.handleNewAccount(req, headers);
    }

    // Account
    const accountMatch = path.match(/^\/account\/(.+)$/);
    if (accountMatch && method === "POST") {
      return this.handleAccount(accountMatch[1], headers);
    }

    // New Order
    if (path === "/new-order" && method === "POST") {
      return await this.handleNewOrder(req, headers);
    }

    // Order
    const orderMatch = path.match(/^\/order\/(.+)$/);
    if (orderMatch) {
      return this.handleOrder(orderMatch[1], headers);
    }

    // Authorization
    const authzMatch = path.match(/^\/authz\/(.+)$/);
    if (authzMatch) {
      return this.handleAuthz(authzMatch[1], headers);
    }

    // Challenge
    const challengeMatch = path.match(/^\/challenge\/(.+)$/);
    if (challengeMatch && method === "POST") {
      return await this.handleChallenge(challengeMatch[1], headers);
    }

    // Finalize
    const finalizeMatch = path.match(/^\/finalize\/(.+)$/);
    if (finalizeMatch && method === "POST") {
      return await this.handleFinalize(finalizeMatch[1], req, headers);
    }

    // Certificate
    const certMatch = path.match(/^\/cert\/(.+)$/);
    if (certMatch) {
      return this.handleCertificate(certMatch[1], headers);
    }

    // Revoke Certificate
    if (path === "/revoke-cert" && method === "POST") {
      return this.jsonResponse({}, headers);
    }

    return new Response("Not Found", { status: 404, headers });
  }

  async parseAcmeBody(req) {
    const raw = await req.text().catch(() => "");
    if (!raw) return {};

    const parsed = JSON.parse(raw);

    if (parsed && typeof parsed === "object" && typeof parsed.payload === "string") {
      if (parsed.payload.length === 0) {
        return {};
      }

      const decoded = Buffer.from(parsed.payload, "base64url").toString("utf8");
      return decoded ? JSON.parse(decoded) : {};
    }

    return parsed;
  }

  async handleNewAccount(req, headers) {
    const body = await this.parseAcmeBody(req).catch(() => ({}));
    const accountId = this.generateId();
    const kid = `${this.baseUrl}/account/${accountId}`;

    const account = {
      id: accountId,
      status: "valid",
      contact: body.contact || [],
      termsOfServiceAgreed: body.termsOfServiceAgreed || false,
      orders: `${this.baseUrl}/orders/${accountId}`,
      createdAt: new Date().toISOString(),
    };

    this.accounts.set(accountId, account);

    return this.jsonResponse(
      {
        status: account.status,
        contact: account.contact,
        orders: account.orders,
      },
      {
        ...headers,
        Location: kid,
      },
      201
    );
  }

  handleAccount(accountId, headers) {
    const account = this.accounts.get(accountId);
    if (!account) {
      return this.errorResponse("accountDoesNotExist", "Account not found", headers);
    }

    return this.jsonResponse(
      {
        status: account.status,
        contact: account.contact,
        orders: account.orders,
      },
      headers
    );
  }

  async handleNewOrder(req, headers) {
    const body = await this.parseAcmeBody(req).catch(() => ({}));
    const identifiers = body.identifiers || [];

    if (identifiers.length === 0) {
      return this.errorResponse("malformed", "No identifiers provided", headers);
    }

    const orderId = this.generateId();
    const authzIds = [];

    // Create authorizations for each identifier
    for (const identifier of identifiers) {
      const authzId = this.generateId();
      const challengeId = this.generateId();
      const token = this.generateToken();

      const challenge = {
        id: challengeId,
        type: "http-01",
        url: `${this.baseUrl}/challenge/${challengeId}`,
        token,
        status: "pending",
      };

      const authz = {
        id: authzId,
        status: "pending",
        identifier,
        challenges: [challenge],
        expires: new Date(Date.now() + 86400000).toISOString(),
      };

      this.challenges.set(challengeId, { ...challenge, authzId });
      this.authorizations.set(authzId, authz);
      authzIds.push(authzId);
    }

    const order = {
      id: orderId,
      status: "pending",
      identifiers,
      authorizations: authzIds.map((id) => `${this.baseUrl}/authz/${id}`),
      finalize: `${this.baseUrl}/finalize/${orderId}`,
      expires: new Date(Date.now() + 86400000).toISOString(),
    };

    this.orders.set(orderId, order);

    return this.jsonResponse(
      {
        status: order.status,
        expires: order.expires,
        identifiers: order.identifiers,
        authorizations: order.authorizations,
        finalize: order.finalize,
      },
      {
        ...headers,
        Location: `${this.baseUrl}/order/${orderId}`,
      },
      201
    );
  }

  handleOrder(orderId, headers) {
    const order = this.orders.get(orderId);
    if (!order) {
      return this.errorResponse("orderNotFound", "Order not found", headers);
    }

    const response = {
      status: order.status,
      expires: order.expires,
      identifiers: order.identifiers,
      authorizations: order.authorizations,
      finalize: order.finalize,
    };

    if (order.certificate) {
      response.certificate = order.certificate;
    }

    return this.jsonResponse(response, headers);
  }

  handleAuthz(authzId, headers) {
    const authz = this.authorizations.get(authzId);
    if (!authz) {
      return this.errorResponse("authorizationNotFound", "Authorization not found", headers);
    }

    return this.jsonResponse(
      {
        status: authz.status,
        identifier: authz.identifier,
        challenges: authz.challenges.map((c) => ({
          type: c.type,
          url: c.url,
          token: c.token,
          status: c.status,
        })),
        expires: authz.expires,
      },
      headers
    );
  }

  async handleChallenge(challengeId, headers) {
    const challenge = this.challenges.get(challengeId);
    if (!challenge) {
      return this.errorResponse("challengeNotFound", "Challenge not found", headers);
    }

    // Simulate challenge validation (auto-pass for testing)
    challenge.status = "valid";
    challenge.validated = new Date().toISOString();

    // Update authorization
    const authz = this.authorizations.get(challenge.authzId);
    if (authz) {
      authz.status = "valid";
      authz.challenges = authz.challenges.map((c) =>
        c.id === challengeId ? challenge : c
      );

      // Check if all authorizations for the order are valid
      for (const [orderId, order] of this.orders) {
        const orderAuthzIds = order.authorizations.map((url) =>
          url.split("/").pop()
        );
        if (orderAuthzIds.includes(challenge.authzId)) {
          const allValid = orderAuthzIds.every((id) => {
            const a = this.authorizations.get(id);
            return a && a.status === "valid";
          });
          if (allValid) {
            order.status = "ready";
          }
        }
      }
    }

    return this.jsonResponse(
      {
        type: challenge.type,
        url: challenge.url,
        token: challenge.token,
        status: challenge.status,
        validated: challenge.validated,
      },
      headers
    );
  }

  async handleFinalize(orderId, req, headers) {
    const order = this.orders.get(orderId);
    if (!order) {
      return this.errorResponse("orderNotFound", "Order not found", headers);
    }

    if (order.status !== "ready") {
      return this.errorResponse(
        "orderNotReady",
        "Order is not ready for finalization",
        headers
      );
    }

    const body = await this.parseAcmeBody(req).catch(() => ({}));
    if (!body.csr) {
      return this.errorResponse("malformed", "Missing CSR", headers);
    }

    // Generate certificate
    const certId = this.generateId();
    const certPem = this.generateMockCertificate(order.identifiers);
    this.certificates.set(certId, certPem);

    order.status = "valid";
    order.certificate = `${this.baseUrl}/cert/${certId}`;

    return this.jsonResponse(
      {
        status: order.status,
        expires: order.expires,
        identifiers: order.identifiers,
        authorizations: order.authorizations,
        finalize: order.finalize,
        certificate: order.certificate,
      },
      headers
    );
  }

  handleCertificate(certId, headers) {
    const cert = this.certificates.get(certId);
    if (!cert) {
      return this.errorResponse("certificateNotFound", "Certificate not found", headers);
    }

    return new Response(cert, {
      status: 200,
      headers: {
        ...headers,
        "Content-Type": "application/pem-certificate-chain",
      },
    });
  }

  generateMockCertificate(identifiers) {
    // Generate a mock PEM certificate (not valid, just for testing)
    const domains = identifiers.map((id) => id.value).join(", ");
    return `-----BEGIN CERTIFICATE-----
MIIC+TCCAeGgAwIBAgIJAMockCertificate
Mock certificate for: ${domains}
Generated at: ${new Date().toISOString()}
This is a mock certificate for testing purposes only.
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIC+TCCAeGgAwIBAgIJAMockIssuerCert
Mock issuer certificate
-----END CERTIFICATE-----`;
  }

  generateId() {
    return randomBytes(16).toString("hex");
  }

  generateToken() {
    return randomBytes(32)
      .toString("base64url")
      .replace(/[^a-zA-Z0-9_-]/g, "");
  }

  generateNonce() {
    return randomBytes(16).toString("base64url");
  }

  getNewNonce() {
    const nonce = this.generateNonce();
    this.nonces.add(nonce);
    return nonce;
  }

  jsonResponse(data, headers, status = 200) {
    return new Response(JSON.stringify(data), {
      status,
      headers: {
        "Content-Type": "application/json",
        ...headers,
      },
    });
  }

  errorResponse(type, detail, headers, status = 400) {
    return new Response(
      JSON.stringify({
        type: `urn:ietf:params:acme:error:${type}`,
        detail,
        status,
      }),
      {
        status,
        headers: {
          "Content-Type": "application/problem+json",
          ...headers,
        },
      }
    );
  }

  // Helper methods for testing
  getChallenge(challengeId) {
    return this.challenges.get(challengeId);
  }

  getChallengeByToken(token) {
    for (const challenge of this.challenges.values()) {
      if (challenge.token === token) {
        return challenge;
      }
    }
    return null;
  }

  setOrderStatus(orderId, status) {
    const order = this.orders.get(orderId);
    if (order) {
      order.status = status;
    }
  }

  clearState() {
    this.accounts.clear();
    this.orders.clear();
    this.authorizations.clear();
    this.challenges.clear();
    this.certificates.clear();
  }
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

export function createACMEMock(port = 14001) {
  // Retry bind: sequential describes share mock ports and Bun.serve
  // can briefly reject re-bind after stop(true).
  stopStaleAcmeDocker();
  let lastError = null;
  for (let attempt = 0; attempt < 12; attempt++) {
    if (attempt > 0) {
      killStaleListeners(port);
      sleepSync(40 * attempt);
    } else {
      killStaleListeners(port);
    }
    try {
      return new ACMEMock(port).start();
    } catch (error) {
      lastError = error;
      const msg = String(error?.message || error);
      if (!/EADDRINUSE|in use/i.test(msg)) break;
    }
  }
  throw lastError ?? new Error(`Failed to start ACME mock on port ${port}`);
}
