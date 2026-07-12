import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import {
  startNginz,
  stopNginz,
  cleanupRuntime,
  TEST_URL,
} from "../harness.js";

const MODULE = "graphql";

describe("graphql module", () => {
  beforeAll(async () => {
    await startNginz(`tests/${MODULE}/nginx.conf`, MODULE);
  });

  afterAll(async () => {
    await stopNginz();
    cleanupRuntime(MODULE);
  });

  describe("valid queries", () => {
    test("allows simple query under depth limit", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ user { name } }",
        }),
      });
      expect(res.status).toBe(200);
      const body = await res.json();
      expect(body.data.received).toBe(true);
    });

    test("allows query at exact depth limit", async () => {
      // depth limit is 5 on /graphql
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ user { profile { settings { theme { name } } } } }",
        }),
      });
      expect(res.status).toBe(200);
    });

    test("allows query with arguments", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: '{ user(id: "123") { name email } }',
        }),
      });
      expect(res.status).toBe(200);
    });

    test("allows mutation queries", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: 'mutation { updateUser(id: "1", name: "Test") { id } }',
        }),
      });
      expect(res.status).toBe(200);
    });

    test("allows query with variables", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "query GetUser($id: ID!) { user(id: $id) { name } }",
          variables: { id: "123" },
        }),
      });
      expect(res.status).toBe(200);
    });

    test("allows query with operationName", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "query GetUser { user { name } } query GetPosts { posts { title } }",
          operationName: "GetUser",
        }),
      });
      expect(res.status).toBe(200);
    });
  });

  describe("depth limiting", () => {
    test("rejects query exceeding depth limit", async () => {
      // depth limit is 5 on /graphql, this is 6 levels deep
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ user { profile { settings { theme { colors { primary } } } } } }",
        }),
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.errors).toBeDefined();
      expect(body.errors[0].message).toContain("depth");
    });

    test("rejects deeply nested query", async () => {
      const deepQuery = `{
        a {
          b {
            c {
              d {
                e {
                  f {
                    g { name }
                  }
                }
              }
            }
          }
        }
      }`;

      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: deepQuery }),
      });
      expect(res.status).toBe(400);
    });

    test("shallow endpoint rejects depth 3", async () => {
      // /graphql-shallow has max_depth 2
      const res = await fetch(`${TEST_URL}/graphql-shallow`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ user { profile { name } } }",
        }),
      });
      expect(res.status).toBe(400);
    });

    test("shallow endpoint allows depth 2", async () => {
      const res = await fetch(`${TEST_URL}/graphql-shallow`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ user { name } }",
        }),
      });
      expect(res.status).toBe(200);
    });
  });

  describe("introspection control", () => {
    test("blocks __schema query when introspection disabled", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ __schema { types { name } } }",
        }),
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.errors).toBeDefined();
      expect(body.errors[0].message).toContain("Introspection");
    });

    test("blocks __type query when introspection disabled", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: '{ __type(name: "User") { fields { name } } }',
        }),
      });
      expect(res.status).toBe(400);
      const body = await res.json();
      expect(body.errors[0].message).toContain("Introspection");
    });

    test("allows __schema when introspection enabled", async () => {
      const res = await fetch(`${TEST_URL}/graphql-introspection`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ __schema { types { name } } }",
        }),
      });
      expect(res.status).toBe(200);
    });

    test("allows __type when introspection enabled", async () => {
      const res = await fetch(`${TEST_URL}/graphql-introspection`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: '{ __type(name: "User") { fields { name } } }',
        }),
      });
      expect(res.status).toBe(200);
    });

    test("blocks introspection in nested field", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ user { name } __schema { types { name } } }",
        }),
      });
      expect(res.status).toBe(400);
    });

    test("does not treat introspection keywords inside strings as introspection", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: '{ search(term: "__schema __type") { name } }',
        }),
      });
      expect(res.status).toBe(200);
    });
  });

  describe("request handling", () => {
    test("rejects a request body above the configured module limit", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: `{ ${"field ".repeat(128)} }` }),
      });
      expect(res.status).toBe(413);
    });

    test("passes through GET requests without validation", async () => {
      const res = await fetch(`${TEST_URL}/graphql?query={user{name}}`);
      // GET requests should pass through (GraphQL validation is for POST only)
      // The upstream will handle or reject GET as needed
      expect([200, 405]).toContain(res.status);
    });

    test("rejects invalid JSON body", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "not valid json {{{",
      });
      expect(res.status).toBe(400);
    });

    test("rejects missing query field", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          variables: { id: "123" },
        }),
      });
      expect(res.status).toBe(400);
    });

    test("rejects empty query string", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "",
        }),
      });
      expect(res.status).toBe(400);
    });

    test("handles query with comments", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: `
            # This is a comment
            {
              user {
                # Another comment
                name
              }
            }
          `,
        }),
      });
      expect(res.status).toBe(200);
    });

    test("handles query with string literals containing braces", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: '{ user(filter: "{ nested: true }") { name } }',
        }),
      });
      expect(res.status).toBe(200);
    });

    test("handles block strings without counting braces or introspection text", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: '{ search(term: """{ __schema }""") { name } }' }),
      });
      expect(res.status).toBe(200);
    });

    test("rejects fragment syntax that the depth policy cannot safely expand", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ query: "query { user { ...UserFields } } fragment UserFields on User { name }" }),
      });
      expect(res.status).toBe(400);
      expect((await res.json()).errors[0].message).toContain("Fragments are unsupported");
    });

    test("rejects query with extra closing brace", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ user { name } }}",
        }),
      });
      expect(res.status).toBe(400);

      const body = await res.json();
      expect(body.errors[0].message).toMatch(/brace/i);
    });

    test("rejects non-string query field", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: { nested: true },
        }),
      });
      expect(res.status).toBe(400);

      const body = await res.json();
      expect(body.errors[0].message).toContain("Query field must be a string");
    });
  });

  describe("disabled mode", () => {
    test("passes any query when graphql disabled", async () => {
      const res = await fetch(`${TEST_URL}/graphql-disabled`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ a { b { c { d { e { f { g { h { i { j { deep } } } } } } } } } } }",
        }),
      });
      expect(res.status).toBe(200);
    });

    test("passes introspection when graphql disabled", async () => {
      const res = await fetch(`${TEST_URL}/graphql-disabled`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ __schema { types { name } } }",
        }),
      });
      expect(res.status).toBe(200);
    });

    test("passes invalid JSON when graphql disabled", async () => {
      const res = await fetch(`${TEST_URL}/graphql-disabled`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: "not json",
      });
      // Should pass through to upstream (which may return error)
      expect([200, 400, 500]).toContain(res.status);
    });
  });

  describe("error response format", () => {
    test("returns GraphQL-formatted error for depth violation", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ a { b { c { d { e { f { name } } } } } } }",
        }),
      });
      expect(res.status).toBe(400);
      expect(res.headers.get("content-type")).toContain("application/json");

      const body = await res.json();
      expect(body.errors).toBeInstanceOf(Array);
      expect(body.errors.length).toBeGreaterThan(0);
      expect(body.errors[0].message).toBeDefined();
    });

    test("returns GraphQL-formatted error for introspection violation", async () => {
      const res = await fetch(`${TEST_URL}/graphql`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          query: "{ __schema { types { name } } }",
        }),
      });
      expect(res.status).toBe(400);

      const body = await res.json();
      expect(body.errors).toBeInstanceOf(Array);
      expect(body.errors[0].message).toContain("Introspection");
    });
  });
});
