## Hello

A minimal nginx module written in Zig that returns a literal "hello" response when the `hello` directive is specified.

### Directive

#### hello

*syntax:* `hello;`  
*context:* `location`

Enables the hello module handler for the current location. When enabled, any request to this location will receive a response containing the literal string "hello".

### Usage

```nginx
location /hello {
    hello;
}
```

Visiting `/hello` will return a response with status code 200 and body containing "hello".

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/hello/`.
- [x] Bun integration coverage now verifies exact-match locations, nested locations, HEAD requests, POST requests, and neighboring non-hello locations remaining unaffected.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: PASS WITH LOW-RISK CLEANUP.** This module has no shared memory, asynchronous ownership, or cross-module state. Its request-pool allocations and HEAD handling are straightforward. Before treating the example as a reference implementation, set an explicit content type and content length and remove unused imports; these are protocol/maintenance improvements, not current isolation defects.
