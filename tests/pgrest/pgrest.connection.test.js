import { afterAll, describe, expect, test } from "bun:test";
import { cleanupRuntime, startNginz, stopNginz, TEST_URL, createPostgresMock } from "../harness.js";

const MODULE = "pgrest";

let resetPgMock;
let dnsErrorMock;

async function runConnectionCase(configName, path = "/api/users") {
  await startNginz(`tests/${MODULE}/${configName}`, MODULE);
  try {
    return await fetch(`${TEST_URL}${path}`);
  } finally {
    await stopNginz();
    cleanupRuntime(MODULE);
  }
}

describe("pgrest connection error handling", () => {
  resetPgMock = createPostgresMock(15434);
  resetPgMock.setQueryHandler(/^SELECT \* FROM users$/, () => ({ close: true }));

  // A separate mock on port 15437 that sends a startup error simulating DNS failure.
  // Uses hostaddr=127.0.0.1 (no real DNS) to avoid blocking the nginx worker.
  dnsErrorMock = createPostgresMock(15437);
  dnsErrorMock.connectionError = "could not translate host name \"does-not-resolve\" to address: Name or service not known";

  afterAll(() => {
    if (resetPgMock) resetPgMock.stop();
    if (dnsErrorMock) dnsErrorMock.stop();
    cleanupRuntime(MODULE);
  });

  test("unreachable PostgreSQL returns 503", async () => {
    const res = await runConnectionCase("nginx.connection.unreachable.conf");
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ message: "PostgreSQL is unreachable" });
  });

  test("DNS resolution failure returns 503", async () => {
    const res = await runConnectionCase("nginx.connection.dns.conf");
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ message: "PostgreSQL DNS resolution failed" });
  });

  test("connection timeout returns 504", async () => {
    const res = await runConnectionCase("nginx.connection.timeout.conf");
    expect(res.status).toBe(504);
    expect(await res.json()).toEqual({ message: "PostgreSQL connection timed out" });
  }, 15000);

  test("connection reset mid-query returns 503", async () => {
    const res = await runConnectionCase("nginx.connection.reset.conf");
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ message: "PostgreSQL connection reset" });
  }, 15000);
});
