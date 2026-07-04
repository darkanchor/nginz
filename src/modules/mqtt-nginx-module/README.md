# MQTT Stream Module

Native nginx stream module scaffold for MQTT-aware routing and CONNECT-message
rewrite. The intended feature surface mirrors the commercial NGINX Plus MQTT
stream modules while keeping the implementation in nginz/Zig.

## Status

**Current MQTT module design implemented.**

Implemented:

- Stream module plumbing for two exported modules:
  - `ngx_stream_mqtt_preread_module`
  - `ngx_stream_mqtt_filter_module`
- `mqtt_preread` directive in `stream` and `server` contexts.
- `$mqtt_preread_clientid` and `$mqtt_preread_username` variable registration.
- Preread phase hook installation.
- `mqtt` directive in `stream` and `server` contexts.
- `mqtt_set_connect` directive parsing for `clientid`, `username`, and
  `password`.
- Stream filter hook installation.
- Static nginz registration, package metadata, and dynmod eligibility.
- Bounds-checked MQTT CONNECT parser for MQTT 3.1.1 and MQTT 5.0.
- Preread population for `$mqtt_preread_clientid` and
  `$mqtt_preread_username`.
- Client-to-upstream CONNECT rewrite with buffering for split CONNECT packets.
- Minimal TCP MQTT mock and packet helpers for stream integration tests.
- Runtime stream proxy test that captures rewritten CONNECT fields at a mock
  broker.
- Runtime rewrite matrix coverage for adding, replacing, and removing
  username/password fields.
- Malformed CONNECT runtime behavior for preread-only and rewrite-enabled modes.
- Split CONNECT runtime behavior for preread-only variable extraction.
- Runtime MQTT 5 broker-proxy coverage with CONNECT properties.
- TLS-terminated MQTT stream config and runtime coverage.
- Phase 5 hardening guardrails: fuzz-like parser coverage, checked parser and
  rewrite arithmetic, explicit rewrite buffer limit, and malformed/overflow
  logging.

Not implemented yet:

- Broker-specific authentication/authorization.
- MQTT packet inspection beyond the initial CONNECT packet.
- MQTTS passthrough inspection without nginx stream SSL termination.

The implementation is still conservative: preread parsing is usable for stream
routing, and rewrite is covered for split CONNECT frames and the main
username/password mutation cases. Remaining work is compatibility expansion
outside the current module scope rather than core CONNECT parsing/rewrite
mechanics.

## Purpose and Boundaries

The module should provide the OSS nginz equivalent of the NGINX Plus MQTT stream
features:

1. Extract MQTT CONNECT identity fields during the stream preread phase.
2. Expose those fields as nginx stream variables usable by `hash`, `map`, logs,
   and `proxy_pass` variable expressions.
3. Rewrite selected fields in the first CONNECT packet before forwarding to the
   broker.
4. Preserve raw stream proxying semantics for all subsequent packets.
5. Fail closed on malformed CONNECT packets when rewrite is enabled, and fail
   soft for preread-only routing when the CONNECT packet is incomplete within the
   preread buffer.

This module should own:

- MQTT CONNECT packet parsing in the stream preread path
- MQTT identity variables exposed to stream routing and logging
- CONNECT-only rewrite of `clientid`, `username`, and `password`
- parser/rewrite failure policy and guardrail tests

This module should **not** own:

- broker behavior, subscriptions, retain state, QoS state, or message fanout
- upstream peer table mutation
- peer health checks
- service discovery
- TLS implementation
- broker authentication policy beyond optional CONNECT field rewrite

In plain terms: nginx still owns TCP proxying and upstream selection, the broker
still owns MQTT semantics after CONNECT, and this module only makes the initial
MQTT CONNECT packet visible and optionally rewritable inside the stream pipeline.

## Current Behavior

- `mqtt_preread on|off` is accepted in `stream` and `server` contexts.
- `mqtt on|off` is accepted in `stream` and `server` contexts.
- `mqtt_set_connect clientid|username|password <value>` is accepted in `server`
  context and rejects unsupported fields at config load.
- `$mqtt_preread_clientid` and `$mqtt_preread_username` are registered as stream
  variables.
- The preread module installs a stream preread phase handler.
- The filter module wraps the stream top filter and rewrites the first complete
  client-to-upstream CONNECT frame when `mqtt on;` and `mqtt_set_connect` are
  configured.
