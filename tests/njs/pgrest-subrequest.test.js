import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
  createPostgresMock,
  MOCK_PORTS,
  teardownModule,
  prepareMockPorts,
  testFetch,
} from "../harness.js";


const MODULE = "njs";

function setupPgMock() {
  const pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);

  // Catch-all: any SELECT involving "users" returns 3 rows
  pgMock.setQueryHandler(/users/i, (query) => {
    if (/SELECT.*count\(\*\)/i.test(query)) {
      return { columns: ["count"], rows: [["3"]] };
    }
    // All other user queries return JSON-safe data
    return {
      columns: ["id", "name", "email", "status"],
      rows: [
        ["1", "Alice", "alice@test.com", "active"],
        ["2", "Bob", "bob@test.com", "active"],
        ["3", "Carol", "carol@test.com", "inactive"],
      ],
    };
  });

  // INSERT returns success
  pgMock.setQueryHandler(/INSERT INTO "public"."users"/i, () => ({
    columns: [],
    rows: [],
  }));

  // Handle introspection queries (pg_constraint, pg_class, etc.) with empty results
  pgMock.setQueryHandler(/pg_constraint|pg_class|pg_attribute|pg_namespace|pg_type|information_schema/i, () => ({
    columns: ["dummy"],
    rows: [],
  }));

  pgMock.setQueryHandler(/add_them/i, () => ({
    columns: ["add_them"],
    rows: [["3"]],
  }));

  return pgMock;
}

// Split into separate nginx lifecycles. A single long chain that mixes
// FILTER + CREATE + RPC + PATCH + DELETE has been observed to hang the
// next njs→pgrest subrequest (client sees ECONNRESET / timeout; mock never
// receives the query). Isolating read/RPC from writes keeps each suite
// short and avoids that sequence.
describe("njs pgrest subrequest reads and rpc", () => {
  let pgMock;

  beforeAll(async () => {
    await prepareMockPorts(MOCK_PORTS.POSTGRES);
    pgMock = setupPgMock();
    await startNginz("tests/njs/pgrest-subrequest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await teardownModule(MODULE, [pgMock], [MOCK_PORTS.POSTGRES]);
  });

  test("subrequest GET /api/users returns array", async () => {
    const res = await testFetch(`/njs/pgrest/users`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body.length).toBe(3);
    expect(body[0]).toHaveProperty("id");
    expect(body[0]).toHaveProperty("name");
  });

  test("subrequest GET /api/users with id filter and select", async () => {
    const res = await testFetch(`/njs/pgrest/users-filtered?id=1&select=id,name`);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(Array.isArray(body)).toBe(true);
    expect(body[0]).toHaveProperty("id");
    expect(body[0]).toHaveProperty("name");
  });

  test("subrequest RPC calls a function", async () => {
    const res = await testFetch(`/njs/pgrest/rpc?fn=add_them&a=1&b=2`, { method: "POST" });
    expect(res.status === 200 || res.status === 201).toBe(true);
    const body = await res.json();
    // RPC result could be scalar or object
    expect(body).toBeTruthy();
  });
});

describe("njs pgrest subrequest writes", () => {
  let pgMock;

  beforeAll(async () => {
    await prepareMockPorts(MOCK_PORTS.POSTGRES);
    pgMock = setupPgMock();
    await startNginz("tests/njs/pgrest-subrequest.conf", MODULE);
  }, 30000);

  afterAll(async () => {
    await teardownModule(MODULE, [pgMock], [MOCK_PORTS.POSTGRES]);
  });

  test("subrequest POST /api/users creates a user", async () => {
    const res = await testFetch(`/njs/pgrest/users-create`, {
      method: "POST",
      body: JSON.stringify({ name: "Dave", email: "dave@test.com" }),
    });
    // pgrest returns 201 on successful POST
    expect(res.status === 201 || res.status === 200).toBe(true);
  });

  test("subrequest PATCH /api/users updates a user", async () => {
    const res = await testFetch(`/njs/pgrest/users-update?id=1`, {
      method: "POST",
      body: JSON.stringify({ name: "Alice-Updated" }),
    });
    expect(res.status === 200 || res.status === 204).toBe(true);
  });

  test("subrequest DELETE /api/users removes a user", async () => {
    const res = await testFetch(`/njs/pgrest/users-delete?id=3`, {
      method: "POST",
    });
    expect(res.status === 200 || res.status === 204).toBe(true);
  });
});
