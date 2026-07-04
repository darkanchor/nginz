# MQTT Stream Module

Native nginx stream module scaffold for MQTT-aware routing and CONNECT-message
rewrite. The intended feature surface mirrors the commercial NGINX Plus MQTT
stream modules while keeping the implementation in nginz/Zig.

## Status

**Scaffolded, not feature-ready.**

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

Not implemented yet:

- MQTT CONNECT parser.
- Population of `$mqtt_preread_clientid` and `$mqtt_preread_username`.
- CONNECT rewrite in the stream filter.
- MQTT 5 property preservation tests.
- Integration tests against a broker or TCP harness.

The scaffold is intentionally conservative: enabled directives should not change
traffic behavior until the parser and rewriter land.

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
- The filter module wraps the stream top filter and currently passes chains
  through unchanged.
- Build, static registration, package metadata, and nginx config fixtures are
  wired.
- The CONNECT parser and rewriter are not implemented yet; variables are not
  populated and traffic is not modified.

## Current Test Coverage

`tests/mqtt/mqtt.test.js` currently proves:

- MQTT fixture files exist under `tests/mqtt/`
- `nginx -t` accepts a valid stream config using `mqtt_preread`, `mqtt`,
  `mqtt_set_connect`, `upstream`, `hash`, and `proxy_pass`
- unsupported `mqtt_set_connect` fields fail config testing
- the MQTT Zig module is included in `build.zig`
- both exported MQTT stream modules are registered in `src/ngz_modules.zig`
- package metadata marks both MQTT modules as `STREAM`

The current tests are configuration and registration guardrails only. Runtime
MQTT packet tests are exit criteria for parser and rewrite phases.

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

## Dynamic Upstream and Routing Contract

This module is a routing signal producer, not an upstream manager.

The intended dynamic-upstream integration is:

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

The upstream module, dynamic-upstreams module, or nginx core upstream code owns:

- peer membership
- peer health and draining
- snapshot activation
- consistent-hash ring construction
- retry and failover behavior

The MQTT module owns only the variable values that the stream upstream selector
may consume.

Required behavior:

- Variables must be available before stream upstream peer selection begins.
- For a valid CONNECT with the same `clientid`, consistent hash routing must see
  a stable byte-for-byte variable value across repeated connections.
- If parsing fails in preread-only mode, variables are marked not found; routing
  then follows the configured nginx behavior for an empty/not-found variable.
- Dynamic upstream membership changes may move clients according to the upstream
  module's own consistent-hash semantics. The MQTT module must not cache selected
  peers or depend on a specific upstream generation.
- When `mqtt_set_connect clientid ...` rewrites the client ID, routing still uses
  the preread value seen before upstream selection unless the config explicitly
  hashes another variable. The rewrite path must not retroactively change the
  selected upstream.

Traceability with `dynamic-upstreams`:

| Requirement / claim | Evidence |
|---|---|
| MQTT variables are used only as routing inputs, not peer-table state | MQTT README boundary + stream config fixtures |
| Dynamic peer snapshots remain owned by `dynamic-upstreams` / balancer modules | `src/modules/dynamic-upstreams-nginx-module/README.md` |
| Sticky MQTT routing works across repeated connections | Future runtime test: same clientid reaches same backend with unchanged upstream generation |
| Dynamic peer updates do not require MQTT module state migration | Future integration test with updated peer generation and no MQTT session-cache dependency |

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
- Rewrite buffer overflow: fail the session.
- Complex value evaluation failure: fail the session.

This split keeps routing useful for imperfect clients while ensuring the module
does not forward a partially rewritten or ambiguous CONNECT packet.

## Testing Plan

Unit tests:

- Remaining-length decoder: one to four byte encodings, malformed continuation,
  overflow, incomplete.
