## GraphQL Gateway Module

GraphQL-aware access handler with query validation, depth limiting, and introspection control.

### Status

**Implemented** - All Phase 1 features complete with 26 passing tests

### Features

- [x] **Query Depth Limiting** - Prevent deeply nested query attacks (DoS protection)
- [x] **Introspection Control** - Block `__schema` and `__type` queries in production
- [x] **Lightweight Query Parsing** - Tokenizer-based parsing without full AST
- [x] **JSON Error Responses** - GraphQL-compliant error format
- [x] **Comment Handling** - Properly skips `#` comments
- [x] **String Handling** - Correctly handles quoted strings

### Directives

| Directive | Syntax | Default | Context | Description |
|-----------|--------|---------|---------|-------------|
| `graphql` | `on\|off` | `off` | location | Enable GraphQL validation |
| `graphql_max_depth` | `<number>` | `10` | location | Max query nesting depth |
| `graphql_introspection` | `on\|off` | `on` | location | Allow introspection queries |

### Usage

```nginx
location /graphql {
    graphql on;
    graphql_max_depth 5;
    graphql_introspection off;

    proxy_pass http://127.0.0.1:4000;
}
```

### How It Works

1. Handler runs in ACCESS phase (before content)
2. Only validates POST requests with JSON body
3. Extracts `query` field from JSON body
4. Parses GraphQL query with lightweight tokenizer:
   - Tracks brace depth `{` `}` to measure nesting
   - Detects `__schema` and `__type` for introspection
   - Handles strings and comments correctly
5. Returns 400 with JSON error if validation fails
6. Returns `NGX_OK` to pass request to backend

### Error Responses

Depth exceeded:
```json
{"errors":[{"message":"Query depth 12 exceeds maximum allowed 5"}]}
```

Introspection blocked:
```json
{"errors":[{"message":"Introspection queries are disabled"}]}
```

Invalid JSON:
```json
{"errors":[{"message":"Invalid JSON body"}]}
```

### Architecture

```
Client Request (POST /graphql)
    ↓
[ACCESS PHASE] graphql_handler
    ↓
Read request body (JSON)
    ↓
Extract "query" field (cJSON)
    ↓
Parse GraphQL query (tokenizer)
    ↓
Check depth limit
    ↓
Check introspection blocked
    ↓
NGX_OK (pass to proxy_pass) or 400 Bad Request
```

### Test Coverage

- Valid query under depth limit → passes through
- Query exceeds depth limit → 400 + error JSON
- Introspection query when disabled → 400 + error JSON
- Introspection query when enabled → passes through
- Invalid JSON body → 400
- GET request → passes through (no validation)
- Deeply nested queries → depth counted correctly
- Query with comments → comments ignored
- Multiple selection sets → depth tracked correctly
- Fragment introspection (`__typename`) → detected
- `graphql_body_max_size` overflow → 413; temp-file request bodies → explicit rejection

### Body limit

`graphql_body_max_size <size>;` is a location directive with a `1m` default.
The module rejects declared or accumulated larger bodies with 413 and rejects
file-backed bodies rather than copying them into request-pool memory.

### Phase 2: Future Enhancements

- [ ] Query complexity scoring (field weights)
- [ ] Persisted queries (query hash lookup)
- [ ] Response caching
- [ ] Field-level authorization
- [ ] Rate limiting per operation

### References

- [GraphQL Specification](https://spec.graphql.org/)
- [GraphQL Query Syntax](https://graphql.org/learn/queries/)
- [Why Disable Introspection](https://www.apollographql.com/blog/graphql/security/why-you-should-disable-graphql-introspection-in-production/)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/graphql/`.
- [x] Bun integration coverage now verifies introspection keywords inside quoted strings are ignored, malformed non-string `query` fields are rejected, and unmatched closing braces are rejected.
- [x] Gap fixed in this audit pass: the lightweight parser now rejects unmatched closing braces instead of silently accepting malformed queries whose final depth returns to zero.
- [x] Block strings and regular-string escape parity are tokenized without counting embedded braces or introspection text.
- [x] Fragment spreads and inline fragments fail closed because the bounded depth heuristic does not expand fragment selection sets.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 HEURISTIC FAIL-CLOSED.** This remains a bounded depth/introspection heuristic rather than a complete GraphQL parser. It handles block strings and escape parity, rejects fragment syntax it cannot safely expand, enforces `graphql_body_max_size` (1 MiB default), and rejects temp-file request bodies explicitly. A real GraphQL parser and semantic complexity model remain feature work rather than a hidden security guarantee.
