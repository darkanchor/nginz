import { describe, test, expect } from "bun:test";
import { spawn, spawnSync } from "bun";
import { existsSync, mkdirSync, readFileSync, rmSync } from "fs";
import { join } from "path";
import net from "net";
import tls from "tls";
import { buildMqttConnect, createMqttMock } from "../mocks/mqtt.js";

const MODULE = "mqtt";
const CONFIG = `tests/${MODULE}/nginx.conf`;
const INVALID_FIELD_CONFIG = `tests/${MODULE}/nginx-invalid-field.conf`;
const REWRITE_MATRIX_CONFIG = `tests/${MODULE}/nginx-rewrite-matrix.conf`;
const TLS_CONFIG = `tests/${MODULE}/nginx-tls.conf`;
const DESIGN = "src/modules/mqtt-nginx-module/README.md";
const MODULE_SRC = "src/modules/mqtt-nginx-module/ngx_stream_mqtt.zig";
const NGINZ_BIN = "./zig-out/bin/nginz";

function runtimeDir(name) {
  const dir = join(process.cwd(), "tests", MODULE, name);
  if (existsSync(dir)) rmSync(dir, { recursive: true });
  mkdirSync(join(dir, "logs"), { recursive: true });
  return dir;
}

function nginxTest(configPath, name) {
  const dir = runtimeDir(name);
  return spawnSync([NGINZ_BIN, "-t", "-p", dir, "-c", join(process.cwd(), configPath)], {
    cwd: process.cwd(),
    stdout: "pipe",
    stderr: "pipe",
  });
}

async function waitForTcpPort(port, timeout = 5000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const socket = await Bun.connect({
        hostname: "127.0.0.1",
        port,
        socket: {
          open(s) { s.end(); },
          data() {},
          close() {},
          error() {},
        },
      });
      return;
    } catch {
      await Bun.sleep(50);
    }
  }
  throw new Error(`timeout waiting for TCP port ${port}`);
}

async function startNginz(configPath, name, port) {
  const dir = runtimeDir(name);
  const proc = spawn([NGINZ_BIN, "-p", dir, "-c", join(process.cwd(), configPath)], {
    cwd: process.cwd(),
    stdout: "pipe",
    stderr: "pipe",
  });
  await waitForTcpPort(port);
  return proc;
}

async function stopNginz(proc) {
  if (!proc) return;
  proc.kill("SIGTERM");
  await proc.exited;
}

function tcpExchange(port, payload) {
  return tcpExchangeChunks(port, [payload]);
}

function tcpExchangeChunks(port, chunks, delayMs = 25) {
  return new Promise((resolve, reject) => {
    const received = [];
    let done = false;
    const socket = new net.Socket();

    function finish() {
      if (done) return;
      done = true;
      socket.end();
      resolve(Buffer.concat(received));
    }

    socket.connect(port, "127.0.0.1", () => {
      chunks.forEach((chunk, index) => {
        setTimeout(() => {
          if (!done) socket.write(chunk);
        }, index * delayMs);
      });
    });
    socket.on("data", (data) => {
      received.push(Buffer.from(data));
      finish();
    });
    socket.on("close", () => {
      if (!done) {
        done = true;
        resolve(Buffer.concat(received));
      }
    });
    socket.on("error", reject);
  });
}

function tlsExchange(port, payload) {
  return new Promise((resolve, reject) => {
    const received = [];
    let done = false;
    const socket = tls.connect({
      host: "127.0.0.1",
      port,
      rejectUnauthorized: false,
      servername: "localhost",
    }, () => {
      socket.write(payload);
    });

    function finish() {
      if (done) return;
      done = true;
      socket.end();
      resolve(Buffer.concat(received));
    }

    socket.on("data", (data) => {
      received.push(Buffer.from(data));
      finish();
    });
    socket.on("close", () => {
      if (!done) {
        done = true;
        resolve(Buffer.concat(received));
      }
    });
    socket.on("error", reject);
  });
}

