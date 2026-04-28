import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { startNginz, stopNginz, cleanupRuntime, TEST_URL, createPostgresMock, MOCK_PORTS } from "../harness.js";

const MODULE = "njs";
let pgMock;

beforeAll(async () => {
  pgMock = createPostgresMock(MOCK_PORTS.POSTGRES);

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

  await startNginz("tests/njs/pgrest-subrequest.conf", MODULE);
}, 30000);

afterAll(async () => {
  await stopNginz();
  cleanupRuntime(MODULE);
  pgMock?.stop();
});

// =========================================================================
// Simple GET via subrequest
// =========================================================================

test("subrequest GET /api/users returns array", async () => {
  const res = await fetch(`${TEST_URL}/njs/pgrest/users`);
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(Array.isArray(body)).toBe(true);
  expect(body.length).toBe(3);
  expect(body[0]).toHaveProperty("id");
  expect(body[0]).toHaveProperty("name");
});

test("subrequest GET /api/users with id filter and select", async () => {
  const res = await fetch(`${TEST_URL}/njs/pgrest/users-filtered?id=1&select=id,name`);
  expect(res.status).toBe(200);
  const body = await res.json();
  expect(Array.isArray(body)).toBe(true);
  expect(body[0]).toHaveProperty("id");
  expect(body[0]).toHaveProperty("name");
});

// =========================================================================
// POST (create) via subrequest
// =========================================================================

test("subrequest POST /api/users creates a user", async () => {
  const res = await fetch(`${TEST_URL}/njs/pgrest/users-create`, {
    method: "POST",
    body: JSON.stringify({ name: "Dave", email: "dave@test.com" }),
  });
  // pgrest returns 201 on successful POST
  expect(res.status === 201 || res.status === 200).toBe(true);
});

// =========================================================================
// PATCH (update) via subrequest
// =========================================================================

test("subrequest PATCH /api/users updates a user", async () => {
  const res = await fetch(`${TEST_URL}/njs/pgrest/users-update?id=1`, {
    method: "POST",
    body: JSON.stringify({ name: "Alice-Updated" }),
  });
  expect(res.status === 200 || res.status === 204).toBe(true);
});

// =========================================================================
// DELETE via subrequest
// =========================================================================

test("subrequest DELETE /api/users removes a user", async () => {
  const res = await fetch(`${TEST_URL}/njs/pgrest/users-delete?id=3`, {
    method: "POST",
  });
  expect(res.status === 200 || res.status === 204).toBe(true);
});

// =========================================================================
// RPC via subrequest
// =========================================================================

test("subrequest RPC calls a function", async () => {
  // Set handler for RPC-style queries
  pgMock.setQueryHandler(/add_them/i, () => ({
    columns: ["add_them"],
    rows: [["3"]],
  }));

  const res = await fetch(`${TEST_URL}/njs/pgrest/rpc?fn=add_them&a=1&b=2`, { method: "POST" });
  expect(res.status === 200 || res.status === 201).toBe(true);
  const body = await res.json();
  // RPC result could be scalar or object
  expect(body).toBeTruthy();
});


