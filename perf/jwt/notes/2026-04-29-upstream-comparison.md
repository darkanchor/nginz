# JWT Module — Upstream C Comparison Analysis

## Context

This note compares the Zig JWT module (`jwt-nginx-module`) against the upstream C reference
(`nginx-auth-jwt` at `/home/kaiwu/Documents/github/nginx-auth-jwt`) without running the
upstream module directly. Estimates are derived from:

- Measured Zig baseline: `2026-04-28-baseline.md` (HS256) and `2026-04-29-rs256-worstcase.md` (RS256)
- Static code analysis of both implementations
- Component-level timing estimates from hardware counter data

No upstream benchmark was run. All upstream figures are estimates.

---

## Key implementation differences

### Base64url decode

**Zig** (`base64url_decode`, lines 205–253):
- Uses a 4096-byte **stack buffer** — zero heap allocations
- Character substitution (`-`→`+`, `_`→`/`) done inline in a first pass
- Decodes via `std.mem.indexOfScalar(u8, alphabet, char)` — a **linear scan through 64
  characters per input byte** (average ~32 comparisons/char, ~64 cycles/char in ReleaseSmall)

**Upstream C** (`ngx_auth_jwt_b64url_decode`, `jws_base64url_decode`):
- 2 `malloc` + 3 BIO object allocations (`BIO_new`, `BIO_new_mem_buf`, `BIO_push`) per call
- Decodes via OpenSSL BIO `BIO_read` which uses a **precomputed 256-entry lookup table**
  (~1 cycle/char)
- `BIO_free_all` + 2 `free` on completion

For a typical HS256 JWT with ~244 base64 characters across header + payload + signature:

| Implementation | Mechanism | Estimated cost (3 decodes/req) |
|---------------|-----------|-------------------------------|
| Zig            | Linear search, zero alloc | ~5.5μs |
| Upstream C     | Lookup table, BIO+malloc   | ~4.5μs |

The upstream lookup table is ~10× faster per character, but its BIO setup and malloc overhead
partially close the gap. Net: **Zig is ~1μs slower on base64** despite avoiding heap allocations.

### JSON parsing

**Zig**: cJSON via `ngx_pool` — bump allocator, each node is an `ngx_pcalloc` (~5–20ns).
No individual frees; pool is released with the request.

**Upstream C**: Jansson (`json_loadb`) — heap-allocated nodes with `malloc` per JSON string
and an internal hashtable for object fields. Ref-counted. For a 5-field JWT payload, Jansson
issues ~7–10 individual heap allocations.

| Implementation | Allocator | Estimated cost (header + payload) |
|---------------|-----------|-----------------------------------|
| Zig (cJSON+pool) | Bump alloc, ~10ns/node | ~2μs |
| Upstream (Jansson+heap) | malloc, ~100ns/node | ~5–7μs |

**Zig is 4–5μs faster on JSON parsing.**

### Signature verification (crypto)

Both call identical OpenSSL EVP APIs:
- HMAC: `HMAC_CTX_new` / `HMAC_Init_ex` / `HMAC_Update` / `HMAC_Final` / `HMAC_CTX_free`
  (Zig explicit ctx) vs `HMAC()` wrapper (upstream; internally the same). Functionally equal.
- RSA/ECDSA/EdDSA: both use `EVP_DigestVerifyInit` + `EVP_DigestVerify`. Identical path.
- Constant-time comparison: Zig uses a custom xor-accumulate loop; upstream uses
  `CRYPTO_memcmp`. Both are constant-time and functionally equivalent.

Crypto is **identical** on both sides.

### Token handling

**Zig**: works off a slice into the existing nginx request buffer. No token copy.

**Upstream**: `ngx_pnalloc(pool, token_len + 1)` + `ngx_memcpy` to store a token copy, then
`OPENSSL_cleanse` after use (security scrubbing). Adds ~0.5μs and a pool allocation per
request. (The cleanse is good security hygiene — Zig skips it.)

### HMAC context allocation

**Zig**: `HMAC_CTX_new()` (1 heap alloc via OpenSSL) + `HMAC_CTX_free()` per verify.

**Upstream**: `HMAC()` wrapper also internally allocates and frees an `HMAC_CTX`.

**Equal**.

---

## Component-level budget (HS256, per request)

Measured Zig HS256-specific cost (from baseline): **~70μs** total delta over reject-no-token
baseline (nginx content handler path vs error path). Of this, pure JWT compute is:

