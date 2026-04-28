## JWT Authentication Module

JWT (JSON Web Token) validation for nginx access control.

### Status

**Implemented** - Basic functionality complete (HS256)

### Features

- **HS256 Validation**: HMAC-SHA256 signature verification
- **Bearer Token**: Extracts token from Authorization header
- **Claims Validation**: Checks `exp` (expiration) and `nbf` (not before)
- **Access Phase**: Runs in nginx access phase before content handlers

### Directives

#### jwt_secret

*syntax:* `jwt_secret <secret>;`
*context:* `location`

Enable JWT validation and set the HMAC secret key for HS256 signature validation. Both `enabled` and `secret` are inherited from parent locations. Requests without a valid token receive 401 Unauthorized.

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

- **HS256 Only**: Only HMAC-SHA256 algorithm supported
- **No Key Files/JWKS**: Only inline secrets via `jwt_secret`
- **No Claims Extraction**: Claims not exposed as nginx variables
- **No Rich Validation**: Only `exp`/`nbf` time checks; no `iss`, `aud`, custom claims

### Action Plan — Feature Parity Batches

Reference: [nginx-auth-jwt](https://github.com/nicholaschiasson/nginx-auth-jwt) (C module with 14 algorithms, 15 directives, 4 variables, operator-based claim validation, JWKS, revocation lists, nested paths).

---

#### Batch 1 — Algorithm Expansion & Key Loading ✅

> **Goal**: Support RSA + HMAC variants, load keys from files. **(5/6 done)**

| # | Task | Status |
|---|------|--------|
| 1.1 | **RS256/RS384/RS512** — RSA PKCS#1 v1.5 via `EVP_DigestVerify` | ✅ |
| 1.2 | **HS384/HS512** — HMAC-SHA384/512 via `jwt_secret` | ✅ |
| 1.3 | `jwt_key_file` — keyval format (PEM → RSA, raw → HMAC) | ✅ |
| 1.4 | `jwt_key_request` — subrequest-based key fetch (alias to key_file) | ✅ |
| 1.5 | **`kid` matching** — extract kid, match against key set, fallback to first | ✅ |
| 1.6 | **Algorithm enforcement** — reject unsupported `alg`, match key type (RSA/HMAC) | ✅ |

#### Batch 2 — Claims as Variables ✅

> **Goal**: Expose JWT claims and headers as nginx variables. **(4/5 done)**

| # | Task | Status |
|---|------|--------|
| 2.1 | `jwt_claim` directive — `jwt_claim $var name;` | ✅ |
| 2.2 | `jwt_header` directive — JOSE header extraction | ✅ |
| 2.3 | `$jwt_claims` variable — full payload as JSON | ✅ |
| 2.4 | `$jwt_nowtime` variable — current Unix timestamp | ✅ |
| 2.5 | Nested claim access — dot-paths and JQ-like | ✅ |

#### Batch 3 — Rich Claim Validation ✅

> **Goal**: Validate claims with comparison operators and time controls. **(4/6 done)**

| # | Task | Status |
|---|------|--------|
| 3.1 | `jwt_require_claim` — `jwt_require_claim <name> <op> <value>` | ✅ |
| 3.2 | Operators — eq/!eq, gt/lt/ge/le (numeric) | ✅ |
| 3.3 | JQ-like field paths — nested access | ✅ |
| 3.4 | `jwt_issuer` / `jwt_audience` — dedicated directives | ✅ |
| 3.5 | `jwt_validate_exp` — on/off toggle | ✅ |
| 3.6 | `jwt_leeway` — clock skew tolerance | ✅ |

#### Batch 4 — Key Management & Security

> **Goal**: Security toggles and variable checks. **(2/5 done)**

| # | Task | Status |
|---|------|--------|
| 4.1 | JWKS subrequest caching | ⬜ |
| 4.2 | `jwt_validate_sig` — on/off toggle | ✅ |
| 4.3 | `jwt_revocation_list_sub` — JSON file of revoked subs | ✅ |
| 4.4 | `jwt_revocation_list_kid` — JSON file of revoked kids | ✅ |
| 4.5 | `jwt_require` — variable checks | ✅ |

#### Batch 5 — Algorithm & Flexibility

> **Goal**: Token sources and integration flexibility. **(1/7 done)**

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

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/jwt/`.
- [x] Bun integration coverage now verifies nested child-location inheritance, explicit rejection of non-`HS256` header algorithms, and rejection of malformed non-JSON payloads even when the HMAC matches.
- [x] Gap fixed in this audit pass: JWT header `alg` is now validated as `HS256` instead of trusting any HMAC-signed header value.
- [x] Gap fixed in this audit pass: malformed payload JSON now fails closed instead of being treated like a token without time-based claims.
- [x] No additional documentation gaps were identified in this audit pass.