- Build, static registration, package metadata, and nginx config fixtures are
  wired.
- The rewrite implementation buffers split CONNECT packets until the first full
  frame is available.

## Current Test Coverage

`tests/mqtt/mqtt.test.js` currently proves:

- MQTT fixture files exist under `tests/mqtt/`
- `nginx -t` accepts a valid stream config using `mqtt_preread`, `mqtt`,
  `mqtt_set_connect`, `upstream`, `hash`, and `proxy_pass`
- unsupported `mqtt_set_connect` fields fail config testing
- a live stream `return $mqtt_preread_username` fixture returns the username from
  a real MQTT 3.1.1 CONNECT packet
- repeated MQTT 3.1.1 CONNECT packets with the same client ID route to the same
  stream upstream peer when the upstream uses `hash $mqtt_preread_clientid
  consistent`
- the mock broker observes rewritten `clientid`, `username`, and `password`
  values while returning an unchanged MQTT CONNACK to the client
- split CONNECT packets are buffered and rewritten before proxying
- username/password add, replace, and remove cases update payload fields and
  CONNECT flags as expected
- malformed preread-only CONNECT leaves variables not found
- malformed rewrite-enabled CONNECT fails closed before the mock broker observes
  a CONNECT
- MQTT 5 CONNECT packets with non-empty CONNECT properties are proxied and
  rewritten
- TLS-terminated MQTT streams are decrypted by nginx before MQTT preread and
  rewrite
- split CONNECT packets in preread-only mode return `NGX_AGAIN` until enough
  bytes arrive to populate variables
- the MQTT Zig module is included in `build.zig`
- both exported MQTT stream modules are registered in `src/ngz_modules.zig`
- package metadata marks both MQTT modules as `STREAM`

Zig unit tests in `ngx_stream_mqtt.zig` cover MQTT remaining-length parsing,
MQTT 3.1.1 CONNECT extraction, MQTT 5 CONNECT extraction, incomplete frames,
invalid packet types, invalid CONNECT flags, and malformed variable-byte
remaining lengths. They also cover the CONNECT rewrite frame builder, including
client ID replacement, username replacement, password addition, remaining-length
re-encoding, CONNECT flag updates, auth-field edge cases, and byte-for-byte
preservation of MQTT 5 CONNECT properties and Will fields.

The current module design is implemented; production rollout should still include
site-specific broker compatibility and operational testing.

## Example Configuration

Sticky routing by MQTT client ID:

```nginx
stream {
    upstream mqtt_brokers {
        hash $mqtt_preread_clientid consistent;
        server 127.0.0.1:1884;
        server 127.0.0.1:1885;
    }

    server {
        listen 1883;
        mqtt_preread on;
        proxy_pass mqtt_brokers;
    }
}
```

CONNECT rewrite before broker proxying:

```nginx
stream {
    server {
        listen 1883;
        proxy_pass 127.0.0.1:1884;

        mqtt on;
        mqtt_set_connect clientid "$mqtt_preread_clientid:$remote_addr";
        mqtt_set_connect username "$mqtt_preread_username";
        mqtt_set_connect password "broker-local-secret";
    }
}
```

Preread and rewrite can be enabled together:

```nginx
stream {
    upstream mqtt_brokers {
        hash $mqtt_preread_username consistent;
        server 127.0.0.1:1884;
        server 127.0.0.1:1885;
    }

    server {
        listen 1883;
        mqtt_preread on;
        mqtt on;
        mqtt_set_connect username "$mqtt_preread_username@edge-a";
        proxy_pass mqtt_brokers;
    }
}
```

## Directives

| Directive | Syntax | Context | Purpose |
|---|---|---|---|
| `mqtt_preread` | `on \| off` | `stream`, `server` | Parse initial CONNECT during preread and populate MQTT identity variables |
| `mqtt` | `on \| off` | `stream`, `server` | Enable client-to-upstream CONNECT filtering and rewrite support |
| `mqtt_set_connect` | `<clientid\|username\|password> <value>` | `server` | Configure CONNECT field rewrite using a stream complex value |

### mqtt_preread

```nginx
mqtt_preread on | off;
```

Default: `off`

Context: `stream`, `server`

