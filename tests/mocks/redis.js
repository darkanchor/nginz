import { spawnSync } from "bun";
/**
 * Mock Redis server using RESP (Redis Serialization Protocol)
 * Supports basic commands: PING, GET, SET, DEL, EXISTS, INCR, EXPIRE, TTL
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

export class RedisMock {
  constructor(port = 6379) {
    this.port = port;
    this.server = null;
    this.store = new Map();
    this.ttls = new Map();
    this.rawResponses = new Map();
  }

  start() {
    killStaleListeners(this.port);
    this.server = Bun.listen({
      hostname: "127.0.0.1",
      port: this.port,
      socket: {
        data: (socket, data) => this.handleData(socket, data),
        open: (socket) => {},
        close: (socket) => {},
        error: (socket, error) => console.error("Redis mock error:", error),
      },
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
    this.store.clear();
    this.ttls.clear();
    this.rawResponses.clear();
  }

  handleData(socket, data) {
    const input = data.toString();
    const lines = input.split("\r\n").filter((l) => l.length > 0);

    try {
      const response = this.parseAndExecute(lines);
      socket.write(response);
    } catch (err) {
      socket.write(`-ERR ${err.message}\r\n`);
    }
  }

  parseAndExecute(lines) {
    if (lines.length === 0) return "+OK\r\n";

    // Parse RESP array format: *<count>\r\n$<len>\r\n<data>\r\n...
    let idx = 0;
    const args = [];

    if (lines[0].startsWith("*")) {
      const count = parseInt(lines[0].slice(1));
      idx = 1;
      for (let i = 0; i < count && idx < lines.length; i++) {
        if (lines[idx].startsWith("$")) {
          idx++;
          if (idx < lines.length) {
            args.push(lines[idx]);
            idx++;
          }
        }
      }
    } else {
      // Inline command format
      args.push(...lines[0].split(" "));
    }

    if (args.length === 0) return "+OK\r\n";

    const cmd = args[0].toUpperCase();
    const override = this.rawResponses.get(`${cmd}:${args[1] ?? ""}`);
    if (override !== undefined) return override;

    switch (cmd) {
      case "PING":
        return args[1] ? `$${args[1].length}\r\n${args[1]}\r\n` : "+PONG\r\n";

      case "ECHO":
        if (args[1]) {
          return `$${args[1].length}\r\n${args[1]}\r\n`;
        }
        return "-ERR wrong number of arguments for 'echo' command\r\n";

      case "GET": {
        const key = args[1];
        if (!key) return "-ERR wrong number of arguments for 'get' command\r\n";
        this.checkExpired(key);
        const val = this.store.get(key);
        if (val === undefined) return "$-1\r\n"; // null bulk string
        return `$${val.length}\r\n${val}\r\n`;
      }

      case "SET": {
        const key = args[1];
        const val = args[2];
        if (!key || val === undefined)
          return "-ERR wrong number of arguments for 'set' command\r\n";
        this.store.set(key, val);

        // Handle EX/PX options
        for (let i = 3; i < args.length; i++) {
          const opt = args[i].toUpperCase();
          if (opt === "EX" && args[i + 1]) {
            const seconds = parseInt(args[i + 1]);
            this.ttls.set(key, Date.now() + seconds * 1000);
          } else if (opt === "PX" && args[i + 1]) {
            const ms = parseInt(args[i + 1]);
            this.ttls.set(key, Date.now() + ms);
          }
        }
        return "+OK\r\n";
      }

      case "DEL": {
        let count = 0;
        for (let i = 1; i < args.length; i++) {
          if (this.store.has(args[i])) {
            this.store.delete(args[i]);
            this.ttls.delete(args[i]);
            count++;
          }
        }
        return `:${count}\r\n`;
      }

      case "EXISTS": {
        let count = 0;
        for (let i = 1; i < args.length; i++) {
          this.checkExpired(args[i]);
          if (this.store.has(args[i])) count++;
        }
        return `:${count}\r\n`;
      }

      case "STRLEN": {
        const key = args[1];
        if (!key)
          return "-ERR wrong number of arguments for 'strlen' command\r\n";
        this.checkExpired(key);
        const val = this.store.get(key);
        if (val === undefined) return ":0\r\n";
        return `:${val.length}\r\n`;
      }

      case "HGET": {
        const key = args[1];
        const field = args[2];
        if (!key || !field)
          return "-ERR wrong number of arguments for 'hget' command\r\n";
        this.checkExpired(key);
        const hash = this.store.get(key);
        if (hash === undefined) return "$-1\r\n";
        // Store hash as JSON object
        let obj;
        try { obj = JSON.parse(hash); } catch { return "$-1\r\n"; }
        if (typeof obj !== "object" || obj === null) return "$-1\r\n";
        const fieldVal = obj[field];
        if (fieldVal === undefined) return "$-1\r\n";
        const strVal = String(fieldVal);
        return `$${strVal.length}\r\n${strVal}\r\n`;
      }

      case "HSET": {
        const key = args[1];
        const field = args[2];
        const val = args[3];
        if (!key || !field || val === undefined)
          return "-ERR wrong number of arguments for 'hset' command\r\n";
        this.checkExpired(key);
        const existing = this.store.get(key);
        let obj = {};
        if (existing) {
          try { obj = JSON.parse(existing); } catch { obj = {}; }
          if (typeof obj !== "object" || obj === null) obj = {};
        }
        const isNew = !(field in obj);
        obj[field] = val;
        this.store.set(key, JSON.stringify(obj));
        return `:${isNew ? 1 : 0}\r\n`;
      }

      case "HDEL": {
        const key = args[1];
        const field = args[2];
        if (!key || !field)
          return "-ERR wrong number of arguments for 'hdel' command\r\n";
        this.checkExpired(key);
        const existing = this.store.get(key);
        if (!existing) return ":0\r\n";
        let obj;
        try { obj = JSON.parse(existing); } catch { return ":0\r\n"; }
        if (typeof obj !== "object" || obj === null) return ":0\r\n";
        if (field in obj) {
          delete obj[field];
          this.store.set(key, JSON.stringify(obj));
          return ":1\r\n";
        }
        return ":0\r\n";
      }

      case "INCR": {
        const key = args[1];
        if (!key)
          return "-ERR wrong number of arguments for 'incr' command\r\n";
        this.checkExpired(key);
        let val = this.store.get(key);
        if (val === undefined) val = "0";
        const num = parseInt(val);
        if (isNaN(num))
          return "-ERR value is not an integer or out of range\r\n";
        const newVal = (num + 1).toString();
        this.store.set(key, newVal);
        return `:${num + 1}\r\n`;
      }

      case "DECR": {
        const key = args[1];
        if (!key)
          return "-ERR wrong number of arguments for 'decr' command\r\n";
        this.checkExpired(key);
        let val = this.store.get(key);
        if (val === undefined) val = "0";
        const num = parseInt(val);
        if (isNaN(num))
          return "-ERR value is not an integer or out of range\r\n";
        const newVal = (num - 1).toString();
        this.store.set(key, newVal);
        return `:${num - 1}\r\n`;
      }

      case "EXPIRE": {
        const key = args[1];
        const seconds = parseInt(args[2]);
        if (!key || isNaN(seconds))
          return "-ERR wrong number of arguments for 'expire' command\r\n";
        if (!this.store.has(key)) return ":0\r\n";
        this.ttls.set(key, Date.now() + seconds * 1000);
        return ":1\r\n";
      }

      case "TTL": {
        const key = args[1];
        if (!key)
          return "-ERR wrong number of arguments for 'ttl' command\r\n";
        if (!this.store.has(key)) return ":-2\r\n"; // key doesn't exist
        const expiry = this.ttls.get(key);
        if (!expiry) return ":-1\r\n"; // no TTL
        const remaining = Math.ceil((expiry - Date.now()) / 1000);
        if (remaining <= 0) {
          this.store.delete(key);
          this.ttls.delete(key);
          return ":-2\r\n";
        }
        return `:${remaining}\r\n`;
      }

      case "MGET": {
        const keys = args.slice(1);
        if (keys.length === 0)
          return "-ERR wrong number of arguments for 'mget' command\r\n";
        let response = `*${keys.length}\r\n`;
        for (const key of keys) {
          this.checkExpired(key);
          const val = this.store.get(key);
          if (val === undefined) {
            response += "$-1\r\n";
          } else {
            response += `$${val.length}\r\n${val}\r\n`;
          }
        }
        return response;
      }

      case "MSET": {
        if (args.length < 3 || (args.length - 1) % 2 !== 0)
          return "-ERR wrong number of arguments for 'mset' command\r\n";
        for (let i = 1; i < args.length; i += 2) {
          this.store.set(args[i], args[i + 1]);
        }
        return "+OK\r\n";
      }

      case "KEYS": {
        const pattern = args[1] || "*";
        const keys = [...this.store.keys()].filter((k) => {
          this.checkExpired(k);
          return this.store.has(k) && this.matchPattern(pattern, k);
        });
        let response = `*${keys.length}\r\n`;
        for (const key of keys) {
          response += `$${key.length}\r\n${key}\r\n`;
        }
        return response;
      }

      case "FLUSHDB":
      case "FLUSHALL":
        this.store.clear();
        this.ttls.clear();
        return "+OK\r\n";

      case "INFO":
        const info = "# Server\r\nredis_version:mock\r\n";
        return `$${info.length}\r\n${info}\r\n`;

      case "COMMAND":
        return "*0\r\n";

      case "QUIT":
        return "+OK\r\n";

      default:
        return `-ERR unknown command '${cmd}'\r\n`;
    }
  }

  setRawResponse(command, firstArg, response) {
    this.rawResponses.set(`${command.toUpperCase()}:${firstArg}`, response);
  }

  checkExpired(key) {
    const expiry = this.ttls.get(key);
    if (expiry && Date.now() > expiry) {
      this.store.delete(key);
      this.ttls.delete(key);
    }
  }

  matchPattern(pattern, str) {
    if (pattern === "*") return true;
    // Simple glob matching
    const regex = new RegExp(
      "^" + pattern.replace(/\*/g, ".*").replace(/\?/g, ".") + "$"
    );
    return regex.test(str);
  }

  // Helper methods for testing
  setValue(key, value) {
    this.store.set(key, value);
  }

  getValue(key) {
    return this.store.get(key);
  }

  clear() {
    this.store.clear();
    this.ttls.clear();
  }
}

function sleepSync(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

export function createRedisMock(port = 6379) {
  // Retry bind: sequential describes share remapped mock ports and Bun.listen
  // can briefly reject re-bind after stop(true).
  let lastError = null;
  for (let attempt = 0; attempt < 10; attempt++) {
    if (attempt > 0) sleepSync(30 * attempt);
    try {
      return new RedisMock(port).start();
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error(`Failed to start Redis mock on port ${port}`);
}
