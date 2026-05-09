# Dynamic Upstreams Combo - Optimization Angles

Date: 2026-05-09

This note surveys the remaining optimization angles for the combo benchmark after the 2026-05-08 hardening rounds. For each angle it states whether it was implemented, what the expected gain is, and where the hard limits are.

## Angle 1 — Replace `std.mem.zeroes(TagEntry)` with field-only reset (implemented)

**What was happening**

Every `capture-and-purge` iteration triggers two full-TagEntry zero-writes to shared memory:

1. `findOrCreateTag` in `cache-tags` — creates the per-request tag slot, zeroes the full `TagEntry` before setting two fields
2. `purgeByTag` / `remove_tag_at` — frees the tag slot, zeroes the full `TagEntry` before clearing `tag_used`

`TagEntry` is:
```
tag:       [64]u8            64 bytes
tag_len:   usize              8 bytes
uris:      [64][256]u8    16,384 bytes
uri_lens:  [64]usize         512 bytes
uri_count: usize               8 bytes
─────────────────────────── 16,976 bytes ≈ 16.6 KiB
```

Total store for 256 tags: 4.14 MiB.

Two zeroes per iteration × 16,976 bytes = ~33 KB of shm writes per request at 1525 RPS (c=1) = **~49 MB/s of pure zero-writes** to shared memory with no correctness purpose.

**Why it was safe to remove**

`tag_used[i]` is the authoritative gate: no code reads a `TagEntry` without first confirming `tag_used[i] == 1`. Fields in a dead slot (tag_used == 0) are never read until `findOrCreateTag` reuses the slot, at which point it overwrites the safety-critical fields before returning.

The only field that must be explicitly reset on slot *creation* is `uri_count`. If `uri_count` retains a stale non-zero value from the previous tenant:
- `addUriToTag` would skip all new URI additions (early-return on the capacity check)
- the tag would appear full immediately, breaking capture silently

The fix: set `entry.uri_count = 0` in `findOrCreateTag` (mandatory). Skip zeroing entirely in purge paths (safe because `tag_used = 0` gates the slot). The `uris` and `uri_lens` arrays never need zeroing because they are written before being read, bounded by `uri_count`.

**Files changed**

- `src/modules/cache-tags-nginx-module/ngx_http_cache_tags.zig`: `findOrCreateTag` (two call sites), `purgeByTag`
- `src/modules/cache-purge-nginx-module/ngx_http_cache_purge.zig`: `remove_tag_at`

**Measured gain — see `2026-05-09-zeroing-fix-results.md` for full data**

Hardware counters at c=32 (capture-and-purge, perf-stat run):

| metric | baseline | round4 | delta |
|---|---:|---:|---:|
| instr/req | 107,583 | 103,573 | -3.7% |
| cycles/req | 294,402 | 245,093 | **-16.7%** |
| IPC | 0.365 | 0.423 | **+15.9%** |
| cache miss/req | 233.4 | 224.8 | -3.7% |

The cycles/req improvement is 4.5× larger than the instruction-count improvement, as expected: the cost of zeroing 16.6 KB was primarily in pipeline stalls from uncached shm writes, not instruction count alone.

Throughput comparisons are noisier — all c=1 numbers were uniformly lower on the measurement session due to system-state differences unrelated to the code. See the results note for the full explanation.

---

## Angle 2 — Worker-events mode experiment (next benchmark to run)

The benchmark config does not set `cache_purge_worker_events_mode`, so it uses the default `per_target`. This means every successful purge writes a worker-events entry, which requires:
- acquiring the worker-events shm mutex
- copying ~640 bytes (channel + event_type + payload) into the ring
- releasing the mutex

That is a second `ngx_shmtx_lock` call per request cycle, separate from the cache-tags lock.

In the benchmark, every iteration uses a unique tag token. The purge always succeeds (the tag was just captured), so the event publish fires on every single iteration.

**Three modes to compare**

| mode | behaviour | shm lock per purge |
|---|---|---:|
| `per_target` (default) | one event per matched tag | 2 (cache-tags + events) |
| `summary` | one event per batch | 2 (cache-tags + events) |
| `off` | no event publish | 1 (cache-tags only) |

For single-target purges, `summary` and `per_target` are identical in cost. The meaningful comparison is `off` vs any publish mode.

**How to run the experiment**

Add `cache_purge_worker_events_mode off;` to the `/cache-purge` location in `run.js` and re-run the benchmark with a new artifact tag. Run the existing default config as the paired reference to isolate the event publication cost.

This experiment was already flagged in `2026-05-09-best-benchmarks.md` as the next recommended slice. The combo benchmark currently only exercises single-target purges, so the `per_target` / `summary` distinction is noise; the useful data point is the `off` baseline.