Enables parsing of the MQTT CONNECT packet in the stream preread phase. The
parser will extract `clientid` and `username` and make them available through
stream variables before upstream peer selection.

### mqtt

```nginx
mqtt on | off;
```

Default: `off`

Context: `stream`, `server`

Enables MQTT-aware stream filtering for a server. When enabled, the filter will
inspect client-to-upstream traffic and may rewrite the first CONNECT packet
according to `mqtt_set_connect` directives.

### mqtt_set_connect

```nginx
mqtt_set_connect field value;
```

Default: none

Context: `server`

Supported fields:

- `clientid`
- `username`
- `password`

`value` is compiled as an nginx stream complex value, so it can contain literal
text, variables, or both. Multiple directives can be configured in the same
server block.

## Embedded Variables

### $mqtt_preread_clientid

The MQTT CONNECT Client Identifier.

When parsing fails, the packet is not CONNECT, or the field is absent, the
variable is marked not found.

### $mqtt_preread_username

The MQTT CONNECT username.

MQTT 3.1.1 and MQTT 5 encode username only when the username flag is set in the
CONNECT flags byte. When the field is absent, the variable is marked not found.

## MQTT Packet Scope

First implementation target:

- MQTT 3.1.1 CONNECT
- MQTT 5.0 CONNECT
- TCP stream transport
- First packet only

Out of scope for the first implementation:

- MQTT 3.1 legacy protocol name `MQIsdp`
- WebSocket MQTT
- UDP
- Rewriting packets after CONNECT
- Full MQTT validation beyond what is needed to safely parse and rewrite CONNECT

## Architecture

The module is one Zig source file exporting two nginx stream modules.

### Preread Module

`ngx_stream_mqtt_preread_module` owns:

- `mqtt_preread`
- `$mqtt_preread_clientid`
- `$mqtt_preread_username`
- preread phase handler registration
- per-session parsed identity context

The preread handler reads from `s->connection->buffer`, which nginx stream core
fills during the preread phase. It must not consume bytes. It should return:

- `NGX_OK` when CONNECT was parsed or a terminal non-MQTT decision was made.
- `NGX_AGAIN` when more preread bytes are needed.
- `NGX_DECLINED` when disabled.
- `NGX_ERROR` for allocation or parser safety failures.

The parser stores slices copied into the connection pool. Variables should never
point at transient preread buffer memory unless the buffer lifetime is proven
stable for the full session.

### Filter Module

`ngx_stream_mqtt_filter_module` owns:

- `mqtt`
- `mqtt_set_connect`
- stream filter registration
- client-to-upstream CONNECT rewrite

The filter is inserted after `ngx_stream_write_filter_module` in
`src/ngz_modules.zig`, so its `postconfiguration` wraps the built-in writer:

```text
ngx_stream_top_filter -> mqtt_filter -> write_filter
```

The filter only acts on `from_upstream == 0`, which is client-to-broker traffic
in `ngx_stream_proxy_module`. Server-to-client traffic is passed through
unchanged.

The filter must rewrite at most one packet: the initial CONNECT packet. After
that, it should mark the session as pass-through and delegate directly to the
next filter.

## CONNECT Parser Design

MQTT fixed header:

```text
byte 0     packet type and flags
byte 1..4  remaining length, MQTT variable-byte integer
```

For CONNECT, byte 0 must be `0x10`. Remaining length may use one to four bytes.
The complete frame length is:

```text
1 + encoded_remaining_length_width + remaining_length
```

Variable header:

```text
protocol name      UTF-8 string
protocol level     u8
connect flags      u8
keep alive         u16
properties         MQTT 5 only, variable-byte integer + bytes
```

Payload order:

```text
clientid           UTF-8 string, always present
will properties    MQTT 5 only, when will flag set
will topic         when will flag set
will payload       when will flag set
username           when username flag set
password           when password flag set
```

The parser should return a compact `ConnectView` containing offsets and lengths
inside the complete CONNECT frame:

```zig
const ConnectView = struct {
    version: enum { v311, v5 },
    frame_len: usize,
    remaining_len: usize,
    remaining_len_width: usize,
    connect_flags_offset: usize,
    clientid: FieldRef,
    username: ?FieldRef,
    password: ?FieldRef,
};
```

