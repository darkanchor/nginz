## JWT Authentication Module

JWT (JSON Web Token) validation for nginx access control.

### Status

**Implemented** - Multi-algorithm JWT validation with claims, headers, revocation lists, and configurable phase selection.

### Features

- **Algorithm coverage in integration tests**: HS256/384/512, RS256/384/512, ES256, PS256, EdDSA, and local JWKS RSA paths are covered end-to-end; broader ES*/PS* family variants remain good candidates for additional matrix coverage
- **Key material**: inline HMAC secrets, keyval key files, local JWKS files (`oct` and RSA public keys), and subrequest-based key fetching via `jwt_key_request`
- **Token sources**: Authorization Bearer tokens and `token=$variable` via `jwt_secret`
- **Claim and header extraction**: `jwt_claim`, `jwt_header`, nested dot-path/array-index lookups, `$jwt_claims`, and `$jwt_nowtime`
- **Validation controls**: `jwt_require_claim`, `jwt_require_header`, `jwt_require`, `jwt_validate_exp`, `jwt_validate_sig`, `jwt_leeway`, `jwt_issuer`, and `jwt_audience`
- **Operational controls**: `jwt_revocation_list_sub`, `jwt_revocation_list_kid`, and `jwt_phase access|preaccess`

### Directives

#### jwt_secret

*syntax:* `jwt_secret <secret>;`
*context:* `http`, `server`, `location`

Enable JWT validation and set the inline HMAC secret or token source. The directive inherits across `http` → `server` → `location`, and `jwt_secret off;` explicitly disables inherited JWT protection for the current block.

#### jwt_key_request

*syntax:* `jwt_key_request <url-or-$variable> [jwks|keyval];`
*context:* `http`, `server`, `location`

Fetch key material (JWKS or keyval) via an nginx subrequest. The subrequest response body is parsed as JWKS (default) or keyval JSON format. Supports literal URLs and nginx variable-based URLs (e.g., `$jwt_key_url`). Multiple `jwt_key_request` directives may be specified; all subrequests are issued in parallel and waited on before JWT validation proceeds. The directive itself does not provide a module-local cache; use nginx caching on the subrequest location when needed.

```nginx
location /jwks {
    return 200 '{"keys":[{"kty":"oct","kid":"k1","k":"...","alg":"HS256"}]}';
}

location /api {
    jwt_key_request /jwks;
    # or variable-based:
    # jwt_key_request $jwt_key_url;
    proxy_pass http://backend;
}
```

### Usage

```nginx
http {
    server {
        listen 8080;

        # Protected API
        location /api {
            jwt_secret "your-secret-key-here";
            proxy_pass http://backend;
        }

        # All nested locations inherit enabled flag and secret
        location /admin {
            jwt_secret "admin-secret-key";

            # All children are protected
            location /admin/users {
                proxy_pass http://backend;
            }

            location /admin/settings {
                proxy_pass http://backend;
            }
        }

        # Public endpoints must be defined separately (not nested under protected locations)
        location /public {
            proxy_pass http://backend;
        }
    }
}
```

**Note**: Since `jwt_secret` enables JWT validation, all nested locations inherit this setting. To have public endpoints, define them outside protected location blocks.

### Token Format

The module expects tokens in the Authorization header:

```http
GET /api/users HTTP/1.1
Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJ1c2VyMTIzIiwiZXhwIjoxNzA1MDAwMDAwfQ.signature
```

### Token Structure

Standard JWT with three base64url-encoded parts:

```
header.payload.signature
```

**Header:**
```json
{"alg": "HS256", "typ": "JWT"}
```

**Payload (Claims):**
```json
{
  "sub": "user123",
  "exp": 1705000000,
  "nbf": 1704900000,
  "iat": 1704900000
}
```

### Claims Validation

| Claim | Description | Validation |
|-------|-------------|------------|
| `exp` | Expiration time (Unix timestamp) | Token rejected if current time > exp |
| `nbf` | Not before (Unix timestamp) | Token rejected if current time < nbf |

Tokens without `exp` or `nbf` claims pass validation (no time check).

### Response Codes

| Status | Reason |
|--------|--------|
| 200 | Valid token, access granted |
| 401 | Missing Authorization header |
| 401 | Invalid token format |
| 401 | Invalid signature |
| 401 | Token expired (exp) |
| 401 | Token not yet valid (nbf) |

### Limitations

Current implementation has these limitations:

- **`jwt_key_request`**: subrequest-based key fetching now supported — issues nginx subrequests with `NGX_HTTP_SUBREQUEST_WAITED | NGX_HTTP_SUBREQUEST_IN_MEMORY` to fetch JWKS or keyval material from internal/external endpoints
- **Fixed-size limits**: `MAX_KEYS = 16`, `MAX_CLAIM_VARS = 8`, `MAX_REQUIRE_CLAIMS = 8`
- **Fixed decode buffers**: header and payload decoding currently rely on bounded stack buffers in the module implementation
- **Nested extraction is leaf-oriented**: nested string and integer values are the strongest supported extraction targets today

