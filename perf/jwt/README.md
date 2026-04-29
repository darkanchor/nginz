# JWT Module — Performance

## Quick start

```bash
# Snapshot baseline (default)
bun perf/jwt/benchmark/run.js

# Perf-stat profiling
bun perf/jwt/benchmark/run.js --profile=perf-stat

# Single scenario, custom load
bun perf/jwt/benchmark/run.js --scenario=valid-hs256 --requests=5000 --concurrency=4,16,64
```

## Scenarios

| Name | Description | Expected | Overhead profile |
|------|------------|----------|-----------------|
| `valid-hs256` | Valid HS256 token → 200 OK | body="OK" | JWT parse + base64 decode + HMAC-SHA256 verify |
| `valid-claims` | Valid token + claim extraction → 200 OK + headers | body="OK", X-Jwt-Sub="claim-user" | above + CJSON decode + claim traversal |
| `reject-no-token` | No Authorization header → 401 | 401 status | Fast: enabled check + header absence |
| `reject-wrong-secret` | Token with wrong secret → 401 | 401 status | Full parse + HMAC verify (fail) |
| `valid-rs256` | Valid RS256 token (RSA-2048) → 200 OK | body="OK" | JWT parse + base64 decode + EVP_DigestVerify (RSA modular exponentiation) |

## Architecture

The JWT module is the simplest possible perf target — pure CPU, no external
dependencies, no containers, no mock servers:

```
Bun test runner → HTTP → nginz (single worker) → JWT access handler
                                                    │
                                                    ├─ base64url decode (header + payload)
                                                    ├─ HMAC-SHA256 verify (OpenSSL)
                                                    ├─ Optional: CJSON decode + claim extract
                                                    └─ Return 200 OK or 401
```

## No external dependencies

Unlike pgrest (PostgreSQL) or redis (Redis mock), the JWT benchmark requires
zero setup. Tokens are pre-computed in `scenarios.js` using Bun's built-in
`crypto.createHmac`. The nginx config uses inline `jwt_secret` with an HS256 key.

## Baseline

See `notes/2026-04-28-baseline.md` for the initial HS256 baseline with full analysis
including perf-stat hardware counters.

## Worst-case (RS256)

See `notes/2026-04-29-rs256-worstcase.md` for the RS256 worst-case analysis.
RS256 is 2.1× slower than HS256 at single-concurrency (1,955 vs 4,077 rps)
due to RSA-2048 modular exponentiation (~427K instructions/request).

## Upstream C comparison

See `notes/2026-04-29-upstream-comparison.md` for a code-analysis-based comparison against
`nginx-auth-jwt` (the upstream C reference module). Key findings:

- **HS256**: Zig ≈ 1.05× faster (5%) — pool-based JSON allocation offsets slower base64 decode
- **RS256**: Zig ≈ 1.01× (parity) — RSA compute dominates, framework differences are noise
- **Main gap**: `base64url_decode` uses a linear scan (`indexOfScalar`) instead of a 256-entry
  lookup table; fixing this would push HS256 advantage to ~1.10–1.15×
- No upstream benchmark was run; all upstream figures are estimates from static code analysis
