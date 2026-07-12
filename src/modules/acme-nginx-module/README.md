## ACME/Let's Encrypt Module

Automatic SSL certificate provisioning and renewal using the ACME protocol (RFC 8555).

### Status

**Feature Ready** - Single-domain trigger-driven HTTP-01 issuance works end-to-end against both the mock ACME server and a live Pebble + challtestsrv Docker suite, including challenge serving, SAN-bearing CSR finalization, and persisted certificate storage.

#### Implemented Features
- [x] Base64url encoding/decoding (RFC 4648)
- [x] SHA256 hashing
- [x] JWK thumbprint calculation (RFC 7638)
- [x] RSA key generation (2048-bit)
- [x] JWS signing with RS256 (RFC 7515)
- [x] CSR generation (X509_REQ)
- [x] HTTP-01 challenge handler (ACCESS phase, intercepts regardless of location handler)
- [x] Shared-memory challenge storage (max 32 active challenges)
- [x] File storage (account keys, domain keys, certificates)
- [x] Certificate expiry checking
- [x] Module configuration and directives
- [x] ACME protocol state machine (`AcmeState` enum with 12 states)
- [x] ACME directory/order/authorization parsing (JSON via cJSON)
- [x] HTTP request builder for ACME operations (`AcmeHttpRequest`)
- [x] Trigger endpoint (`/.well-known/acme-trigger`) to initiate ACME flow
- [x] Upstream integration skeleton (callbacks implemented)
- [x] End-to-end mock ACME issuance through account initialization, challenge registration, authorization polling, finalization, and persisted `fullchain.pem` / `privkey.pem` output
- [x] Docker-backed live HTTP-01 issuance against Pebble + challtestsrv, including real validation on port 80 and persisted `account.key` / `fullchain.pem` / `privkey.pem` output

#### Current Limitations
- Error recovery is still simple; repeated trigger calls advance the state machine but do not implement rich retry/backoff policy
- Verified issuance coverage is currently the single-domain HTTP-01 path; multi-identifier/SAN orders are not yet exercised by the live suite
- Shared session/challenge state is nginx-shared-memory backed, but live coverage is still limited to a sequential trigger-driven Pebble harness rather than concurrent trigger stress

#### Pending Features
- [x] End-to-end testing with Pebble + challtestsrv
- [x] Multi-worker support for trigger-progress/challenge state via shm-backed per-domain sessions
- [ ] Error recovery and retry logic

#### Renewal Strategy

Renewal is handled externally via the trigger endpoint - no internal timer needed:

```bash
# Cron job (recommended)
0 0 * * * curl -s http://localhost/.well-known/acme-trigger

# Or systemd timer
# /etc/systemd/system/acme-renewal.timer
```

This approach is simpler, more debuggable, and follows the same pattern as certbot.

#### Current Design Notes

- Both `/.well-known/acme-challenge/*` and `/.well-known/acme-trigger` are intercepted in the nginx **ACCESS** phase, so they run before normal location content handlers.
- `/.well-known/acme-trigger` advances the ACME state machine one step at a time and returns JSON statuses such as `initialized`, `started`, `complete`, or `error`.
- Live ACME progress is now stored in an nginx shared-memory zone keyed by domain, so later trigger requests can land on different workers and still resume the same step-driven flow.
- Persistent storage is part of the working design: the module loads or creates `account.key`, then writes `certs/<domain>/fullchain.pem` and `certs/<domain>/privkey.pem` when issuance completes.
- Domain private keys are now persisted as soon as finalization needs them, which lets finalize/certificate steps survive cross-worker requests without relying on worker globals.
- Renewal is intentionally **external-trigger driven**, not timer driven inside nginx. Repeated trigger calls resume or advance the shared per-domain ACME session state.

### Implementation Plan

#### Phase 1: HTTP-01 Challenge + Basic ACME Client

Focus on the most common use case - automatic certificates for single domains:

1. **HTTP-01 Challenge Handler** - Serve challenge responses at `/.well-known/acme-challenge/`
2. **ACME Account Management** - Create/load account keys
3. **Certificate Ordering** - Request certificates from ACME server
4. **CSR Generation** - Create Certificate Signing Requests
5. **JWS Signing** - Sign ACME requests with RS256
6. **Certificate Storage** - Store certs and keys on filesystem
7. **External Renewal Trigger** - Renewal is driven by repeated calls to `/.well-known/acme-trigger`

