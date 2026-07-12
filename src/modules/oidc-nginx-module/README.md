## OpenID Connect Module

OpenID Connect relying-party authentication for nginx locations.

### Status

**Implemented with core RP security closure**

- Discovery-backed metadata (`issuer`, `authorization_endpoint`, `token_endpoint`, `jwks_uri`)
- Authorization Code flow with state, nonce, and optional PKCE
- RS256 ID token verification against JWKS
- Required claim validation before session creation
- Encrypted cookie-backed sessions (AES-256-GCM)
- Claim passthrough via `$oidc_claim_sub`, `$oidc_claim_email`, `$oidc_claim_name`

### Directives

| Directive | Syntax | Default | Description |
|---|---|---|---|
| `oidc` | `on\|off` | `off` | Enable OIDC authentication |
| `oidc_discovery` | `<url>` | - | Required discovery document URL |
| `oidc_client_id` | `<id>` | - | Required OAuth client ID |
| `oidc_client_secret` | `<secret>` | - | OAuth client secret |
| `oidc_redirect_uri` | `<uri>` | - | Required callback URI |
| `oidc_scope` | `<scopes>` | `openid profile email` | Requested scopes |
| `oidc_cookie_name` | `<name>` | `oidc_session` | Session cookie name |
| `oidc_cookie_secret` | `<hex>` | - | Required 32-byte AES key encoded as 64 hex chars |
| `oidc_pkce` | `on\|off` | `on` | Enable PKCE S256 |

### Required Behavior

For the feature-ready path, `oidc on;` requires discovery. The module fails closed if discovery, JWKS retrieval, or ID token verification cannot complete.

### Validation Performed

ID tokens are accepted only when all of the following pass:

- JWT header `alg` is exactly `RS256`
- `kid` is present and found in JWKS
- Signature verifies against the selected JWKS RSA key
- `iss` matches the discovery issuer
- `aud` contains the configured `oidc_client_id` (string or array)
- `exp` is present and not expired
- `sub` is present
- `nonce` is present and matches the nonce stored in the encrypted state cookie

The module rejects `alg=none`, HS* fallback, missing `kid`, unknown `kid`, signature mismatches, and malformed or unverifiable ID tokens.

### Metadata / JWKS Caching

- Discovery metadata is cached per worker / per location in memory
- JWKS is cached per worker / per location in memory
- Cache TTL is intentionally simple: 5 minutes
- Unknown `kid` triggers one JWKS refresh attempt, then the request fails closed if still unresolved

### Time Handling

The module uses a small **30 second skew** for `exp` validation to tolerate minor clock drift while remaining strict.

### Session Cookies

Sessions are stored in an AES-256-GCM encrypted cookie. Only validated claims are persisted to the session:

```json
{
  "sub": "user1",
  "email": "test@example.com",
  "name": "Test User",
  "exp": 1704067200,
  "iat": 1704063600
}
```

### Exposed Variables

| Variable | Description |
|---|---|
| `$oidc_claim_sub` | Subject claim |
| `$oidc_claim_email` | Email claim |
| `$oidc_claim_name` | Name claim |

### Example

```nginx
location /app {
    oidc on;
    oidc_discovery https://idp.example.com/.well-known/openid-configuration;
    oidc_client_id my-client;
    oidc_client_secret my-secret;
    oidc_redirect_uri https://app.example.com/callback;
    oidc_cookie_secret 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef;

    proxy_set_header X-User-Sub $oidc_claim_sub;
    proxy_set_header X-User-Email $oidc_claim_email;
    proxy_set_header X-User-Name $oidc_claim_name;

    proxy_pass http://backend;
}
```

### Current Scope / Limitations

Implemented here:

- Discovery-backed core authorization code flow
- RS256 ID token verification via JWKS
- State + nonce protection
- Basic claim passthrough

Still out of scope:

- Refresh token handling
- RP logout / back-channel logout
- Advanced custom claim mapping
- Multi-node shared session storage
- Non-RS256 signing algorithms

### Tests

`tests/oidc/` covers:

- successful signed-token flow
- tampered signature rejection
- wrong issuer rejection
- wrong audience rejection
- nonce mismatch rejection
- expired token rejection
- unknown `kid` rejection
- authenticated claim passthrough

### References

- [OpenID Connect Core 1.0](https://openid.net/specs/openid-connect-core-1_0.html)
- [RFC 7517 - JSON Web Key](https://datatracker.ietf.org/doc/html/rfc7517)
- [RFC 7519 - JSON Web Token](https://datatracker.ietf.org/doc/html/rfc7519)

### Engineering Audit Verdict (2026-07-12)

**Verdict: S0 TRANSPORT FIXED; S1 EVENTED FETCH/TLS NEGATIVES OPEN.** Token exchange and HTTPS discovery/JWKS fetching now use system CA roots, SNI, certificate verification, and hostname validation. Metadata responses are capped at 1 MiB, and plain HTTP is rejected unless `oidc_allow_insecure_http on` is explicitly configured for local testing. OIDC state is mandatory and state/nonce secrets use constant-time comparison. A live oversized-JWKS flow fails closed at the 1 MiB bound, and the 24-case focused flow remains green. The metadata fetcher still uses blocking sockets, and negative untrusted-CA/hostname integration cases remain high-priority hardening work.
