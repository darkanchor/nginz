## Cache Tags Module

Tag-based cache invalidation for nginx responses.

### Status

**Implemented** - Basic functionality complete with shared-memory tag storage

### Features

- **Tag Collection**: Captures `Cache-Tag` header from upstream responses
- **Shared Tag Storage**: Stores URL-to-tags mappings in nginx shared memory across workers
- **Purge Endpoint**: REST API for invalidating cache entries by tag
- **Pattern Matching**: Purge by exact tag

### Directives

#### cache_tags

 *syntax:* `cache_tags;`
*context:* `location`

Enable cache tag collection for responses in this location. The module captures the `Cache-Tag` header from upstream responses.

#### cache_tags_purge

*syntax:* `cache_tags_purge;`
*context:* `location`

Enable the purge endpoint at this location. Accepts GET or DELETE requests with an optional `tag` query parameter.

### Usage

```nginx
http {
    server {
        listen 8080;

        # Application with cache tags
        location /api {
            proxy_pass http://backend;
            cache_tags;
        }

        # Purge endpoint
        location /cache/purge {
            cache_tags_purge;

            # Restrict access
            allow 127.0.0.1;
            deny all;
        }
    }
}
```

### Upstream Response

Your backend should include the `Cache-Tag` header:

```http
HTTP/1.1 200 OK
Content-Type: application/json
Cache-Tag: user-123, product-456, category-electronics
```

### Purge API

```bash
# Purge by exact tag
curl -X DELETE "http://localhost:8080/cache/purge?tag=user-123"

# Response
{"purged": 5, "tag": "user-123"}
```

### Nginx Variables

These variables expose the most recent purge outcome for the current purge request only.

| Variable | Values | Scripted consumers |
|---|---|---|
| `$cache_tags_last_purged` | decimal / not found | `metrics`, `workflow` — observability and purge follow-up behavior |
| `$cache_tags_last_tag` | string / not found | `metrics` — structured logging and audit trails |
| `$cache_tags_last_error` | `method_not_allowed` / not found | `workflow` — request-shape recovery policy |

- `$cache_tags_last_purged` is set only on tagged purge requests and reflects the number of URIs removed for that tag.
- `$cache_tags_last_tag` is set only on tagged purge requests and reflects the requested tag, even when the purge count is `0`.
- `$cache_tags_last_error` is currently set to `method_not_allowed` when the purge endpoint is called with an unsupported method such as `POST`.
- Plain cache-tag capture requests and tag-listing purge requests leave these variables unset.

### Limitations

Current implementation has these limitations:

- **Memory Only**: Tags are stored in nginx shared memory and are still lost on restart/reload
- **No Wildcards Yet**: Pattern matching limited to exact tags
- **Fixed Capacity**: The current shared-memory store uses fixed tag and URI limits

### Future Enhancements

- **Wildcard Purge**: Support patterns like `user-*` or `product-*`
- **Bulk Purge**: Purge multiple tags in one request
- **Tag TTL**: Automatic expiration of stale tags
- **Persistence**: Optional disk-backed storage
- **Richer purge error surface**: expose storage/validation failures beyond the current `method_not_allowed` signal

### References

- [Fastly Surrogate Keys](https://docs.fastly.com/en/guides/purging-api-cache-with-surrogate-keys)
- [Varnish Cache Tags](https://varnish-cache.org/docs/trunk/users-guide/purging.html)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/cache-tags/`.
- [x] README now matches the current command surface: `cache_tags;` enables collection and the purge endpoint accepts GET or DELETE.
- [x] Tags are now stored in an nginx shared-memory zone so capture and purge work across multiple workers.
- [x] Bun integration coverage now runs with `worker_processes 2` and verifies cross-worker capture plus purge behavior.
- [x] Variable integration coverage now verifies `$cache_tags_last_purged`, `$cache_tags_last_tag`, and `$cache_tags_last_error` on purge success/miss/error paths.
- [x] No additional documentation gaps were identified in this audit pass.
