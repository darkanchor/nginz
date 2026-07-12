## Transform Module

JSON response transformation using JSON path extraction.

### Status

**Implemented** - Basic functionality complete

### Features

- **JSON Path Extraction**: Extract nested values from JSON responses
- **Path Syntax**: Supports `$.data.items`, `$.items.0` notation
- **Passthrough**: Non-JSON responses pass through unchanged
- **Graceful Fallback**: Returns original response if path not found

### Directives

#### transform_response

*syntax:* `transform_response <json_path>;`
*context:* `location`

Extract and return only the specified JSON path from upstream responses.

#### transform_response_max_size

*syntax:* `transform_response_max_size <size>;`
*default:* `1m`
*context:* `location`

Sets the hard upper bound for a response transformed in memory. JSON responses
with an indeterminate length or a declared length above the limit are rejected
with `502 Bad Gateway`; they are never buffered without a provable bound.

### Usage

```nginx
http {
    server {
        listen 8080;

        # Extract nested data
        location /api/users {
            proxy_pass http://backend/users;
            transform_response $.data;
        }

        # Extract specific field
        location /api/count {
            proxy_pass http://backend/stats;
            transform_response $.data.total;
        }

        # Extract array element
        location /api/first {
            proxy_pass http://backend/items;
            transform_response $.items.0;
        }
    }
}
```

### Examples

**Original Response:**
```json
{
  "status": "ok",
  "data": {
    "users": [
      {"id": 1, "name": "Alice"},
      {"id": 2, "name": "Bob"}
    ],
    "total": 2
  }
}
```

**With `transform_response $.data`:**
```json
{
  "users": [
    {"id": 1, "name": "Alice"},
    {"id": 2, "name": "Bob"}
  ],
  "total": 2
}
```

**With `transform_response $.data.users`:**
```json
[
  {"id": 1, "name": "Alice"},
  {"id": 2, "name": "Bob"}
]
```

**With `transform_response $.data.total`:**
```
2
```

### Path Syntax

| Pattern | Description |
|---------|-------------|
| `$.foo` | Root-level field |
| `$.foo.bar` | Nested field |
| `$.items.0` | Array index (0-based) |
| `$.data.items.0.name` | Deeply nested with array |

### Behavior

- **Non-JSON**: Responses without `application/json` content-type pass through unchanged
- **Invalid Path**: If path doesn't exist, original response is returned
- **Parse Error**: If JSON parsing fails, original response is returned
- **Media Type**: Only an exact, case-insensitive `application/json` media type is transformed; parameters such as `charset` are allowed
- **Buffer Bound**: Responses require a known length no greater than `transform_response_max_size`

### Limitations

Current implementation has these limitations:

- **Simple Paths Only**: No array filters or complex JSONPath expressions
- **Bounded Memory Buffering**: The full response is buffered up to `transform_response_max_size`
- **No Request Transform**: Only transforms responses, not requests

### Future Enhancements

- **Request Transform**: Transform request bodies before proxying
- **JSONPath Filters**: Support `$.items[?(@.active)]` syntax
- **XML Support**: XML-to-JSON transformation
- **Template Transform**: Jinja-style response templates
- **Multiple Extractions**: Extract multiple paths into new structure

### References

- [JSONPath Specification](https://goessner.net/articles/JsonPath/)
- [jq Manual](https://stedolan.github.io/jq/manual/)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/transform/`.
- [x] Bun integration coverage now verifies `application/json` content types with charset parameters, scalar string extraction, invalid JSON passthrough, missing-path passthrough, and non-JSON passthrough.
- [x] Gap fixed in this audit pass: string-scalar extraction now returns the full JSON string value instead of truncating to a single quote character.
- [x] Response buffering is capped by `transform_response_max_size` (default 1 MiB), with exact-limit and one-byte-over regressions.
- [x] Buffered input chains are consumed, file-backed buffers are supported, flush intent is retained, and JSON media-type matching is exact and case-insensitive.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 BUFFERING FIXED; STREAMING FEATURE DEFERRED.** Full-response transformation remains explicitly opt-in and memory-backed, but it now requires a known response length within a configurable 1 MiB default bound. Oversized or indeterminate JSON responses fail with 502 before their bodies are buffered. The filter consumes memory/file input buffers, preserves flush intent on its final output, and matches `application/json` exactly and case-insensitively. Streaming JSONPath evaluation remains a feature gap rather than a robustness prerequisite.