| Component | Zig | Upstream (estimated) | Delta |
|-----------|-----|----------------------|-------|
| Base64url decode (×3) | ~5.5μs | ~4.5μs | Zig +1μs |
| JSON parse header+payload | ~2μs | ~6μs | Zig −4μs |
| Token copy | 0μs | ~0.5μs | Zig −0.5μs |
| HMAC-SHA256 | ~0.06μs | ~0.06μs | Equal |
| **Net JWT-compute delta** | — | — | **Zig ~3.5μs faster** |

The 3.5μs savings is a **~5%** improvement on the estimated upstream JWT-specific compute of
~70μs. Most of the 70μs is nginx framework overhead (different handler paths for 200 vs 401),
not JWT computation.

---

## Overall throughput estimate

No upstream benchmark was run. Estimates are derived from the component budget above.

| Scenario | Zig measured | Upstream estimated | Ratio |
|----------|-------------|-------------------|-------|
| HS256 c=1 | 4,077 rps | ~3,800–3,900 rps | **~1.05×** |
| HS256 c=32 | 14,725 rps | ~12,500–13,500 rps | **~1.05–1.10×** |
| RS256 c=1 | 1,955 rps | ~1,900–1,930 rps | **~1.01–1.03×** |
| RS256 c=32 | 6,212 rps | ~5,800–6,000 rps | **~1.02–1.07×** |

**Effective parity for RS256; 5–10% advantage for HS256.**

At high concurrency, the Zig module gains slightly because:
1. Pool allocation (ngx_pool) has no global lock — per-request bump pointer
2. Upstream's Jansson + BIO mallocs hit the system heap allocator under concurrent load,
   which can serialize on glibc malloc's arena locks

---

## The main perf gap: base64url decode ✅ Fixed

The `base64url_decode` function was the only concrete optimization opportunity. The linear
search through the 64-char alphabet string was ~10× slower per character than a lookup table.

**Fix applied** (commit on 2026-04-29): replaced with a compile-time 256-byte decode table
that maps ASCII bytes directly to 6-bit values, handling `-` and `_` as 62/63 inline:

```zig
const b64url_table: [256]u8 = blk: {
    var t = [_]u8{0xFF} ** 256;
    const std_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    for (std_chars, 0..) |c, i| t[c] = @intCast(i);
    t['-'] = 62;
    t['_'] = 63;
    break :blk t;
};
```

This eliminates:
- The first character-substitution pass (`-`→`+`, `_`→`/`) — no longer needed
- The 4096-byte stack temp buffer — reads directly from input
- The `std.mem.indexOfScalar` linear search (~64 cycles/char) — replaced by 1 table lookup

Expected savings: **~5μs per request** (from ~5.5μs → ~0.4μs for 3 decodes).

After this fix, the combined effect (faster base64 + pool JSON) gives Zig a genuine
**~1.10–1.15× advantage over upstream** for HS256 at c=1, growing toward **1.15–1.20×** at
c=32 due to reduced allocator contention.

For RS256, the RSA compute (220μs out of ~290μs JWT-specific) so completely dominates that
the 5μs base64 savings are noise: improvement is ~2–3% regardless.

---

## Summary

| | HS256 | RS256 |
|-|-------|-------|
| Pre-fix Zig vs upstream | ~1.05× (5% faster) | ~1.01× (parity) |
| **Post-fix Zig vs upstream** | **~1.10–1.15×** | **~1.02–1.03×** |
| Dominant factor | JSON alloc + base64 | RSA-2048 modular exponentiation |

The lookup-table fix was applied; `base64url_decode` now reads directly from the input
with a single table lookup per byte. No benchmark re-run yet — figures above are estimates.

The Zig module's pool-allocation design is structurally sound and provides a real but modest
advantage over the upstream C module's malloc-heavy approach. The only code-level regression
is the linear-search base64 decoder, which cancels roughly half of the JSON allocation benefit.
Fixing it is a one-function change with no API impact.

For RS256 and other asymmetric algorithms, neither module's framework overhead is relevant —
both are fully OpenSSL-bound and effectively identical.

---

## Appendix — upstream C sources examined

- `src/ngx_auth_jwt_decode.c` — JWT splitting, `ngx_auth_jwt_b64url_decode`, Jansson decode
- `src/ngx_auth_jwt_jws.c` — `jws_base64url_decode`, HMAC/RSA/EC/EdDSA verification, key matching
- `src/ngx_auth_jwt_claims.c`, `src/ngx_auth_jwt_field.c` — claim extraction (not benchmarked)
- `docs/DIRECTIVES.md` — feature surface reference