#### Architecture

```
                             ACME Server (Let's Encrypt)
                                      ^
                                      | HTTPS (JWS-signed requests)
                                      |
┌─────────────────────────────────────┴─────────────────────────────────────┐
│                              nginx + ACME module                           │
│                                                                            │
│  ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────────┐ │
│  │  Challenge       │    │  ACME Client     │    │  Certificate         │ │
│  │  Handler         │    │  (upstream)      │    │  Manager             │ │
│  │                  │    │                  │    │                      │ │
│  │  Intercepts      │    │  Account reg     │    │  Load/store certs    │ │
│  │  /.well-known/   │    │  Order creation  │    │  Trigger-driven flow │ │
│  │  acme-challenge/ │    │  Challenge ready │    │  Key generation      │ │
│  │                  │    │  Finalization    │    │                      │ │
│  └──────────────────┘    └──────────────────┘    └──────────────────────┘ │
│           │                       │                        │              │
│           └───────────────────────┴────────────────────────┘              │
│                                   │                                        │
│                          ┌────────┴────────┐                              │
│                          │  Storage        │                              │
│                          │  /acme/         │                              │
│                          │  ├─ account.key │                              │
│                          │  └─ certs/      │                              │
│                          │     └─ domain/  │                              │
│                          │        ├─ cert  │                              │
│                          │        └─ key   │                              │
│                          └─────────────────┘                              │
└───────────────────────────────────────────────────────────────────────────┘
```

#### ACME Protocol Flow

```
┌─────────┐                      ┌─────────────┐                    ┌─────────────┐
│  nginx  │                      │ ACME Server │                    │  Storage    │
└────┬────┘                      └──────┬──────┘                    └──────┬──────┘
     │                                  │                                  │
     │  1. GET /directory               │                                  │
     │─────────────────────────────────>│                                  │
     │  {newNonce, newAccount, ...}     │                                  │
     │<─────────────────────────────────│                                  │
     │                                  │                                  │
     │  2. POST /acme/new-account       │                                  │
     │  (JWS with new key)              │                                  │
     │─────────────────────────────────>│                                  │
     │  {account URL}                   │                                  │
     │<─────────────────────────────────│                                  │
     │                                  │                                  │
     │  3. POST /acme/new-order         │                                  │
     │  {identifiers: [{dns: domain}]}  │                                  │
     │─────────────────────────────────>│                                  │
     │  {authorizations, finalize URL}  │                                  │
     │<─────────────────────────────────│                                  │
     │                                  │                                  │
     │  4. POST authorization URL       │                                  │
     │─────────────────────────────────>│                                  │
     │  {challenges: [{type: http-01}]} │                                  │
     │<─────────────────────────────────│                                  │
     │                                  │                                  │
     │  5. Prepare challenge response   │                                  │
     │─────────────────────────────────────────────────────────────────────>│
     │                                  │                                  │
     │  6. POST challenge URL (ready)   │                                  │
     │─────────────────────────────────>│                                  │
     │                                  │                                  │
     │                                  │  7. GET http://domain/.well-     │
     │<─────────────────────────────────│     known/acme-challenge/{token} │
     │  {token}.{thumbprint}            │                                  │
     │─────────────────────────────────>│                                  │
     │                                  │                                  │
     │  8. Poll authorization (valid)   │                                  │
     │<────────────────────────────────>│                                  │
     │                                  │                                  │
     │  9. POST /acme/finalize          │                                  │
     │  {csr: base64url(CSR)}           │                                  │
     │─────────────────────────────────>│                                  │
     │  {certificate URL}               │                                  │
     │<─────────────────────────────────│                                  │
     │                                  │                                  │
     │  10. GET certificate URL         │                                  │
     │─────────────────────────────────>│                                  │
     │  PEM certificate chain           │                                  │
     │<─────────────────────────────────│                                  │
     │                                  │                                  │
     │  11. Store certificate           │                                  │
     │─────────────────────────────────────────────────────────────────────>│
     │                                  │                                  │
```