`FieldRef` points to the two-byte length prefix and payload:

```zig
const FieldRef = struct {
    len_offset: usize,
    value_offset: usize,
    value_len: usize,
};
```

Parser safety rules:

- Reject malformed remaining-length encodings.
- Reject CONNECT flags with reserved bit set.
- Reject invalid packet type.
- Reject truncated two-byte strings.
- Reject frames larger than configured stream preread capacity for preread.
- Reject rewritten frames that exceed configured rewrite buffer capacity.
- Use checked arithmetic for every offset and length calculation.

UTF-8 validation can be deferred. MQTT brokers often enforce their own UTF-8
policy, and this module only needs safe field extraction and rewriting.

## Rewrite Design

The filter should collect enough client-to-upstream bytes to cover the first
CONNECT frame. It then builds a replacement CONNECT frame in the connection pool:

1. Copy fixed header packet type.
2. Decode original remaining length and parse `ConnectView`.
3. Evaluate each configured `mqtt_set_connect` complex value.
4. Compute length delta for `clientid`, `username`, and `password`.
5. Update CONNECT flags if username/password fields are added or removed.
6. Re-encode MQTT remaining length.
7. Copy unchanged spans from the original frame and substitute rewritten fields.
8. Forward the rewritten frame plus any trailing bytes already received.

Client ID handling:

- `clientid` is always present in MQTT 3.1.1 and 5 CONNECT payload.
- Rewriting it changes only the two-byte field length and payload bytes.

Username/password handling:

- If a field is present and the rewritten value is non-empty, replace it.
- If a field is present and the rewritten value is empty, remove it and clear the
  corresponding CONNECT flag.
- If a field is absent and the rewritten value is non-empty, append it in MQTT
  payload order and set the corresponding CONNECT flag.
- If both username and password are added, username must precede password.

The filter should not mutate nginx buffers in place. It should allocate a new
temporary buffer for the rewritten CONNECT frame and pass through the rest of the
chain unchanged when possible.

## Stream Upstream and Routing Contract

This module is a routing signal producer, not an upstream manager.

The currently supported upstream integration is nginx stream upstream selection
using MQTT preread variables:

```nginx
stream {
    mqtt_preread on;

    upstream mqtt_brokers {
        zone mqtt_brokers 256k;
        hash $mqtt_preread_clientid consistent;

        server 10.0.0.11:1883;
        server 10.0.0.12:1883;
    }

    server {
        listen 1883;
        proxy_pass mqtt_brokers;
    }
}
```

The stream upstream module or nginx core stream upstream code owns:

- peer membership
- peer health and draining
- snapshot activation
- consistent-hash ring construction
- retry and failover behavior

The MQTT module owns only the variable values that the stream upstream selector
may consume.

Important current-repo boundary: `dynamic-upstreams` is an **HTTP upstream**
module today. It is implemented as `ngx_http_dynamic_upstreams_module`, its API
lives in HTTP `location` context, and its peer-source handoff targets
`ngx_http_upstream_srv_conf_t` / `ngx_http_upstream_rr_peers_t`. It does not
currently manage `stream { upstream ... }` groups and cannot directly mutate the
MQTT broker upstream list.

To make runtime broker membership updates work for MQTT stream traffic, nginz
would need a separate stream-side dynamic upstream implementation or a shared
HTTP/stream peer-store abstraction with stream-specific adapters. That future
work would need to target `ngx_stream_upstream_srv_conf_t` and
`ngx_stream_upstream_rr_peers_t`, and it would need stream peer-source hooks
equivalent to the current HTTP `upstream-balancer` / `dynamic-upstreams`
contract.

That stream dynamic-upstream work is outside this MQTT module's current design
scope. MQTT contributes stable preread variables; stream upstream membership and
peer snapshots belong to stream upstream infrastructure.

Required behavior:

- Variables must be available before stream upstream peer selection begins.
- For a valid CONNECT with the same `clientid`, consistent hash routing must see
  a stable byte-for-byte variable value across repeated connections.
- If parsing fails in preread-only mode, variables are marked not found; routing
  then follows the configured nginx behavior for an empty/not-found variable.
- When `mqtt_set_connect clientid ...` rewrites the client ID, routing still uses
  the preread value seen before upstream selection unless the config explicitly
  hashes another variable. The rewrite path must not retroactively change the
  selected upstream.