describe("mqtt stream module scaffold", () => {
  test("owns stream nginx fixtures", () => {
    const config = readFileSync(CONFIG, "utf8");
    expect(config).toContain("stream {");
    expect(config).toContain("mqtt_preread on;");
    expect(config).toContain("mqtt on;");
    expect(config).toContain('hash $mqtt_preread_clientid consistent;');
    expect(config).toContain('mqtt_set_connect clientid "$mqtt_preread_clientid:$remote_addr";');
    expect(config).toContain('mqtt_set_connect username "$mqtt_preread_username@edge-a";');
    expect(config).toContain('mqtt_set_connect password "broker-local-secret";');
    const matrix = readFileSync(REWRITE_MATRIX_CONFIG, "utf8");
    expect(matrix).toContain('mqtt_set_connect username "";');
    expect(matrix).toContain('mqtt_set_connect password "";');
    expect(matrix).toContain('mqtt_set_connect password "added-secret";');
    expect(matrix).toContain('mqtt_set_connect username "added-user";');
    expect(matrix).toContain('mqtt_set_connect password "new-secret";');
    const tlsConfig = readFileSync(TLS_CONFIG, "utf8");
    expect(tlsConfig).toContain("listen 18893 ssl;");
    expect(tlsConfig).toContain("ssl_certificate");
  });

  test("has module source and detailed design doc", () => {
    expect(existsSync(MODULE_SRC)).toBe(true);
    expect(existsSync(DESIGN)).toBe(true);

    const design = readFileSync(DESIGN, "utf8");
    expect(design).toContain("CONNECT Parser Design");
    expect(design).toContain("Rewrite Design");
    expect(design).toContain("Implementation Phases");
  });

  test("package manifest declares MQTT as stream modules", () => {
    const src = readFileSync("project/build_package.zig", "utf8");
    expect(src).toContain("src/modules/mqtt-nginx-module/ngx_stream_mqtt.zig");
    expect(src).toContain('"ngx_stream_mqtt_preread_module"');
    expect(src).toContain('"ngx_stream_mqtt_filter_module"');
    expect(src).toContain(".STREAM");
  });

  test("bundled nginz registers MQTT stream modules", () => {
    const modules = readFileSync("src/ngz_modules.zig", "utf8");
    expect(modules).toContain("extern var ngx_stream_mqtt_preread_module");
    expect(modules).toContain("extern var ngx_stream_mqtt_filter_module");
    expect(modules).toContain("&ngx_stream_mqtt_preread_module");
    expect(modules).toContain("&ngx_stream_mqtt_filter_module");
  });

  test("nginx -t accepts MQTT stream directives and variables", () => {
    const result = nginxTest(CONFIG, "runtime-valid");
    const stderr = Buffer.from(result.stderr).toString();
    expect(result.exitCode, stderr).toBe(0);
    expect(stderr).toContain("syntax is ok");
  });

  test("nginx -t rejects unsupported mqtt_set_connect fields", () => {
    const result = nginxTest(INVALID_FIELD_CONFIG, "runtime-invalid-field");
    const stderr = Buffer.from(result.stderr).toString();
    expect(stderr).toContain("invalid MQTT CONNECT field");
    expect(stderr).toContain("test failed");
  });

  test("nginx -t accepts MQTT rewrite matrix fixture", () => {
    const result = nginxTest(REWRITE_MATRIX_CONFIG, "runtime-rewrite-matrix-valid");
    const stderr = Buffer.from(result.stderr).toString();
    expect(result.exitCode, stderr).toBe(0);
    expect(stderr).toContain("syntax is ok");
  });

  test("nginx -t accepts MQTT TLS stream fixture", () => {
    const result = nginxTest(TLS_CONFIG, "runtime-tls-valid");
    const stderr = Buffer.from(result.stderr).toString();
    expect(result.exitCode, stderr).toBe(0);
    expect(stderr).toContain("syntax is ok");
  });

  test("runtime preread variable returns MQTT username", async () => {
    const proc = await startNginz(CONFIG, "runtime-preread-variable", 18886);
    try {
      const packet = buildMqttConnect({
        clientId: "client-runtime",
        username: "alice",
        password: "secret",
      });
      const response = await tcpExchange(18886, packet);
      expect(response.toString()).toBe("alice");
    } finally {
      await stopNginz(proc);
    }
  });

  test("runtime malformed CONNECT leaves preread variable not found", async () => {
    const proc = await startNginz(CONFIG, "runtime-preread-malformed", 18886);
    try {
      const response = await tcpExchange(18886, Buffer.from([0x30, 0x00]));
      expect(response.toString()).toBe("");
    } finally {
      await stopNginz(proc);
    }
  });

  test("runtime preread waits for a split MQTT CONNECT packet", async () => {
    const proc = await startNginz(CONFIG, "runtime-preread-split-connect", 18886);
    try {
      const packet = buildMqttConnect({
        clientId: "split-preread",
        username: "frank",
        password: "secret",
      });
      const response = await tcpExchangeChunks(18886, [
        packet.subarray(0, 8),
        packet.subarray(8),
      ]);
      expect(response.toString()).toBe("frank");
    } finally {
      await stopNginz(proc);
    }
  });

  test("runtime TLS passthrough bytes are not parsed as MQTT", async () => {
    const proc = await startNginz(CONFIG, "runtime-tls-passthrough", 18886);
    try {
      const tlsClientHelloPrefix = Buffer.from([
        0x16, 0x03, 0x01, 0x00, 0x2e, 0x01, 0x00, 0x00,
        0x2a, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00,
      ]);
      const response = await tcpExchange(18886, tlsClientHelloPrefix);
      expect(response.toString()).toBe("");
    } finally {
      await stopNginz(proc);
    }
  });

  test("runtime hash routing is stable for the same MQTT clientid", async () => {
    const broker1 = createMqttMock(18884).start();
    const broker2 = createMqttMock(18885).start();
    const proc = await startNginz(CONFIG, "runtime-hash-routing", 18883);

    try {
      for (let i = 0; i < 4; i++) {
        const response = await tcpExchange(18883, buildMqttConnect({
          clientId: "sticky-client",
          username: `user-${i}`,
        }));
        expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      }

      const total = broker1.connects.length + broker2.connects.length;
      expect(total).toBe(4);
      expect([broker1.connects.length, broker2.connects.length].sort()).toEqual([0, 4]);

      const target = broker1.connects.length > 0 ? broker1 : broker2;
      expect(target.connects.every((connect) => connect.clientId.startsWith("sticky-client:"))).toBe(true);
      expect(target.connects.every((connect) => connect.username.endsWith("@edge-a"))).toBe(true);
      expect(target.connects.every((connect) => connect.password === "broker-local-secret")).toBe(true);
    } finally {
      await stopNginz(proc);
      broker1.stop();
      broker2.stop();
    }
  });

  test("runtime MQTT 5 CONNECT with properties is proxied and rewritten", async () => {
    const broker1 = createMqttMock(18884).start();
    const broker2 = createMqttMock(18885).start();
    const proc = await startNginz(CONFIG, "runtime-mqtt5-properties", 18883);

    try {
      const response = await tcpExchange(18883, buildMqttConnect({
        version: 5,
        clientId: "mqtt5-client",
        username: "grace",
        connectProperties: Buffer.from([0x21, 0x00, 0x2a]),
      }));

      expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      const connects = [...broker1.connects, ...broker2.connects];
      expect(connects.length).toBe(1);
      expect(connects[0].version).toBe(5);
      expect(connects[0].clientId.startsWith("mqtt5-client:")).toBe(true);
      expect(connects[0].username).toBe("grace@edge-a");
      expect(connects[0].password).toBe("broker-local-secret");
      expect(connects[0].raw.includes(Buffer.from([0x21, 0x00, 0x2a]))).toBe(true);
    } finally {
      await stopNginz(proc);
      broker1.stop();
      broker2.stop();
    }
  });

  test("runtime TLS-terminated MQTT CONNECT is parsed and rewritten", async () => {
    const broker = createMqttMock(18884).start();
    const proc = await startNginz(TLS_CONFIG, "runtime-tls-mqtt", 18893);

    try {
      const response = await tlsExchange(18893, buildMqttConnect({
        clientId: "tls-client",
        username: "heidi",
      }));

      expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      expect(broker.connects.length).toBe(1);
      expect(broker.connects[0].clientId).toBe("tls-client:tls");
      expect(broker.connects[0].username).toBe("heidi@tls-edge");
      expect(broker.connects[0].password).toBe("tls-secret");
    } finally {
      await stopNginz(proc);
      broker.stop();
    }
  });

  test("runtime rewrite buffers split MQTT CONNECT packets", async () => {
    const broker1 = createMqttMock(18884).start();
    const broker2 = createMqttMock(18885).start();
    const proc = await startNginz(CONFIG, "runtime-split-connect", 18883);

    try {
      const packet = buildMqttConnect({
        clientId: "split-client",
        username: "carol",
      });
      const response = await tcpExchangeChunks(18883, [
        packet.subarray(0, 7),
        packet.subarray(7),
      ]);

      expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      const connects = [...broker1.connects, ...broker2.connects];
      expect(connects.length).toBe(1);
      expect(connects[0].clientId.startsWith("split-client:")).toBe(true);
      expect(connects[0].username).toBe("carol@edge-a");
      expect(connects[0].password).toBe("broker-local-secret");
    } finally {
      await stopNginz(proc);
      broker1.stop();
      broker2.stop();
    }
  });

  test("runtime rewrite removes username and password fields", async () => {
    const broker = createMqttMock(18884).start();
    const proc = await startNginz(REWRITE_MATRIX_CONFIG, "runtime-rewrite-remove-auth", 18889);

    try {
      const response = await tcpExchange(18889, buildMqttConnect({
        clientId: "remove-auth-client",
        username: "dave",
        password: "old-secret",
      }));

      expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      expect(broker.connects.length).toBe(1);
      expect(broker.connects[0].clientId).toBe("remove-auth-client");
      expect(broker.connects[0].username).toBe(null);
      expect(broker.connects[0].password).toBe(null);
      expect((broker.connects[0].flags & 0xc0)).toBe(0);
    } finally {
      await stopNginz(proc);
      broker.stop();
    }
  });

  test("runtime rewrite adds password with empty username when username is absent", async () => {
    const broker = createMqttMock(18884).start();
    const proc = await startNginz(REWRITE_MATRIX_CONFIG, "runtime-rewrite-add-password", 18890);

    try {
      const response = await tcpExchange(18890, buildMqttConnect({
        clientId: "add-password-client",
      }));

      expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      expect(broker.connects.length).toBe(1);
      expect(broker.connects[0].clientId).toBe("add-password-client");
      expect(broker.connects[0].username).toBe("");
      expect(broker.connects[0].password).toBe("added-secret");
      expect((broker.connects[0].flags & 0xc0)).toBe(0xc0);
    } finally {
      await stopNginz(proc);
      broker.stop();
    }
  });

  test("runtime rewrite adds username when username is absent", async () => {
    const broker = createMqttMock(18884).start();
    const proc = await startNginz(REWRITE_MATRIX_CONFIG, "runtime-rewrite-add-username", 18891);

    try {
      const response = await tcpExchange(18891, buildMqttConnect({
        clientId: "add-username-client",
      }));

      expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      expect(broker.connects.length).toBe(1);
      expect(broker.connects[0].clientId).toBe("add-username-client");
      expect(broker.connects[0].username).toBe("added-user");
      expect(broker.connects[0].password).toBe(null);
      expect((broker.connects[0].flags & 0xc0)).toBe(0x80);
    } finally {
      await stopNginz(proc);
      broker.stop();
    }
  });

  test("runtime rewrite replaces password while preserving username", async () => {
    const broker = createMqttMock(18884).start();
    const proc = await startNginz(REWRITE_MATRIX_CONFIG, "runtime-rewrite-replace-password", 18892);

    try {
      const response = await tcpExchange(18892, buildMqttConnect({
        clientId: "replace-password-client",
        username: "frank",
        password: "old-secret",
      }));

      expect([...response]).toEqual([0x20, 0x02, 0x00, 0x00]);
      expect(broker.connects.length).toBe(1);
      expect(broker.connects[0].clientId).toBe("replace-password-client");
      expect(broker.connects[0].username).toBe("frank");
      expect(broker.connects[0].password).toBe("new-secret");
      expect((broker.connects[0].flags & 0xc0)).toBe(0xc0);
    } finally {
      await stopNginz(proc);
      broker.stop();
    }
  });

  test("runtime malformed CONNECT fails closed when rewrite is enabled", async () => {
    const broker1 = createMqttMock(18884).start();
    const broker2 = createMqttMock(18885).start();
    const proc = await startNginz(CONFIG, "runtime-rewrite-malformed", 18883);

    try {
      const response = await tcpExchange(18883, Buffer.from([0x30, 0x00]));
      expect([...response]).toEqual([]);
      expect(broker1.connects.length + broker2.connects.length).toBe(0);
    } finally {
      await stopNginz(proc);
      broker1.stop();
      broker2.stop();
    }

    const errorLog = readFileSync(join(process.cwd(), "tests", MODULE, "runtime-rewrite-malformed", "logs", "error.log"), "utf8");
    expect(errorLog).toContain("mqtt rewrite malformed CONNECT");
  });
});