- MQTT UTF-8 string bounds parser.
- CONNECT parser for MQTT 3.1.1 and 5.0.
- Optional username/password and will-field skipping.
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
- Backend receives rewritten CONNECT fields.
- Non-CONNECT first packet is passed through when only preread is enabled.
- Malformed CONNECT closes when rewrite is enabled.
- Dynamic upstream generation changes do not require MQTT session state and do
  not crash active or new MQTT connections.

Manual compatibility tests:

- Mosquitto client against a Mosquitto backend.
- MQTT 5 client with properties preserved.
- TLS termination in nginx stream SSL before MQTT parsing.

## Traceability and Audit Hooks

| Requirement / claim | Evidence |
|---|---|
| Directives parse in stream config | `tests/mqtt/mqtt.test.js` valid fixture |
| Unsupported rewrite fields fail config load | `tests/mqtt/nginx-invalid-field.conf` + negative test |
| Both MQTT modules are stream modules in package metadata | `tests/mqtt/mqtt.test.js` package assertions |
| Module registration includes preread and filter exports | `tests/mqtt/mqtt.test.js` registration assertions |
| Preread variables are known to nginx | Current source registration; future runtime variable test |
| CONNECT parser is bounds-safe | Future Zig unit tests for truncated and malformed packets |
| Rewrite preserves MQTT frame structure | Future backend harness tests comparing parsed CONNECT fields |
| TLS is nginx-owned, not module-owned | README TLS boundary + future stream SSL config fixture |

## Implementation Phases

### Phase 1 - Scaffold

Current state: mostly complete.

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

- [ ] `$mqtt_preread_clientid` works for MQTT 3.1.1.
- [ ] `$mqtt_preread_username` works for MQTT 3.1.1.
- [ ] `$mqtt_preread_clientid` works for MQTT 5.
- [ ] `$mqtt_preread_username` works for MQTT 5.
- [ ] Hash routing by client ID is covered by integration tests.
- [ ] Incomplete packet handling is bounded and returns `NGX_AGAIN` correctly.
- [ ] Malformed CONNECT in preread-only mode marks variables not found without
  crashing or mutating stream buffers.

### Phase 3 - CONNECT Rewrite

Implement client-to-upstream filter rewrite.

Exit criteria:

- [ ] `mqtt_set_connect clientid` rewrites the field.
- [ ] `mqtt_set_connect username` adds, replaces, and removes the field.
- [ ] `mqtt_set_connect password` adds, replaces, and removes the field.
- [ ] MQTT remaining length is re-encoded correctly after size changes.
- [ ] CONNECT flags are updated correctly when username/password are added or
  removed.
- [ ] MQTT 5 properties and will fields are preserved byte-for-byte.
- [ ] Backend test harness observes modified CONNECT packets.
- [ ] Server-to-client packets are passed through unchanged.

### Phase 4 - TLS and Dynamic-Upstream Integration

Prove the module behaves correctly at nginx integration boundaries.

Exit criteria:

- [ ] TLS-terminated MQTT config passes `nginx -t` with stream SSL enabled.
- [ ] TLS-terminated runtime test proves MQTT variables are populated after
  nginx decrypts the stream.
- [ ] TLS passthrough limitation is covered by a negative or documented manual
  test.
- [ ] Dynamic-upstream membership changes do not require MQTT state migration.
- [ ] Repeated client IDs preserve routing stability across unchanged upstream
  generations.

### Phase 5 - Hardening

Add production guardrails.

Exit criteria:

- [ ] Fuzz-like parser tests for truncated and malformed packets.
- [ ] Clear error logging for malformed CONNECT and rewrite overflow.
- [ ] Parser and rewrite paths use checked arithmetic for every offset and
  length.
- [ ] Rewrite buffer limits are explicit and test-backed.
- [ ] README limitations reflect remaining unsupported MQTT features.

## Limitations

- This module is a scaffold and currently does not parse or rewrite MQTT packets.
- The design targets TCP stream proxying.
- TLS inspection requires nginx stream SSL termination before MQTT parsing.
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