## TLS Boundary

TLS is delegated to nginx stream SSL, matching the existing stream-module
pattern used elsewhere in this repo.

Supported deployment:

```nginx
stream {
    server {
        listen 8883 ssl;
        ssl_certificate     certs/server.crt;
        ssl_certificate_key certs/server.key;

        mqtt_preread on;
        mqtt on;
        proxy_pass mqtt_brokers;
    }
}
```

In that deployment, nginx stream SSL terminates TLS first and the MQTT module
sees plaintext MQTT bytes after handshake completion.

Not supported by this module:

- implementing TLS handshakes directly
- inspecting MQTT over TLS passthrough where nginx does not decrypt the stream
- rewriting encrypted CONNECT packets without stream SSL termination

Operationally, MQTTS passthrough can still be proxied by nginx, but
`mqtt_preread` variables and `mqtt_set_connect` rewrite cannot work because the
CONNECT packet is encrypted.

## Configuration Merge Rules

Expected merge behavior:

- `mqtt_preread` defaults to `off` and inherits from `stream` to `server`.
- `mqtt` defaults to `off` and inherits from `stream` to `server`.
- `mqtt_set_connect` is server-only. If a child server has no rewrite directives,
  it inherits parent rewrite directives.

## Failure Policy

Preread-only mode:

- Incomplete CONNECT: return `NGX_AGAIN` until stream preread timeout or buffer
  limit.
- Malformed CONNECT: variables become not found; proxying may continue.

Rewrite mode:

- Malformed CONNECT: fail the session.
- Rewrite buffer overflow: fail the session. The current client-to-upstream
  rewrite buffer limit is 1 MiB.
- Complex value evaluation failure: fail the session.

This split keeps routing useful for imperfect clients while ensuring the module
does not forward a partially rewritten or ambiguous CONNECT packet.

## Testing Plan

Unit tests:

- Remaining-length decoder: one to four byte encodings, malformed continuation,
  overflow, incomplete.
- MQTT UTF-8 string bounds parser.
- CONNECT parser for MQTT 3.1.1 and 5.0.
- Deterministic fuzz-like parser coverage for random truncated and malformed
  frames.
- Optional username/password and will-field skipping.
- Checked arithmetic for parser cursor movement, MQTT remaining-length math,
  rewrite length deltas, and output offsets.
- Explicit rewrite buffer-limit checks.
- Rewriter length-delta cases:
  - same-length clientid
  - longer clientid
  - shorter clientid
  - add username
  - remove username
  - add password
  - remove password
  - add both username and password
- Remaining-length re-encoding after rewrite.

Integration tests:

- `nginx -t` accepts `mqtt_preread on;`.
- `nginx -t` accepts `mqtt on;` and `mqtt_set_connect`.
- `nginx -t` accepts stream SSL config with MQTT directives when certificates
  are present.
- `hash $mqtt_preread_clientid consistent;` routes repeat connections to the
  same backend.
- `$mqtt_preread_username` is available in stream logs.
- Split preread CONNECT packets wait for enough bytes before variables resolve.
- Backend receives rewritten CONNECT fields.
- Non-CONNECT first packet is passed through when only preread is enabled.
- Malformed CONNECT closes when rewrite is enabled.
- Malformed rewrite failures emit clear stream error-log messages.
- TLS passthrough bytes are not interpreted as MQTT when nginx does not
  terminate TLS before MQTT preread.

Manual compatibility tests:

- Mosquitto client against a Mosquitto backend.
- MQTT 5 client with properties preserved.
- TLS termination in nginx stream SSL before MQTT parsing.
- MQTTS passthrough through a stream proxy without MQTT preread or rewrite.

## Traceability and Audit Hooks