#### Module Structure

```
src/modules/acme-nginx-module/
├── ngx_http_acme.zig      # Main module, config, challenge handler
└── README.md
```

#### Config Structures

```zig
const acme_main_conf = extern struct {
    enabled: ngx_flag_t,              // acme on|off
    directory_url: ngx_str_t,         // ACME directory URL
    account_email: ngx_str_t,         // Contact email
    storage_path: ngx_str_t,          // Path for certs and account key
    challenge_type: ngx_uint_t,       // http_01 (dns_01 in Phase 2)
    renew_before_days: ngx_uint_t,    // Renew when N days until expiry
    staging: ngx_flag_t,              // Use staging server for testing

    // Cached directory endpoints
    new_nonce_url: ngx_str_t,
    new_account_url: ngx_str_t,
    new_order_url: ngx_str_t,

    // Account state
    account_key: [*c]NSSL_RSA,        // RSA key for JWS signing
    account_url: ngx_str_t,           // Registered account URL (kid)

    // Upstream for ACME API calls
    ups: ngx_http_upstream_conf_t,
};

const acme_srv_conf = extern struct {
    domain: ngx_str_t,                // Domain for this server
    cert_path: ngx_str_t,             // Path to certificate (set by module)
    key_path: ngx_str_t,              // Path to private key (set by module)
};

// Challenge state (stored during authorization)
const acme_challenge = extern struct {
    token: ngx_str_t,                 // Challenge token
    key_authorization: ngx_str_t,     // token.thumbprint
    domain: ngx_str_t,                // Domain being validated
    expires: ngx_msec_t,              // When challenge expires
};
```

#### Directives

| Directive | Syntax | Default | Context | Description |
|-----------|--------|---------|---------|-------------|
| `acme` | `on\|off` | `off` | http | Enable ACME certificate management |
| `acme_server` | `<url>` | Let's Encrypt prod | http | ACME directory URL |
| `acme_trusted_certificate` | `<file>` | system trust only | http | Additional CA bundle for private ACME authorities such as Pebble |
| `acme_staging` | `on\|off` | `off` | http | Use Let's Encrypt staging |
| `acme_email` | `<email>` | - | http | Account contact email |
| `acme_storage` | `<path>` | `/etc/nginx/acme` | http | Storage directory |
| `acme_renew_before` | `<days>` | `30` | http | Days before expiry to renew |
| `acme_domain` | `<domain>` | - | server | Domain for this server block |

#### JWS (JSON Web Signature) Format

ACME uses JWS for all authenticated requests:

```
{
  "protected": base64url({
    "alg": "RS256",
    "nonce": "<fresh-nonce>",
    "url": "<request-url>",
    "jwk": {...}  // or "kid": "<account-url>"
  }),
  "payload": base64url(<request-body>),  // or "" for POST-as-GET
  "signature": base64url(RS256(protected.payload))
}
```

```zig
fn createJws(
    pool: [*c]ngx_pool_t,
    rsa: *NSSL_RSA,
    nonce: ngx_str_t,
    url: ngx_str_t,
    kid: ?ngx_str_t,     // account URL (null for new account)
    payload: ngx_str_t,  // JSON payload or empty
) !ngx_str_t {
    // 1. Build protected header JSON
    // 2. Base64url encode protected header
    // 3. Base64url encode payload (or empty string)
    // 4. Sign: RS256(protected || "." || payload)
    // 5. Base64url encode signature
    // 6. Return: {"protected":"...","payload":"...","signature":"..."}
}
```

#### Account Key Thumbprint

Required for challenge key authorization:

```zig
fn computeThumbprint(rsa: *NSSL_RSA, pool: [*c]ngx_pool_t) !ngx_str_t {
    // 1. Extract public key as JWK
    // 2. Create canonical JSON: {"e":"...","kty":"RSA","n":"..."}
    // 3. SHA256 hash
    // 4. Base64url encode
}
```

#### CSR Generation

