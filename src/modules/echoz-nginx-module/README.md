## Echoz Module

Content handler and filter module for outputting text, variables, and request bodies. A Zig implementation inspired by the [echo-nginx-module](https://github.com/openresty/echo-nginx-module).

### Status

**Implemented** - Core directives complete with Bun coverage in `tests/echoz/`

### Features

- [x] **Text Output** - Output literal strings with/without newlines
- [x] **Variable Interpolation** - Expand nginx variables like `$request_method`, `$uri`
- [x] **Request Body Echo** - Output the request body content
- [x] **String Duplication** - Repeat a string N times
- [x] **Internal Redirects** - Redirect to named or regular locations
- [x] **Async Subrequests** - Background fire-and-forget subrequests to other locations
- [x] **Body Filters** - Prepend/append content to responses
- [x] **Response Headers** - Set custom status codes and headers

### Directives

| Directive | Syntax | Context | Description |
|-----------|--------|---------|-------------|
| `echoz` | `<string>...` | location | Output text with trailing newline |
| `echozn` | `<string>...` | location | Output text without newline |
| `echoz_duplicate` | `<count> <string>` | location | Repeat string N times |
| `echoz_flush` | - | location | Flush output buffer |
| `echoz_sleep` | `<seconds>` | location | Pause execution |
| `echoz_request_body` | - | location | Output request body |
| `echoz_read_request_body` | - | location | Read request body into memory |
| `echoz_exec` | `<location>` | location | Internal redirect to location |
| `echoz_location_async` | `<location>` | location | Background header-only subrequest (fire-and-forget) |
| `echoz_before_body` | `<string>` | location | Prepend to response body (filter) |
| `echoz_after_body` | `<string>` | location | Append to response body (filter) |
| `echoz_status` | `<code>` | location | Set response status code |
| `echoz_header` | `<name> <value>` | location | Add response header |

### Usage

Basic text output:
```nginx
location /hello {
    echoz "Hello, World!";
}
# Response: Hello, World!\n
```

Multiple lines:
```nginx
location /multi {
    echoz "line1";
    echoz "line2";
    echoz "line3";
}
# Response: line1\nline2\nline3\n
```

Without newline:
```nginx
location /json {
    echozn '{"status":"ok"}';
}
# Response: {"status":"ok"}
```

Variable interpolation:
```nginx
location /info {
    echoz "Method: $request_method";
    echoz "URI: $uri";
    echoz "Host: $host";
}
```

Echo request body:
```nginx
location /echo {
    echoz_read_request_body;
    echoz "Received: ";
    echoz_request_body;
}
```

String duplication:
```nginx
location /repeat {
    echoz_duplicate 3 "abc";
}
# Response: abcabcabc
```

Internal redirect:
```nginx
location /old {
    echoz_exec @new;
}

location @new {
    echoz "Redirected!";
}
```

Body filters:
```nginx
location /wrapped {
    echoz_before_body "<html><body>";
    echoz_after_body "</body></html>";
    proxy_pass http://backend;
}
```

### Architecture

The module provides two nginx modules in one:

1. **Content Handler Module** (`ngx_http_echoz_module`)
   - Handles `echoz`, `echozn`, `echoz_duplicate`, etc.
   - Runs in CONTENT phase
   - Generates response body

2. **Filter Module** (`ngx_http_echoz_filter_module`)
   - Handles `echoz_before_body`, `echoz_after_body`
   - Runs in output filter chain
   - Modifies responses from other handlers

### Subrequest Semantics

- `echozn` is safe as a subrequest target for `auth_request`, SSI, and mirror.
- `echozn` does not emit a response body for `header_only` subrequests.
- `echoz_location_async` now creates true background subrequests. The child response is discarded and not merged back into the parent response.
- If you want the child body to appear in the parent response, use a foreground subrequest mechanism such as SSI rather than `echoz_location_async`.

### Test Coverage

- `echoz` outputs text with newline
- `echozn` outputs text without newline
- Multiple `echoz` commands output multiple lines
- Variable interpolation works (`$request_method`, `$uri`)
- `echoz_duplicate` repeats strings correctly
- `echoz_exec` redirects to named locations
- `echoz_exec` redirects to regular locations
- `echoz_request_body` echoes POST body
- `echoz_location_async` issues detached background subrequests
- `echozn` behaves correctly as an `auth_request`, SSI, and mirror target

### References

- [echo-nginx-module](https://github.com/openresty/echo-nginx-module) - Original echo module by OpenResty

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/echoz/`.
- [x] Gap recorded: README documents `echoz_status <code>`, but the current command surface and passing coverage use `echoz_status <code> <reason>`.
- [x] Gap recorded: Bun guardrails for `echoz_flush`, `echoz_status`, `echoz_header`, and body-filter wrapping were added in this audit pass because those observable behaviors were implemented but previously unasserted.
- [x] Gap closed: README now documents true background semantics for `echoz_location_async` and bodyless `header_only` subrequest behavior for `echozn`.