| Requirement / claim | Evidence |
|---|---|
| Directives parse in stream config | `tests/mqtt/mqtt.test.js` valid fixture |
| Unsupported rewrite fields fail config load | `tests/mqtt/nginx-invalid-field.conf` + negative test |
| Both MQTT modules are stream modules in package metadata | `tests/mqtt/mqtt.test.js` package assertions |
| Module registration includes preread and filter exports | `tests/mqtt/mqtt.test.js` registration assertions |
| Preread variables are known to nginx | Runtime `return $mqtt_preread_username` test |
| CONNECT parser is bounds-safe | Zig unit tests for truncated and malformed packets |
| Rewrite preserves MQTT frame structure | Zig rewrite unit tests + backend mock field assertions |
| TLS is nginx-owned, not module-owned | README TLS boundary + `tests/mqtt/nginx-tls.conf` runtime fixture + TLS passthrough negative test |
| Parser malformed-input handling is bounded | Deterministic fuzz-like Zig parser test |
| Rewrite buffer limit is explicit | `MQTT_REWRITE_BUFFER_LIMIT` Zig test |
| Malformed rewrite failures are logged | Runtime malformed rewrite error-log assertion |

## Implementation Phases

### Phase 1 - Scaffold

Complete.

Exit criteria:

- [x] Module source compiles.
- [x] Exported modules are registered as `NGX_STREAM_MODULE`.
- [x] Directives parse in nginx config.
- [x] Variables are known to nginx.
- [x] Hooks are installed but pass traffic unchanged.
- [x] Package metadata exposes both modules as stream modules.
- [x] MQTT config fixtures live under `tests/mqtt/`.

### Phase 2 - Preread Parser

Implement CONNECT parser and variable population.

Exit criteria:

- [x] `$mqtt_preread_clientid` parser support works for MQTT 3.1.1.
- [x] `$mqtt_preread_username` parser support works for MQTT 3.1.1.
- [x] `$mqtt_preread_clientid` parser support works for MQTT 5.
- [x] `$mqtt_preread_username` parser support works for MQTT 5.
- [x] Live stream preread variable test covers MQTT 3.1.1 username extraction.
- [x] Hash routing by client ID is covered by integration tests.
- [x] Incomplete packet handling is bounded and returns `NGX_AGAIN` correctly.
- [x] Malformed CONNECT in preread-only mode marks variables not found without
  crashing or mutating stream buffers.

### Phase 3 - CONNECT Rewrite

Implement client-to-upstream filter rewrite.

Exit criteria:

- [x] `mqtt_set_connect clientid` rewrites the field.
- [x] `mqtt_set_connect username` adds, replaces, and removes the field.
- [x] `mqtt_set_connect password` adds, replaces, and removes the field.
- [x] MQTT remaining length is re-encoded correctly after size changes.
- [x] CONNECT flags are updated correctly when username/password are added or
  removed.
- [x] MQTT 5 properties and will fields are preserved byte-for-byte.
- [x] Backend test harness observes modified CONNECT packets.
- [x] Server-to-client packets are passed through unchanged.
- [x] Split CONNECT packets are buffered until the full frame is available or a
  bounded failure policy applies.

### Phase 5 - Hardening

Add production guardrails.

Exit criteria:

- [x] Fuzz-like parser tests for truncated and malformed packets.
- [x] Clear error logging for malformed CONNECT and rewrite overflow.
- [x] Parser and rewrite paths use checked arithmetic for every offset and
  length.
- [x] Rewrite buffer limits are explicit and test-backed.
- [x] README limitations reflect remaining unsupported MQTT features.

## Limitations

- The design targets TCP stream proxying.
- TLS inspection requires nginx stream SSL termination before MQTT parsing.
- Runtime MQTT 5 coverage includes CONNECT properties. Will-field preservation
  is currently covered at Zig unit level.
- Only the initial CONNECT packet is parsed and optionally rewritten. Publish,
  subscribe, ping, disconnect, and server-to-client packets are passed through.
- CONNECT rewrite is limited to `clientid`, `username`, and `password`.
- Client-to-upstream rewrite buffering is capped at 1 MiB.
- No broker-specific authentication or authorization is planned here; credential
  semantics should remain in upstream broker policy or a separate auth module.

## Source References

- NGINX stream MQTT preread module documentation:
  `https://nginx.org/en/docs/stream/ngx_stream_mqtt_preread_module.html`
- NGINX stream MQTT filter module documentation:
  `https://nginx.org/en/docs/stream/ngx_stream_mqtt_filter_module.html`
- MQTT 3.1.1 specification:
  `https://docs.oasis-open.org/mqtt/mqtt/v3.1.1/`
- MQTT 5.0 specification:
  `https://docs.oasis-open.org/mqtt/mqtt/v5.0/`
