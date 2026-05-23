import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz, stopNginz, cleanupRuntime, TEST_URL,
  createRedisMock, createPostgresMock, MOCK_PORTS,
} from "../harness.js";

const MODULE = "njs";
let redisMock;
let pgMock;

describe("njs combo subrequest - failing tests only", () => {
  beforeAll(async () => {
    redisMock = createRedisMock(MOCK_PORTS.REDIS);
    pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);

    redisMock.setValue("_redis/decr/rate-limit", "3");
    redisMock.setValue("_redis/exists/guard-key", "present");

    pgMock.setQueryHandler(/users/i, (query) => {
      if (/SELECT.*count\(\*\)/i.test(query)) return { columns: ["count"], rows: [["3"]] };
      if (/INSERT/i.test(query)) return { columns: [], rows: [] };
      return {
        columns: ["id", "name", "email", "status"],
        rows: [
          ["1", "Alice", "alice@test.com", "active"],
          ["2", "Bob", "bob@test.com", "active"],
          ["3", "Carol", "carol@test.com", "inactive"],
        ],
      };
    });
    pgMock.setQueryHandler(/pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i, () => ({
      columns: ["dummy"], rows: [],
    }));
    pgMock.setQueryHandler(/^SET\s|^RESET\s/i, () => ({ columns: [], rows: [] }));

    await startNginz("tests/njs/combo-subrequest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
    redisMock?.stop();
    pgMock?.stop();
  });

  test("decr rate gate allows request", async () => {
    const r1 = await fetch(`${TEST_URL}/combo/decr-gate?key=rate-limit`, { method: "POST" });
    expect(r1.status).toBe(200);
    const b1 = await r1.json();
    expect(b1.allowed).toBe(true);
    expect(b1.remaining).toBe(2);
    expect(b1.user_count).toBe(3);
  });

  test("exists guard allows write", async () => {
    const res = await fetch(`${TEST_URL}/combo/exists-guard?key=guard-key`, {
      method: "POST",
      body: JSON.stringify({ name: "Guard-User", email: "guard@test.com" }),
    });
    expect(res.status).toBe(200);
  });
});
