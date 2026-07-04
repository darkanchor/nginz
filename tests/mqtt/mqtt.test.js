import { describe, test, expect } from "bun:test";
import { spawnSync } from "bun";
import { existsSync, mkdirSync, readFileSync, rmSync } from "fs";
import { join } from "path";

const MODULE = "mqtt";
const CONFIG = `tests/${MODULE}/nginx.conf`;
const INVALID_FIELD_CONFIG = `tests/${MODULE}/nginx-invalid-field.conf`;
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
});