```zig
fn generateCsr(
    pool: [*c]ngx_pool_t,
    domain: ngx_str_t,
    key_path: ngx_str_t,
) !ngx_str_t {
    // Using OpenSSL:
    // 1. Generate RSA private key
    // 2. Create X509_REQ
    // 3. Set subject CN to domain
    // 4. Sign CSR with private key
    // 5. DER encode, then base64url
}
```

#### HTTP-01 Challenge Handler

```zig
export fn ngx_http_acme_challenge_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // 1. Check if URI starts with /.well-known/acme-challenge/
    if (!isAcmeChallengeUri(r)) {
        return NGX_DECLINED;  // Let other handlers process
    }

    // 2. Extract token from URI
    const token = extractToken(r.*.uri);

    // 3. Look up challenge by token
    const challenge = findChallenge(token) orelse {
        return NGX_HTTP_NOT_FOUND;
    };

    // 4. Return key authorization
    // Content-Type: text/plain
    // Body: {token}.{thumbprint}
    return sendChallengeResponse(r, challenge.key_authorization);
}
```

#### Certificate Manager

```zig
const CertManager = struct {
    // Called on nginx startup and periodically
    fn checkAndRenew(cf: *acme_main_conf, domain: ngx_str_t) !void {
        const cert_path = buildCertPath(cf.storage_path, domain);

        // 1. Check if certificate exists
        if (!fileExists(cert_path)) {
            return requestNewCertificate(cf, domain);
        }

        // 2. Check expiration
        const days_until_expiry = getCertDaysRemaining(cert_path);
        if (days_until_expiry <= cf.renew_before_days) {
            return requestNewCertificate(cf, domain);
        }
    }

    fn requestNewCertificate(cf: *acme_main_conf, domain: ngx_str_t) !void {
        // 1. Fetch fresh nonce
        // 2. Create order
        // 3. Get authorization
        // 4. Prepare challenge
        // 5. Notify ACME server we're ready
        // 6. Poll until valid
        // 7. Generate CSR
        // 8. Finalize order
        // 9. Download certificate
        // 10. Store files
    }
};
```

#### Renewal Execution Model

```zig
export fn ngx_http_acme_trigger_handler(r: [*c]ngx_http_request_t) callconv(.c) ngx_int_t {
    // 1. Initialize worker-global ACME state on the first trigger
    // 2. Advance the ACME state machine one step per call
    // 3. Return JSON status for the current step or terminal state
    // 4. Persist account/certificate material when issuance completes
}
```

The current implementation does **not** run an internal nginx timer for renewal checks.

#### Storage Layout

```
/etc/nginx/acme/
├── account.key           # RSA private key (PEM)
├── account.json          # Account URL and metadata
└── certs/
    └── example.com/
        ├── fullchain.pem # Certificate + intermediates
        └── privkey.pem   # Domain private key
```

#### Test Cases

1. **Challenge endpoint** → Serves correct key authorization
2. **Unknown token** → Returns 404
3. **New account registration** → Creates account and stores key
4. **Existing account** → Loads key and uses kid
5. **Certificate request** → Full flow with mock ACME server
6. **Renewal check** → Skips valid certs, renews expiring
7. **JWS signature** → Correct RS256 signature format
8. **CSR generation** → Valid DER-encoded CSR

#### nginx.conf Example

```nginx
http {
    acme on;
    acme_email admin@example.com;
    acme_storage /etc/nginx/acme;
    # acme_staging on;  # Uncomment for testing

    server {
        listen 80;
        server_name example.com;

        # ACME challenge location - handled by module automatically
        # No explicit location needed, module intercepts /.well-known/acme-challenge/

        location / {
            return 301 https://$host$request_uri;
        }
    }

    server {
        listen 443 ssl;
        server_name example.com;

        acme_domain example.com;

        # Module sets these paths automatically after obtaining cert
        # ssl_certificate /etc/nginx/acme/certs/example.com/fullchain.pem;
        # ssl_certificate_key /etc/nginx/acme/certs/example.com/privkey.pem;

        # Or use nginx variables (Phase 2)
        # ssl_certificate $acme_cert;
        # ssl_certificate_key $acme_key;

        location / {
            proxy_pass http://backend;
        }
    }
}
```

### Phase 2: Future Enhancements

