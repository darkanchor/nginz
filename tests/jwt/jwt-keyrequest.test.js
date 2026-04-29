import { describe, test, expect, afterEach } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime } from "../harness.js";

const MODULE = "jwt";

describe("JWT — Key Request Directive", () => {
  afterEach(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  test("jwt_key_request fails startup until subrequest support is implemented", async () => {
    await expect(startNginz("tests/jwt/nginx.keyrequest.conf", MODULE)).rejects.toThrow();
  }, 15000);
});