---

## Angle 3 — Compile-time TagEntry size reduction (documented opt-in)

**The problem**

Even after the zeroing fix, the `TagEntry` struct is 16.6 KiB. With 2-3 tags active in the benchmark at any moment, the working set for live tag entries is ~50 KB per worker. Under `c=8` with two workers sharing the store, this is already close to typical L2 sizes.

The root cause: `uris: [64][256]u8` is embedded inline in the struct. Most real deployments do not need 64 URIs per tag or 256-byte URIs.

**Proposed compile-time option**

Add `build.zig` options for `max_uris_per_tag` (default 64) and `max_uri_len` (default 256). Both `cache-tags` and `cache-purge` share the shm layout and must be compiled with the same values.

Reduced variant with `max_uris_per_tag=16`, `max_uri_len=128`:
- TagEntry: 2,256 bytes (2.2 KiB) — 7.5× smaller
- Full store (256 tags): 564 KiB — fits in L2/L3 comfortably
- At 1525 RPS, zeroing cost drops from 49 MB/s to ~6.5 MB/s (even before angle 1 fix)

**Tradeoffs**

- Changing these values changes the shm zone layout; requires a binary restart, not a live reload
- Both modules must be built consistently; this is a compile-time invariant, not a runtime check
- Tag names longer than `max_uri_len` bytes will be silently truncated (as today, only limited by `MAX_URI_LEN`)

This is the right option for deployments where operators know their URI space is compact. It is not appropriate as a default because reducing the URI cap changes observable behaviour (fewer URIs tracked before the cap is hit).

**Implementation sketch**

```zig
// build.zig option
const max_uris = b.option(u32, "max_uris_per_tag", "Max URIs per cache tag (default 64)") orelse 64;
const max_uri_len = b.option(u32, "max_uri_len", "Max URI length in bytes (default 256)") orelse 256;
// pass as build options to both cache-tags and cache-purge modules
```

The struct constants in both modules would then reference the build option rather than the hardcoded value. Both modules would fail to compile if they don't agree on the layout (enforced at build time by using the same option source).

---

## Angle 4 — Runtime URI tracking opt-out (`cache_tags_track_uris off`)

**Idea**

Add a `cache_tags_track_uris off` directive that disables URI storage entirely. The header filter still records tag → exists, but skips the `addUriToTag` step. The purge endpoint returns the tag count removed (1 or 0 per target), not the URI count.

**Why this is low-priority for the combo benchmark**

The benchmark uses unique per-request tag tokens (`bench-${Date.now()}-${iteration}`). Each token tag starts with `uri_count = 0`, so `addUriToTag` finds the slot empty and adds the URI immediately in O(1). The duplicate-check loop in `addUriToTag` iterates `0..uri_count` which is 0 at creation and 1 on the second call — but by then the iteration is already past and the tag is being purged. So `track_uris off` would save at most the memcpy of one URI per capture, not a loop scan.

The `combo` and `backend-a` tags that accumulate across iterations hit the URI cap after ~64 requests and then return early. That early-exit optimization was already implemented in the prior hardening round.

URI tracking opt-out would help most in workloads with high-cardinality, non-capping tag sets (many unique tags, each accumulating many URIs). That is not the current benchmark shape.

---

## What is not worth pursuing

**Further lock splitting or lock-free approaches**: The current perf profile shows 0 context switches and 0 CPU migrations. The shmtx cost is real but small relative to the instruction volume. The store is small enough that a spinlock is appropriate here.

**Index structures (hash map) for tag lookup**: With `tag_count` typically 2-3 and `active_seen` early-exit in the linear scan, the scan terminates in 2-3 iterations. Building and maintaining a hash structure in shared memory would add write cost on every mutation and is not justified for this cardinality.

**JSON body parsing optimization**: The fast-path parser (`try_parse_single_target_fast`) already handles single-target exact purges without cJSON allocation. The benchmark always hits this path. Multi-target batches still go through cJSON, but multi-target is not a combo benchmark scenario.

**Async event publish**: Worker-events publish is synchronous (holds the events mutex inline). Making it async would require a per-worker queue and a separate event loop integration, which is substantial complexity for an operation that is already bounded by a single fixed-size ring write.

---

## Priority ordering for next steps

1. Run benchmark with angle-1 fix and record new best results to verify the zeroing improvement
2. Run `worker_events_mode off` slice to measure the event-publication cost (pure config change)
3. If that shows significant savings, document `off` as the recommended default for single-worker or low-churn deployments
4. Implement angle-3 compile-time size option only if the store working set shows up as a meaningful L2/L3 pressure in a future `perf record` run
