## JSON Schema Validation Module

Validates JSON request bodies against inline JSON Schema in the access phase.

### Directives

#### jsonschema

*syntax:* `jsonschema '<json_schema>';`
*context:* `location`

Enable JSON Schema validation with an inline schema. Only validates POST, PUT, and PATCH requests with `Content-Type: application/json`.

### Supported Schema Keywords

- **type**: `string`, `number`, `integer`, `boolean`, `object`, `array`, `null`
- **required**: Array of required field names for objects
- **properties**: Nested schema definitions for object properties
- **minLength** / **maxLength**: String length constraints
- **minimum** / **maximum**: Number value constraints

### Usage

```nginx
http {
    server {
        listen 8888;

        location /api/users {
            jsonschema '{"type":"object","required":["name","email"],"properties":{"name":{"type":"string","minLength":1},"email":{"type":"string"},"age":{"type":"number","minimum":0}}}';
            proxy_pass http://backend;
        }

        location /api/simple {
            jsonschema '{"type":"object"}';
            echozn '{"status":"ok"}';
        }
    }
}
```

### Error Response

On validation failure, returns HTTP 400 with JSON body:

```json
{
  "error": "validation_failed",
  "message": "missing required field"
}
```

Possible error messages:
- `invalid JSON` - Request body is not valid JSON
- `must be a string` / `must be a number` / `must be an object` / etc. - Type mismatch
- `missing required field` - Required field not present
- `string too short` / `string too long` - String length violation
- `number below minimum` / `number above maximum` - Number range violation
- `schema too deep` - Schema exceeds maximum recursion depth (100)

### Behavior

- GET requests and other methods without body pass through without validation
- Requests without `Content-Type: application/json` header pass through without validation
- Empty request bodies pass through without validation
- Validation runs in the access phase before content handlers
- Unsupported or malformed schema keywords reject nginx configuration; they are never silently ignored
- `jsonschema_body_max_size <size>;` is a location directive with a `1m` default; larger and file-backed bodies are rejected

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/jsonschema/`.
- [x] Bun integration coverage now verifies PUT/PATCH validation, JSON content types with parameters, missing content-type passthrough, empty JSON body passthrough, and integer-specific schemas.
- [x] Gap fixed in this audit pass: `type: "integer"` now rejects fractional numeric values instead of being treated the same as `number`.
- [x] Schema configuration now recursively rejects unsupported vocabulary and malformed supported keyword shapes; config tests cover both cases.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 POLICY SEMANTICS FIXED.** Validation remains a deliberately small schema subset, and configuration now recursively rejects every unsupported keyword, unknown type, and malformed supported keyword shape instead of silently weakening policy. `jsonschema_body_max_size` (1 MiB default) bounds copied bodies, temp-file bodies are rejected explicitly, and JSON media types are exact and case-insensitive. Broader JSON Schema vocabulary remains intentionally unsupported.
