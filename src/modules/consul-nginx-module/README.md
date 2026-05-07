## Consul Module

Service discovery and KV store integration with HashiCorp Consul.

### Status

**Implemented** - Core functionality complete

### Features

- **Service Discovery**: Fetch healthy service instances from Consul catalog
- **KV Store**: Read values from Consul KV store with Base64 decoding
- **Catalog Listing**: List all registered services
- **Tag Filtering**: Filter services by tag
- **Datacenter Support**: Query specific datacenters
- **ACL Token**: Authentication support for secured Consul clusters
- **JSON Response**: All endpoints return structured JSON responses

### Directives

#### consul_services

*syntax:* `consul_services <address>;`
*context:* `location`

Enable service discovery endpoint. Service name is extracted from URI path.

#### consul_kv

*syntax:* `consul_kv <address>;`
*context:* `location`

Enable KV store endpoint. Key is extracted from URI path.

#### consul_catalog

*syntax:* `consul_catalog <address>;`
*context:* `location`

Enable catalog listing endpoint. Lists all registered service names.

#### consul_service

*syntax:* `consul_service <name>;`
*context:* `location`

Set a fixed service name instead of extracting from URI.

#### consul_key

*syntax:* `consul_key <key>;`
*context:* `location`

Set a fixed KV key instead of extracting from URI.

#### consul_tag

*syntax:* `consul_tag <tag>;`
*context:* `location`

Filter services by tag.

#### consul_dc

*syntax:* `consul_dc <datacenter>;`
*context:* `location`

Query a specific Consul datacenter.

#### consul_token

*syntax:* `consul_token <token>;`
*context:* `location`

Consul ACL token for authentication.

### Usage Examples

#### Service Discovery (dynamic name from URI)

```nginx
location /services/ {
    consul_services 127.0.0.1:8500;
}
```

Request: `GET /services/api-service`

Response:
```json
{
  "services": [
    {
      "id": "api-1",
      "address": "10.0.0.1",
      "port": 8080,
      "tags": ["production", "v2"]
    },
    {
      "id": "api-2",
      "address": "10.0.0.2",
      "port": 8080,
      "tags": ["production", "v2"]
    }
  ]
}
```

#### Service Discovery (fixed name)

```nginx
location /api {
    consul_services 127.0.0.1:8500;
    consul_service api-service;
    consul_tag production;
}
```

#### KV Store Lookup (dynamic key from URI)

```nginx
location /kv/ {
    consul_kv 127.0.0.1:8500;
}
```

Request: `GET /kv/config/app/timeout`

Response:
```json
{
  "value": "30"
}
```

#### KV Store (fixed key)

```nginx
location /config/timeout {
    consul_kv 127.0.0.1:8500;
    consul_key config/app/timeout;
}
```

#### Catalog Listing

```nginx
location /catalog {
    consul_catalog 127.0.0.1:8500;
}
```

Response:
```json
{
  "services": ["api-service", "cache-service", "db-service"]
}
```

#### Full Configuration Example

```nginx
http {
    server {
        listen 8080;

        # Service discovery with dynamic service name
        location /services/ {
            consul_services 127.0.0.1:8500;
        }

        # Service discovery with fixed name and tag filter
        location /api-service {
            consul_services 127.0.0.1:8500;
            consul_service api-service;
            consul_tag production;
            consul_dc us-east-1;
        }

        # KV store with dynamic key
        location /kv/ {
            consul_kv 127.0.0.1:8500;
        }

        # KV store with fixed key
        location /config/timeout {
            consul_kv 127.0.0.1:8500;
            consul_key config/app/timeout;
        }

        # List all services
        location /catalog {
            consul_catalog 127.0.0.1:8500;
        }
    }
}
```

### Consul API Endpoints Used

- `GET /v1/health/service/:service` - Service discovery (healthy instances)
- `GET /v1/kv/:key` - KV store lookup
- `GET /v1/catalog/services` - Catalog listing

### Response Formats

#### Service Discovery

```json
{
  "services": [
    {
      "id": "string",
      "address": "string",
      "port": number,
      "tags": ["string"]
    }
  ]
}
```

#### KV Store

```json
{
  "value": "string or null"
}
```

#### Catalog

```json
{
  "services": ["service-name-1", "service-name-2"]
}
```

### Nginx Variables

These variables expose per-request Consul state to `nginz-njs` scripted modules without subrequest JSON parsing.

| Variable | Values | Scripted consumers |
|---|---|---|
| `$consul_kv_value` | string / not found | `workflow`, `feature_flags` — dynamic config/flag lookup for policy and routing |
| `$consul_kv_found` | `1` / `0` | `workflow` — branch on key presence without parsing JSON |
| `$consul_service_healthy_count` | decimal | `health_gateway`, `workflow` — service-level gating and routing |
| `$consul_lookup_error` | `consul_error` / not found | `workflow`, `health_gateway` — fail-open/fail-closed policy in scripted adapters |

- `$consul_kv_value` is the base64-decoded value from a KV lookup. Not found if the key does not exist, the query is not a KV query, or parsing fails.
- `$consul_kv_found` is `1` when the KV key exists and was decoded, `0` on 404.
- `$consul_service_healthy_count` is the count of healthy service instances returned by a `consul_services` query.
- `$consul_lookup_error` is `consul_error` when Consul returned a non-200/non-404 status or a parse error occurred, not found otherwise.

### Dynamic Upstreams Integration

`dynamic-upstreams` consumes the same Consul health endpoint shape when configured with `dynamic_upstreams_source consul`.

- It queries `GET /v1/health/service/<name>?passing=true` and forwards optional `tag`, `dc`, and `X-Consul-Token` metadata.
- An empty healthy result is valid service-discovery state and reconciles to an empty upstream snapshot rather than preserving stale peers.
- The current `dynamic-upstreams` adapter still requires discovered peer addresses to be IP literals plus port; it does not resolve hostnames returned by Consul.

### Limitations

- Read-only access to Consul (no service registration or KV writes)
- No caching of Consul responses (each request queries Consul)
- No watch/blocking query support (polling model only)
- HTTP only (no HTTPS support for Consul connection)

### Future Enhancements

- [ ] Response caching with TTL
- [ ] Blocking queries for real-time updates
- [ ] HTTPS support for Consul connection
- [ ] Service registration endpoint
- [ ] Health check integration
- [ ] Multiple datacenter fallback

### References

- [Consul HTTP API](https://www.consul.io/api-docs)
- [Consul Health Endpoint](https://www.consul.io/api-docs/health)
- [Consul KV Store](https://www.consul.io/api-docs/kv)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/consul/`.
- [x] Bun integration coverage now verifies tag-filtered service discovery, datacenter query propagation, ACL token header forwarding, passing-only health filtering, empty-string KV values, and JSON-safe KV payload serialization.
- [x] Variable integration coverage now verifies `$consul_kv_found`, `$consul_kv_value`, `$consul_service_healthy_count`, and `$consul_lookup_error` on hit/miss/error paths.
- [x] Gap fixed in this audit pass: KV responses now preserve empty decoded values instead of collapsing them to `null`.
- [x] Gap fixed in this audit pass: KV responses now JSON-escape decoded and raw fallback values so quoted payloads remain valid JSON.
- [x] No additional documentation gaps were identified in this audit pass.
