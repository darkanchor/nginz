import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz, stopNginz, cleanupRuntime, TEST_URL,
  createPostgresMock, MOCK_PORTS,
} from "../harness.js";

const MODULE = "njs";
let pgMock;

describe("ssi and mirror as pgrest subrequest callers", () => {
  beforeAll(async () => {
    pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);
    pgMock.setQueryHandler(/users/i, (query) => {
      if (/SELECT.*count\(\*\)/i.test(query)) return { columns: ["count"], rows: [["3"]] };
      return {
        columns: ["id", "name"],
        rows: [["1", "Alice"], ["2", "Bob"], ["3", "Carol"]],
      };
    });
    pgMock.setQueryHandler(/pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i, () => ({
      columns: ["dummy"], rows: [],
    }));
    pgMock.setQueryHandler(/^SET\s|^RESET\s/i, () => ({ columns: [], rows: [] }));

    await startNginz("tests/njs/ssi-pgrest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    pgMock?.stop();
  });

  test("SSI include of pgrest returns user JSON", async () => {
    const res = await fetch(`${TEST_URL}/ssi/users`);
    expect(res.status).toBe(200);
    const body = await res.text();
    // SSI replaces the include directive with the subrequest body
    expect(body).toContain("Alice");
  });

  test("SSI pgrest subrequest survives multiple requests", async () => {
    for (let i = 0; i < 3; i++) {
      const res = await fetch(`${TEST_URL}/ssi/users`);
      expect(res.status).toBe(200);
      const body = await res.text();
      expect(body).toContain("Alice");
    }
  });

  test("mirror pgrest subrequest does not crash worker", async () => {
    // Mirror fires pgrest as a side-effect subrequest; main response comes from echozn
    const res = await fetch(`${TEST_URL}/mirror/users`);
    expect(res.status).toBe(200);
    const body = await res.text();
    expect(body).toContain("mirror");
  });

  test("mirror pgrest survives multiple requests", async () => {
    for (let i = 0; i < 3; i++) {
      const res = await fetch(`${TEST_URL}/mirror/users`);
      expect(res.status).toBe(200);
    }
  });
});
