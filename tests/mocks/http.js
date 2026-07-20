import { spawnSync } from "bun";
/**
 * Generic HTTP upstream mock server
 * Configurable responses for testing various scenarios
 */


function killStaleListeners(port) {
  try {
    const ss = spawnSync(["ss", "-ltnp", `sport = :${port}`], {
      stdout: "pipe",
      stderr: "ignore",
    });
    const raw = ss.stdout;
    const text = raw == null
      ? ""
      : typeof raw === "string"
        ? raw
        : Buffer.from(raw).toString();
    for (const match of text.matchAll(/pid=(\d+)/g)) {
      const pid = Number(match[1]);
      if (pid > 0 && pid !== process.pid) {
        try { process.kill(pid, "SIGKILL"); } catch {}
      }
    }
  } catch {}
}

export class HTTPMock {
  constructor(port = 9001) {
    this.port = port;
    this.server = null;
    this.routes = new Map(); // path -> { method -> handler }
    this.defaultHandler = null;
    this.requestLog = [];
    this.latency = 0;
    this.failureRate = 0; // 0-1, probability of returning 500
    this.requestCount = 0;
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
    this.routes.clear();
    this.requestLog = [];
    this.requestCount = 0;
  }

  async handleRequest(req) {
    this.requestCount++;

    // Log request
    const url = new URL(req.url);
    const logEntry = {
      method: req.method,
      path: url.pathname,
      query: Object.fromEntries(url.searchParams),
      headers: Object.fromEntries(req.headers),
      timestamp: Date.now(),
    };

    // Read body if present
    if (req.method !== "GET" && req.method !== "HEAD") {
      try {
        const contentType = req.headers.get("content-type") || "";
        if (contentType.includes("application/json")) {
          logEntry.body = await req.clone().json();
        } else {
          logEntry.body = await req.clone().text();
        }
      } catch {
        logEntry.body = null;
      }
    }

    this.requestLog.push(logEntry);

    // Simulate latency
    if (this.latency > 0) {
      await Bun.sleep(this.latency);
    }

    // Simulate random failures
    if (this.failureRate > 0 && Math.random() < this.failureRate) {
      return new Response("Internal Server Error", { status: 500 });
    }

    // Check for route-specific handler
    const routeHandlers = this.routes.get(url.pathname);
    if (routeHandlers) {
      const handler = routeHandlers.get(req.method) || routeHandlers.get("*");
      if (handler) {
        const result = await handler(req, url, logEntry);
        if (result instanceof Response) {
          return result;
        }
        return this.createResponse(result);
      }
    }

    // Check for pattern-based routes
    for (const [pattern, handlers] of this.routes) {
      if (pattern.includes("*") || pattern.includes(":")) {
        const regex = this.patternToRegex(pattern);
        const match = url.pathname.match(regex);
        if (match) {
          const handler = handlers.get(req.method) || handlers.get("*");
          if (handler) {
            logEntry.params = this.extractParams(pattern, match);
            const result = await handler(req, url, logEntry);
            if (result instanceof Response) {
              return result;
            }
            return this.createResponse(result);
          }
        }
      }
    }

    // Default handler
    if (this.defaultHandler) {
      const result = await this.defaultHandler(req, url, logEntry);
      if (result instanceof Response) {
        return result;
      }
      return this.createResponse(result);
    }

    // Default response
    return this.jsonResponse({ message: "OK", path: url.pathname });
  }

  patternToRegex(pattern) {
    const regexStr = pattern
      .replace(/\*/g, ".*")
      .replace(/:(\w+)/g, "([^/]+)");
    return new RegExp(`^${regexStr}$`);
  }

  extractParams(pattern, match) {
    const params = {};
    const paramNames = pattern.match(/:(\w+)/g) || [];
    paramNames.forEach((name, index) => {
      params[name.slice(1)] = match[index + 1];
    });
    return params;
  }

  createResponse(result) {
    if (typeof result === "string") {
      return new Response(result);
    }
    if (typeof result === "object") {
      if (result.body !== undefined) {
        const body =
          typeof result.body === "string"
            ? result.body
            : JSON.stringify(result.body);
        return new Response(body, {
          status: result.status || 200,
          headers: {
            "Content-Type":
              typeof result.body === "string"
                ? "text/plain"
                : "application/json",
            ...result.headers,
          },
        });
      }
      return this.jsonResponse(result);
    }
    return new Response(String(result));
  }

  jsonResponse(data, status = 200, headers = {}) {
    return new Response(JSON.stringify(data), {
      status,
      headers: {
        "Content-Type": "application/json",
        ...headers,
      },
    });
  }

  // Configuration methods

  /**
   * Register a route handler
   * @param {string} method - HTTP method (GET, POST, etc.) or '*' for any
   * @param {string} path - URL path, supports :param and * wildcards
   * @param {function|object} handler - Handler function or response object
   */
  on(method, path, handler) {
    if (!this.routes.has(path)) {
      this.routes.set(path, new Map());
    }
    const routeHandler =
      typeof handler === "function"
        ? handler
        : () => this.createResponse(handler);
    this.routes.get(path).set(method.toUpperCase(), routeHandler);
    return this;
  }

