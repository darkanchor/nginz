import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz, stopNginz, cleanupRuntime, TEST_URL,
  createPostgresMock, MOCK_PORTS,
} from "../harness.js";

const MODULE = "njs";
let pgMock;

describe("ssi raw response inspect", () => {
  beforeAll(async () => {
    pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);
    pgMock.setQueryHandler(/users/i, (query) => {
      if (/SELECT.*count/i.test(query)) return { columns: ["count"], rows: [["3"]] };
      return { columns: ["id", "name"], rows: [["1", "Alice"], ["2", "Bob"], ["3", "Carol"]] };
    });
    pgMock.setQueryHandler(/pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i, () => ({ columns: ["dummy"], rows: [] }));
    pgMock.setQueryHandler(/^SET\s|^RESET\s/i, () => ({ columns: [], rows: [] }));
    await startNginz("tests/njs/ssi-pgrest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    pgMock?.stop();
  });

  for (let i = 1; i <= 3; i++) {
    test(`SSI request ${i}`, async () => {
      const res = await fetch(`${TEST_URL}/ssi/users`);
      const headers = Object.fromEntries(res.headers.entries());
      const body = await res.text();
      console.log(`Request ${i}: status=${res.status} body=${JSON.stringify(body)} headers=${JSON.stringify(headers)}`);
      expect(res.status).toBe(200);
    });
  }
});