### Action Plan — Feature Parity Batches

Reference: [nginx-auth-jwt](https://github.com/nicholaschiasson/nginx-auth-jwt) (C module with 14 algorithms, 15 directives, 4 variables, operator-based claim validation, JWKS, revocation lists, nested paths).

---

#### Batch 1 — Algorithm Expansion & Key Loading ✅

> **Goal**: Support RSA + HMAC variants, load keys from files, subrequest-based key fetch. **(6/6 done)**

| # | Task | Status |
|---|------|--------|
| 1.1 | **RS256/RS384/RS512** — RSA PKCS#1 v1.5 via `EVP_DigestVerify` | ✅ |
| 1.2 | **HS384/HS512** — HMAC-SHA384/512 via `jwt_secret` | ✅ |
| 1.3 | `jwt_key_file` — keyval format (PEM → RSA, raw → HMAC) | ✅ |
| 1.4 | `jwt_key_request` — subrequest-based key fetch | ✅ |
| 1.5 | **`kid` matching** — extract kid, match against key set, fallback to first | ✅ |
| 1.6 | **Algorithm enforcement** — reject unsupported `alg`, match key type (RSA/HMAC) | ✅ |

#### Batch 2 — Claims as Variables ✅

> **Goal**: Expose JWT claims and headers as nginx variables. **(5/5 done)**

| # | Task | Status |
|---|------|--------|
| 2.1 | `jwt_claim` directive — `jwt_claim $var name;` | ✅ |
| 2.2 | `jwt_header` directive — JOSE header extraction | ✅ |
| 2.3 | `$jwt_claims` variable — full payload as JSON | ✅ |
| 2.4 | `$jwt_nowtime` variable — current Unix timestamp | ✅ |
| 2.5 | Nested claim access — dot-paths and JQ-like | ✅ |

#### Batch 3 — Rich Claim Validation ✅

> **Goal**: Validate claims with comparison operators and time controls. **(6/6 done)**

| # | Task | Status |
|---|------|--------|
| 3.1 | `jwt_require_claim` — `jwt_require_claim <name> <op> <value>` | ✅ |
| 3.2 | Operators — eq/!eq, gt/lt/ge/le (numeric) | ✅ |
| 3.3 | JQ-like field paths — nested access | ✅ |
| 3.4 | `jwt_issuer` / `jwt_audience` — dedicated directives | ✅ |
| 3.5 | `jwt_validate_exp` — on/off toggle | ✅ |
| 3.6 | `jwt_leeway` — clock skew tolerance | ✅ |

#### Batch 4 — Key Management & Security

> **Goal**: Security toggles, variable checks, and key request. **(5/5 done)**

| # | Task | Status |
|---|------|--------|
| 4.1 | JWKS subrequest fetching via `jwt_key_request` (cache configuration still external) | ✅ |
| 4.2 | `jwt_validate_sig` — on/off toggle | ✅ |
| 4.3 | `jwt_revocation_list_sub` — JSON file of revoked subs | ✅ |
| 4.4 | `jwt_revocation_list_kid` — JSON file of revoked kids | ✅ |
| 4.5 | `jwt_require` — variable checks | ✅ |

#### Batch 5 — Algorithm & Flexibility ✅

> **Goal**: Token sources and integration flexibility. **(7/7 done)**

| # | Task | Status |
|---|------|--------|
| 5.1 | ES256/ES384/ES512/ES256K — ECDSA | ✅ |
| 5.2 | PS256/PS384/PS512 — RSA-PSS | ✅ |
| 5.3 | EdDSA (Ed25519) | ✅ |
| 5.4 | Token from cookie/variable — `jwt_secret token=$cookie_name` | ✅ |
| 5.5 | `jwt_phase` — preaccess/access | ✅ |
| 5.6 | `jwt_require_header` | ✅ |
| 5.7 | Directive contexts — http/server/location | ✅ |

---

**Progress**: Batch 1 → 5 ordered by impact. Each batch is independently shippable and adds measurable value.

### Generating Test Tokens

**Node.js:**
```javascript
const jwt = require('jsonwebtoken');
const token = jwt.sign(
  { sub: 'user123', exp: Math.floor(Date.now()/1000) + 3600 },
  'your-secret-key'
);
```

**Python:**
```python
import jwt
import time
token = jwt.encode(
    {'sub': 'user123', 'exp': int(time.time()) + 3600},
    'your-secret-key',
    algorithm='HS256'
)
```

### References

- [RFC 7519 - JSON Web Token](https://tools.ietf.org/html/rfc7519)
- [jwt.io](https://jwt.io/) - JWT debugger and library list
- [nginx-jwt-module](https://github.com/TeslaGov/ngx-http-auth-jwt-module)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-29
- [x] Bun integration coverage exists at `tests/jwt/`.
- [x] Bun integration coverage verifies nested child-location inheritance, JOSE header extraction, nested claim/header access, audience matching, revocation lists, local JWKS RSA loading, and phase configuration smoke behavior.
- [x] Algorithm validation is now key-type aware instead of the old HS256-only behavior described by previous docs.
- [x] `jwt_key_request` now supports real subrequest-based key fetching via nginx subrequests.
- [x] The README top summary, counters, and current limitations were refreshed to match the shipped implementation.

### Audit Addendum — 2026-04-29

Audit materials for this pass included:

- the current Zig implementation in `src/modules/jwt-nginx-module/ngx_http_jwt.zig`
- integration coverage under `tests/jwt/`
- JWT perf notes under `perf/jwt/`
- the last five JWT-related git revisions
- the local C reference project at `/home/kaiwu/Documents/github/nginx-auth-jwt`

#### Audit outcomes

Resolved in this remediation pass:

- README top summary, directive context notes, limitations, and roadmap counters were aligned with the shipped implementation.
- `jwt_header` now uses dedicated request-time header extraction instead of the payload-claim path.
- `jwt_phase` is now wired through separate preaccess/access handlers instead of being stored but ignored.
- Local JWKS RSA public-key loading is now supported alongside existing `oct` key handling.
- Revocation-list parsing now reads string-array values correctly, and integration coverage exists for both `sub` and `kid` revocation paths.
- `jwt_key_request` now supports real subrequest-based JWKS/keyval fetching via nginx subrequests.
- Nested claim/header access now works for dot-path and array-index lookups on leaf string/integer values.
- `jwt_audience` now exists as a dedicated shortcut and matches both string and array-form `aud` claims.

Remaining intentionally deferred items:

- broader perf characterization beyond HS256 + RS256 benchmark scenarios

#### Comparison note against the local C reference

The local C reference still goes further on remote key retrieval and some parity niceties, but the Zig module now covers the core local-file and local-JWKS validation surface it claims in this README.

#### jwt_key_request upstream-equivalence action list

The `jwt_key_request` feature now has the main subrequest path implemented, but it is not yet fully upstream-equivalent with `/home/kaiwu/Documents/github/nginx-auth-jwt`.

- [x] Add integration coverage for **multiple `jwt_key_request` directives** on one location.
- [ ] Add integration coverage proving **key accumulation order** matches upstream semantics.
- [x] Add integration coverage proving duplicate-`kid` sources are all considered during verification.
- [x] Add integration coverage for **mixed sources**: local `jwt_key_file` + `jwt_key_request`.
- [x] Add integration coverage for **inherited `jwt_key_request` entries** across the full `http`/`server`/`location` matrix.
- [x] Add integration coverage for **variable-based key request URIs** in inherited configs.
- [x] Add integration coverage for **`keyval` format over subrequest**, not just JWKS.
- [x] Add integration coverage for **malformed subrequest bodies** returning auth failure.
- [x] Add integration coverage for **compressed subrequest responses** being rejected.
- [ ] Add integration coverage for **missing/empty variable URL** behavior.
- [ ] Add integration coverage for **subrequest creation failure** or equivalent failure-path observability if practically testable.
- [ ] Verify and, if needed, fix **request-key append semantics** across repeated subrequests.
- [ ] Verify and, if needed, fix **duplicate-`kid` override behavior** across request-loaded sources.
- [x] Document explicitly that **caching is not built into `jwt_key_request`** and should be done in the subrequest location with nginx mechanisms like `proxy_cache`.
- [ ] Document the upstream-style limitation around **JWT auth running inside a subrequest / ACCESS phase not executing there**, if it also applies here.
- [ ] Add README examples showing the **recommended cached internal JWKS location pattern**.
- [ ] Re-audit the README language so it says **subrequest fetching** rather than **module-provided caching**.
- [ ] Add a targeted audit note or regression test for **nested-subrequest limitation**, if reproducible in this repo.

Progress from the first parity wave:

- request-time subrequest loading works for literal and variable URLs
- multiple `jwt_key_request` directives on one location are integration-tested
- nested-location parent/child composition is integration-tested
- `keyval` subrequest loading is integration-tested
- malformed and compressed subrequest bodies now fail closed
- duplicate-`kid` subrequest sources are now verified as usable in either declaration order
- mixed `jwt_key_file` + `jwt_key_request` sources are now integration-tested
- full `http`/`server`/`location` inheritance and inherited variable-URL coverage are now integration-tested

#### Follow-up TODOs

- [x] Implement real subrequest-backed `jwt_key_request` semantics. *(NGX_HTTP_SUBREQUEST_WAITED + IN_MEMORY, completion callback, re-entrant handler, 7 integration tests)*
- [x] Extend algorithm-matrix coverage further across ES384/ES512/ES256K and PS384/PS512 variants. *(ES384, ES512, PS384, PS512 covered; ES256K deferred — Bun's built-in OpenSSL lacks secp256k1)*
- [x] Extend perf coverage beyond the current HS256-focused baseline. *(RS256 worst-case analysis in `perf/jwt/notes/2026-04-29-rs256-worstcase.md`: 1,955 rps/core, 2.1× slower than HS256, IPC=1.11, ~427K instr/req)*
