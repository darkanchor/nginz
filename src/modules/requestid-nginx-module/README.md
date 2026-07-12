## Request ID Module

Generate and propagate unique request IDs for distributed tracing.

### Status

**Implemented** - Core functionality complete

### Features

- **UUID4 Generation**: Cryptographically random UUID v4 identifiers
- **ID Propagation**: Accept incoming X-Request-ID header or generate new one
- **Custom Header Name**: Configurable header name (default: X-Request-ID)
- **Response Header**: Add ID to response headers (enabled by default)
- **Case-Insensitive Matching**: Incoming headers matched case-insensitively

### Directives

#### request_id_header

*syntax:* `request_id_header <name>;`
*default:* `X-Request-ID`
*context:* `location`

Enable request ID generation/propagation and set the header name to use (both incoming and outgoing). When enabled, the module will:
1. Check for an incoming request ID header
2. If found, propagate it to the response
3. If not found, generate a new UUID4

#### request_id_response

*syntax:* `request_id_response on|off;`
*default:* `on`
*context:* `location`

Enable request ID generation/propagation and control whether to add the request ID to response headers.

### Variables

#### $ngz_request_id

The request ID for the current request. Returns either:
- The incoming `X-Request-ID` header value (if provided by client)
- A newly generated UUID4 (if no incoming header)

Use this variable for logging or upstream propagation.

### Usage

```nginx
http {
    # Log format with request ID
    log_format traced '$remote_addr - $ngz_request_id - $status "$request"';

    server {
        access_log /var/log/nginx/access.log traced;

        # Basic usage - generates UUID4 and adds X-Request-ID to response
        location /api {
            request_id_response on;
            proxy_pass http://backend;
        }

        # Forward request ID to upstream
        location /backend {
            request_id_response on;
            proxy_set_header X-Request-ID $ngz_request_id;
            proxy_pass http://backend;
        }

        # Custom header name
        location /traced {
            request_id_header X-Correlation-ID;
            proxy_pass http://backend;
        }

        # Disable response header (internal tracking only)
        location /internal {
            request_id_response off;
            proxy_pass http://backend;
        }

        # Return request ID in response body
        location /debug {
            request_id_response on;
            return 200 "Your request ID: $ngz_request_id\n";
        }
    }
}
```

### How It Works

1. **Incoming Request**: If the client sends an `X-Request-ID` header, the module preserves and propagates it
2. **No Incoming ID**: The module generates a new UUID4 (e.g., `550e8400-e29b-41d4-a716-446655440000`)
3. **Response**: The ID is added to response headers (unless `request_id_response off`)

This enables end-to-end request tracing across your infrastructure. The same ID can be logged by nginx and forwarded to upstream services.

### UUID4 Format

Generated IDs follow RFC 4122 UUID version 4:
- 36 characters: `xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`
- Version nibble (position 14): always `4`
- Variant nibble (position 19): `8`, `9`, `a`, or `b`
- Uses cryptographically secure random bytes (Zig's `std.crypto.random`)

### Future Enhancements

- **Additional Formats**: UUID v7, ULID, Snowflake, custom formats
- **Validation**: Validate incoming ID format to prevent log injection

### References

- [OpenTelemetry Trace Context](https://www.w3.org/TR/trace-context/)
- [RFC 4122 - UUID](https://tools.ietf.org/html/rfc4122)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/requestid/`.
- [x] Bun integration coverage now verifies custom header names, upstream proxy forwarding via `$ngz_request_id`, case-insensitive incoming header matching, and internal-only tracking with `request_id_response off`.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 FIXED.** UUID generation now propagates entropy failure instead of formatting uninitialized bytes. Incoming IDs are accepted only when 1–128 bytes of visible non-space ASCII; invalid values are discarded and replaced with a checked UUID. Unit bounds/control-character coverage and the focused request-ID suite are green, including oversized/whitespace regeneration.