- [ ] **DNS-01 Challenge** - For wildcard certificates
- [ ] **TLS-ALPN-01 Challenge** - Port 443 only validation
- [ ] **Multiple Domains/SANs** - Single cert for multiple domains
- [ ] **Wildcard Certificates** - *.example.com (requires DNS-01)
- [ ] **ECDSA Keys** - ES256 for smaller, faster keys
- [ ] **Certificate Variables** - `$acme_cert`, `$acme_key` for dynamic loading
- [ ] **OCSP Stapling** - Automatic OCSP response caching
- [ ] **Rate Limiting** - Respect Let's Encrypt rate limits
- [ ] **Clustered Renewal** - Shared storage for nginx clusters

### Implementation Order

1. Create module skeleton with config structs and directives
2. Implement HTTP-01 challenge handler (intercept and respond)
3. Implement JWS signing with RS256 (using NSSL_RSA)
4. Implement account key generation and storage
5. Implement account thumbprint calculation
6. Implement ACME API client using upstream
7. Implement nonce management
8. Implement account registration
9. Implement order creation
10. Implement authorization and challenge handling
11. Implement CSR generation
12. Implement order finalization
13. Implement certificate download and storage
14. Implement renewal timer
15. Write integration tests with Pebble (ACME test server)

### Complexity Estimate

- **Lines of code**: ~1500-2000
- **Difficulty**: High (HTTP client, JWS/crypto, CSR generation, state machine)
- **Dependencies**: NSSL_RSA (available), cJSON (available), upstream (available)

### Security Considerations

- **Account Key Protection**: Store with restricted permissions (0600)
- **Domain Validation**: Only request certs for configured domains
- **Rate Limiting**: Respect ACME server rate limits
- **Staging First**: Test with staging server before production
- **Key Storage**: Domain private keys stored securely
- **Nonce Replay**: Fresh nonce for every request

### Testing Strategy

Use [Pebble](https://github.com/letsencrypt/pebble) as mock ACME server:
- Lightweight test CA
- Fast certificate issuance
- No rate limiting
- Configurable validation

```bash
# Start Pebble for testing
docker run -p 14000:14000 letsencrypt/pebble

# Run integration tests
ACME_SERVER=https://localhost:14000/dir bun test tests/acme/
```

### ACME Server URLs

| Provider | Production | Staging |
|----------|-----------|---------|
| Let's Encrypt | https://acme-v02.api.letsencrypt.org/directory | https://acme-staging-v02.api.letsencrypt.org/directory |
| ZeroSSL | https://acme.zerossl.com/v2/DV90 | - |
| Buypass | https://api.buypass.com/acme/directory | https://api.test4.buypass.no/acme/directory |

### References

- [RFC 8555 - ACME Protocol](https://tools.ietf.org/html/rfc8555)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)
- [Pebble Test Server](https://github.com/letsencrypt/pebble)
- [JWS RFC 7515](https://tools.ietf.org/html/rfc7515)
- [lua-resty-auto-ssl](https://github.com/auto-ssl/lua-resty-auto-ssl)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Bun integration coverage exists at `tests/acme/`.
- [x] Gap recorded: the trigger-driven end-to-end mock ACME flow is now exercised through certificate storage; `tests/acme/` verifies account key creation, live challenge serving, repeated trigger safety, and persisted `fullchain.pem`/`privkey.pem` output.
- [x] Gap recorded: the previously skipped certificate-storage Bun case was enabled in this audit pass after isolating ACME's worker-global state with a fresh nginx/mock restart inside that test.
- [x] Gap recorded: README documents `acme_staging` and `acme_renew_before`, but the current exported command table does not implement those directives; `acme_trusted_certificate` is implemented for explicit private-PKI trust.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S0/S1 CORE FIXED.** ACME upstreams use system CA trust, SNI, certificate verification, and hostname validation. `acme_server` requires HTTPS by default; private authorities require an explicit `acme_trusted_certificate`. Live Pebble coverage proves private-CA issuance and rejects an untrusted CA, hostname mismatch, and malformed trust material. The shared zone is cycle-refreshed and mutex-protected. Fixed capacities (16 sessions/32 challenges) reject overflow without eviction; session exhaustion is 503, and a two-worker saturation/reload proof preserves all admitted state.