  // Convenience methods
  get(path, handler) {
    return this.on("GET", path, handler);
  }

  post(path, handler) {
    return this.on("POST", path, handler);
  }

  put(path, handler) {
    return this.on("PUT", path, handler);
  }

  delete(path, handler) {
    return this.on("DELETE", path, handler);
  }

  patch(path, handler) {
    return this.on("PATCH", path, handler);
  }

  any(path, handler) {
    return this.on("*", path, handler);
  }

  /**
   * Set default handler for unmatched routes
   */
  setDefault(handler) {
    this.defaultHandler =
      typeof handler === "function"
        ? handler
        : () => this.createResponse(handler);
    return this;
  }

  /**
   * Set artificial latency (ms)
   */
  setLatency(ms) {
    this.latency = ms;
    return this;
  }

  /**
   * Set failure rate (0-1)
   */
  setFailureRate(rate) {
    this.failureRate = Math.max(0, Math.min(1, rate));
    return this;
  }

  /**
   * Get all logged requests
   */
  getRequests() {
    return [...this.requestLog];
  }

  /**
   * Get requests matching a path
   */
  getRequestsFor(path, method) {
    return this.requestLog.filter(
      (r) =>
        r.path === path && (method === undefined || r.method === method)
    );
  }

  /**
   * Get the last request
   */
  getLastRequest() {
    return this.requestLog[this.requestLog.length - 1];
  }

  /**
   * Get request count
   */
  getRequestCount() {
    return this.requestCount;
  }

  /**
   * Clear request log
   */
  clearLog() {
    this.requestLog = [];
    this.requestCount = 0;
    return this;
  }

  /**
   * Clear all routes
   */
  clearRoutes() {
    this.routes.clear();
    this.defaultHandler = null;
    return this;
  }

  /**
   * Reset all state
   */
  reset() {
    this.clearRoutes();
    this.clearLog();
    this.latency = 0;
    this.failureRate = 0;
    return this;
  }
}

/**
 * Create a simple static file server mock
 */
export class StaticMock extends HTTPMock {
  constructor(port = 9002) {
    super(port);
    this.files = new Map();
  }

  /**
   * Add a file to serve
   */
  addFile(path, content, contentType = "text/plain") {
    this.files.set(path, { content, contentType });
    return this;
  }

  /**
   * Add multiple files
   */
  addFiles(files) {
    for (const [path, data] of Object.entries(files)) {
      if (typeof data === "string") {
        this.addFile(path, data);
      } else {
        this.addFile(path, data.content, data.contentType);
      }
    }
    return this;
  }

  start() {
    this.setDefault((req, url) => {
      const file = this.files.get(url.pathname);
      if (file) {
        return new Response(file.content, {
          headers: { "Content-Type": file.contentType },
        });
      }
      return new Response("Not Found", { status: 404 });
    });
    return super.start();
  }
}

/**
 * Create an HTTP mock that proxies to another server with modifications
 */
export class ProxyMock extends HTTPMock {
  constructor(port = 9003, targetUrl) {
    super(port);
    this.targetUrl = targetUrl;
    this.modifyRequest = null;
    this.modifyResponse = null;
  }

  /**
   * Set request modifier
   */
  onRequest(modifier) {
    this.modifyRequest = modifier;
    return this;
  }

  /**
   * Set response modifier
   */
  onResponse(modifier) {
    this.modifyResponse = modifier;
    return this;
  }

  start() {
    this.setDefault(async (req, url) => {
      let targetReq = {
        url: `${this.targetUrl}${url.pathname}${url.search}`,
        method: req.method,
        headers: Object.fromEntries(req.headers),
        body: req.body,
      };

      if (this.modifyRequest) {
        targetReq = await this.modifyRequest(targetReq, req);
      }

      try {
        let response = await fetch(targetReq.url, {
          method: targetReq.method,
          headers: targetReq.headers,
          body: targetReq.body,
        });

        if (this.modifyResponse) {
          response = await this.modifyResponse(response);
        }

        return response;
      } catch (error) {
        return new Response(`Proxy error: ${error.message}`, { status: 502 });
      }
    });
    return super.start();
  }
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function withBindRetry(factory, label, port) {
  // Retry bind: sequential describes share mock ports and Bun.serve / Bun.listen
  // can briefly reject re-bind after stop(true).
  let lastError = null;
  for (let attempt = 0; attempt < 10; attempt++) {
    if (attempt > 0) sleepSync(30 * attempt);
    try {
      return factory();
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error(`Failed to start ${label} on port ${port}`);
}

// Factory functions
export function createHTTPMock(port = 9001) {
  return withBindRetry(() => new HTTPMock(port).start(), "HTTP mock", port);
}

export function createStaticMock(port = 9002, files = {}) {
  return withBindRetry(() => {
    const mock = new StaticMock(port);
    mock.addFiles(files);
    return mock.start();
  }, "static mock", port);
}

export function createProxyMock(port = 9003, targetUrl) {
  return withBindRetry(
    () => new ProxyMock(port, targetUrl).start(),
    "proxy mock",
    port,
  );
}
