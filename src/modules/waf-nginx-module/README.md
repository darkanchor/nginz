## Web Application Firewall Module

Native web application firewall for nginx with SQL injection and XSS attack detection.

### Status

**Implemented** - Native SQLi/XSS detection, libinjection-backed checks, and a small file-driven ModSecurity-like subset

### Features

- **SQL Injection Detection**: Pattern-based SQLi detection covering:
  - Comment-based attacks (`'--`, `/*`, `*/`)
  - Boolean-based attacks (`' or 1=1`, `or '1'='1`)
  - Union-based attacks (`union select`)
  - Keyword-based attacks (`select`, `insert`, `update`, `delete`, `drop`)
  - Time-based attacks (`sleep(`, `waitfor delay`, `benchmark(`)

- **XSS Detection**: Cross-site scripting attack prevention covering:
  - Script tags (`<script>`, `</script>`)
  - JavaScript/VBScript protocols (`javascript:`, `vbscript:`)
  - Event handlers (`onerror=`, `onclick=`, `onload=`, etc.)
  - DOM manipulation (`document.cookie`, `document.write`, `.innerhtml`)
  - Script functions (`alert(`, `eval(`, `prompt(`)
  - HTML injection vectors (`<img`, `<svg`, `<iframe`, etc.)

- **URL Decoding**: Automatically decodes URL-encoded payloads (`%27` → `'`)
- **Case Insensitive**: Matches patterns regardless of case
- **libinjection Integration**: Uses vendored `libinjection` for stronger SQLi and XSS detection before falling back to native substring signatures
- **Request Body Inspection**: Optional scanning of POST/PUT/PATCH request bodies
- **Modes**: Detection-only (log) or prevention (block) mode

### Directives

#### waf

*syntax:* `waf on|off;`
*default:* `waf off;`
*context:* `location`

Enable or disable the WAF for this location.

#### waf_mode

*syntax:* `waf_mode detect|block;`
*default:* `waf_mode block;`
*context:* `location`

WAF operation mode:
- `detect`: Log attacks but allow requests to pass
- `block`: Block requests and return 403 Forbidden with JSON error

#### waf_sqli

*syntax:* `waf_sqli on|off;`
*default:* `waf_sqli on;`
*context:* `location`

Enable or disable SQL injection detection.

#### waf_xss

*syntax:* `waf_xss on|off;`
*default:* `waf_xss on;`
*context:* `location`

Enable or disable XSS detection.

#### waf_check_body

*syntax:* `waf_check_body on|off;`
*default:* `waf_check_body off;`
*context:* `location`

Enable request body inspection for POST/PUT/PATCH requests.

#### waf_rules_file

*syntax:* `waf_rules_file <path>;`
*default:* none
*context:* `location`

Load a native ModSecurity-like rule file at config load time.

Current supported subset:

- one rule per line starting with `SecRule`
- targets: `REQUEST_URI`, `ARGS`, `QUERY_STRING`, `REQUEST_LINE`, `REQUEST_PROTOCOL`, `REQUEST_SCHEME`, `REQUEST_BASENAME`, `REQUEST_EXT`, `REQUEST_BODY`, `REQUEST_HEADERS`, `REQUEST_HEADER_NAMES`, `REQUEST_COOKIES`, `REQUEST_METHOD`, `REMOTE_ADDR`, `RESPONSE_STATUS`, `RESPONSE_HEADERS`
- scoped selectors on:
  - `ARGS:name`
  - `REQUEST_BODY:name`
  - `REQUEST_HEADERS:Header-Name`
  - `REQUEST_COOKIES:cookie_name`
  - `RESPONSE_HEADERS:Header-Name`
- operators:
  - `@contains <needle>`
  - `@pm <space-delimited phrases>`
  - `@strmatch <needle>`
  - `@within <space-delimited values>`
  - `@lt <number>` / `@le <number>` / `@gt <number>` / `@ge <number>`
  - `@ipMatch <ip-or-cidr ...>`
  - `@ipMatchFromFile <local-files...>`
  - `@containsWord <needle>`
  - `@noMatch` / `@unconditionalMatch`
  - `@validateUrlEncoding`
  - `@validateUtf8Encoding`
  - `@pmFromFile <local-files...>`
  - `@beginsWith <value>`
  - `@endsWith <value>`
  - `@streq <value>` / `@eq <value>`
  - `@rx <pattern>`
  - `@libinjection_sqli`
  - `@libinjection_xss`
- actions subset: `id:<n>`, `phase:1|2|3`, `msg:'...'`, `tag:'...'`, `logdata:'...'`, `severity:'critical|error|warning|notice'`, `score:<n>`, `setvar:ip.score=+<n>`, `deny`, `block`, `pass`, `allow`, `log`, `nolog`, `t:none`, `t:lowercase`, `t:urlDecode`, `t:urlDecodeUni`
  - `status:<code>`

Example:

```nginx
location /api {
    waf on;
    waf_mode block;
    waf_sqli off;
    waf_xss off;
    waf_rules_file /etc/nginz/waf/basic.rules;
}
```

Example rule file:

```text
SecRule ARGS "@contains union select" "id:1001,phase:1,msg:'basic SQLi needle'"
SecRule REQUEST_BODY "@contains <script" "id:1002,phase:2,msg:'basic body XSS needle'"
SecRule REQUEST_HEADERS "@contains x-api-key: bad-value" "id:1003,phase:1,msg:'header needle'"
SecRule ARGS "@libinjection_sqli" "id:2001,phase:1,msg:'libinjection SQLi rule'"
SecRule REQUEST_BODY "@libinjection_xss" "id:2002,phase:2,msg:'libinjection XSS rule'"
SecRule REQUEST_HEADERS:X-Scoped-Header "@contains secret-value" "id:2003,phase:1,msg:'scoped header rule'"
SecRule ARGS:role "@contains admin" "id:2004,phase:1,msg:'scoped arg rule'"
SecRule REQUEST_BODY:comment "@contains blocked-field" "id:2005,phase:2,msg:'scoped body rule'"
SecRule REQUEST_METHOD "@streq patch" "id:2006,phase:1,msg:'exact method rule'"
SecRule REQUEST_URI "@rx regex-path-[0-9]+" "id:2007,phase:1,msg:'regex path rule'"
SecRule REQUEST_URI "@beginsWith /admin" "id:2008,phase:1,msg:'prefix rule'"
SecRule REQUEST_URI "@endsWith .php" "id:2009,phase:1,msg:'suffix rule'"
SecRule QUERY_STRING "@contains token=blocked" "id:2010,phase:1,msg:'query string rule'"
SecRule REQUEST_LINE "@contains GET /admin HTTP/1.1" "id:2011,phase:1,msg:'request line rule'"
SecRule REQUEST_HEADERS "@pm x-api-key bad-token" "id:2012,phase:1,msg:'phrase match rule'"
SecRule REQUEST_METHOD "@within patch delete" "id:2013,phase:1,msg:'within set-membership rule'"
SecRule REQUEST_PROTOCOL "@streq http/1.1" "id:2014,phase:1,msg:'request protocol rule'"
SecRule REQUEST_SCHEME "@streq http" "id:2015,phase:1,msg:'request scheme rule'"
SecRule REQUEST_BASENAME "@streq admin.php" "id:2016,phase:1,msg:'request basename rule'"
SecRule REQUEST_EXT "@streq php" "id:2017,phase:1,msg:'request ext rule'"
SecRule ARGS "@contains weighted-score-needle" "id:2018,phase:1,score:2,msg:'weighted score rule'"
SecRule ARGS "@contains setvar-score-needle" "id:2019,phase:1,setvar:ip.score=+2,msg:'setvar score rule'"
SecRule ARGS "@contains severity-score-needle" "id:2020,phase:1,severity:'error',msg:'severity score rule'"
SecRule ARGS:attempts "@ge 5" "id:2021,phase:1,msg:'numeric comparison rule'"
SecRule REMOTE_ADDR "@ipMatch 127.0.0.1/32 ::1/128" "id:2022,phase:1,msg:'ip cidr rule'"
SecRule REMOTE_ADDR "@ipMatchFromFile /etc/nginz/waf-ip-cidrs.txt" "id:2023,phase:1,msg:'ip file rule'"
SecRule REQUEST_HEADERS:User-Agent "@strmatch webzip" "id:2024,phase:1,msg:'single-pattern rule'"
SecRule REQUEST_HEADERS:X-Word-Header "@containsWord token" "id:2025,phase:1,msg:'word boundary rule'"
SecRule REQUEST_URI "@unconditionalMatch" "id:2026,phase:1,msg:'utility always-match rule'"
SecRule REQUEST_HEADERS:X-Encoded-Header "@validateUrlEncoding" "id:2027,phase:1,msg:'invalid url encoding rule'"
SecRule REQUEST_BODY "@validateUtf8Encoding" "id:2028,phase:2,msg:'invalid utf8 rule'"
SecRule REQUEST_HEADERS:User-Agent "@pmFromFile /etc/nginz/waf-phrases.txt" "id:2029,phase:1,msg:'phrase file rule'"
SecRule RESPONSE_STATUS "@streq 204" "id:2030,phase:3,status:451,msg:'response status rule'"
SecRule RESPONSE_HEADERS "@contains x-response-waf: response-header-hit" "id:2031,phase:3,status:452,msg:'response header rule'"
SecRule RESPONSE_HEADERS:X-Response-Scoped "@contains scoped-response-hit" "id:2032,phase:3,status:453,msg:'response header selector rule'"
SecRule REQUEST_HEADER_NAMES "@contains x-api-key" "id:2033,phase:1,msg:'header name collection rule'"
SecRule REQUEST_URI "@contains blocked-api" "id:2034,phase:1,status:406,msg:'custom status rule'"
SecRule REQUEST_URI "@contains high-risk-path" "id:2035,phase:1,deny,status:418,msg:'deny override rule'"
SecRule REQUEST_URI "@contains monitor-only-path" "id:2036,phase:1,pass,log,msg:'pass override rule'"
```

### Detection stack

When `waf_sqli on;` or `waf_xss on;` is enabled, the module currently applies detection in this order:

1. URL-decode the inspected input
2. Run `libinjection` on the decoded value
3. Fall back to the module's native lowercase substring signatures

This keeps the native fast-path checks while improving detection for obfuscated payloads that the original substring matcher missed.

Inside `waf_rules_file`, `@libinjection_sqli` and `@libinjection_xss` can now be used explicitly as rule operators in the supported native subset.

`REQUEST_BODY:name` selectors now support these practical body collections:

- `application/x-www-form-urlencoded` request fields
- `application/json` selector paths such as `profile.comment`
- `multipart/form-data` field parts

Per-rule actions now have explicit semantics:

- `deny` forces a disruptive block for that rule, even if `waf_mode detect;` is set
- `block` is a native compatibility alias for `deny`
- `pass` forces a non-disruptive match for that rule, even if `waf_mode block;` is set
- `allow` is a narrow compatibility alias for `pass` in the native engine
- `log` requests a warning log entry when the rule matches
- `nolog` suppresses warning-log output for that rule even when detect mode would normally log the match
- `score:<n>` increases how much that rule contributes to shared-memory reputation scoring; omitted rules keep the default weight of `1`
- `setvar:ip.score=+<n>` is supported as a narrow compatibility alias for weighted reputation contribution; it maps to the same native score weighting as `score:<n>`
- `severity:'critical|error|warning|notice'` maps to native reputation weights (`5/4/3/2` respectively); explicit `score:<n>` and `setvar:ip.score=+<n>` still take precedence when both are present
- if neither `deny` nor `pass` is present, `waf_mode` remains the default enforcement switch

Detect-mode and `pass,log` matches now emit a more informative warning log line that includes both the matched rule type and the rule message / matched pattern detail when available.

The native subset now also supports metadata-oriented rule actions:

- `tag:'...'`
- `logdata:'...'`

These do not alter disruption flow, but they are emitted into warning-log output for non-blocking matches.

`@pm` is currently implemented as a practical native subset: it accepts a space-delimited phrase list and matches when any phrase appears in the normalized input.

`@within` is implemented as a small native set-membership subset: it accepts a space-delimited value list and matches only when the normalized input equals one of those candidate values.

`@strmatch` is implemented as a bounded single-pattern string matcher over the same normalized input path as `@contains`.

`@lt`, `@le`, `@gt`, and `@ge` are implemented as a small numeric comparison subset: both the inspected value and the rule pattern must parse as base-10 integers or the operator does not match.

`@ipMatch` is implemented as a CIDR/IP membership subset for address targets such as `REMOTE_ADDR`; rule-side CIDR parsing reuses nginx's native `ngx_ptocidr` helper.

`@ipMatchFromFile` is implemented as a bounded local-file subset: IP/CIDR files are loaded from the local filesystem only, one entry per line, with blank lines and `#` comments ignored, and runtime matching reuses the native `@ipMatch` matcher.

`@containsWord` is implemented as a word-boundary subset: letters, digits, and underscore count as word characters, and the needle only matches when both sides are bounded by non-word characters or string edges.

`@noMatch` and `@unconditionalMatch` are implemented as utility operators with literal semantics: the former never matches, and the latter always matches.

`@validateUrlEncoding` is implemented as a strict malformed-encoding detector: it matches when the inspected value contains a `%` escape that is incomplete or not followed by two hexadecimal digits.

`@validateUtf8Encoding` is implemented as a strict malformed-UTF-8 detector: it matches when the inspected raw bytes are not valid UTF-8 according to Zig's standard Unicode validator.

`@pmFromFile` is implemented as a bounded local-file subset: phrase files are loaded from the local filesystem only, one phrase per line, with blank lines and `#` comments ignored, and runtime matching reuses the native `@pm` phrase matcher.

The native subset now also supports a small explicit transformation set:

- `t:none`
- `t:lowercase`
- `t:urlDecode`
- `t:urlDecodeUni`

These transforms are now applied explicitly per rule. This is still not a full ordered ModSecurity transform pipeline, but rule-level `t:none`, `t:lowercase`, `t:urlDecode`, and `t:urlDecodeUni` semantics are no longer parser-only placeholders.

#### waf_ban_threshold

*syntax:* `waf_ban_threshold <n>;`
*default:* `0`
*context:* `location`

Enable temporary IP bans after `<n>` WAF detections within the configured ban window.

#### waf_ban_window

*syntax:* `waf_ban_window <seconds>;`
*default:* `60`
*context:* `location`

Time window in seconds for counting repeated WAF detections toward a temporary ban.

#### waf_ban_duration

*syntax:* `waf_ban_duration <seconds>;`
*default:* `300`
*context:* `location`

Temporary ban duration in seconds once the threshold is reached.

Repeated offenders now escalate beyond a flat first ban: the module keeps per-IP shared-memory strike state and increases later ban durations when the same client keeps tripping WAF rules again after recovery. Quiet periods decay that strike history over time.

#### waf_score_threshold

*syntax:* `waf_score_threshold <n>;`
*default:* `0`
*context:* `location`

Enable lightweight shared-memory score-based banning. Each WAF detection increments the client's score, and the client is temporarily banned once the score reaches `<n>`.

This is intended as a small native reputation layer rather than a full anomaly-scoring engine.

#### waf_score_decay_window

*syntax:* `waf_score_decay_window <seconds>;`
*default:* `60`
*context:* `location`

Controls how quickly accumulated client score decays during quiet periods. Larger values keep score history longer; smaller values let clients recover more quickly after isolated hits.

### Nginx Variables

These variables are exposed per-request after the WAF access phase has run.

| Variable | Values | Description |
|---|---|---|
| `$waf_result` | `allowed` / `denied` / `dryrun` | WAF outcome for this request. `dryrun` means a threat was detected in `waf_mode detect` but the request was not blocked. |
| `$waf_rule_id` | decimal or not found | Numeric rule ID of the matched custom rule. Not found for built-in SQLi/XSS/ban matches (no rule ID). |
| `$waf_score` | decimal | Current accumulated threat score for the client IP. `0` if score tracking is disabled or the IP has no recorded score. |
| `$waf_category` | `sqli` / `xss` / `ban` / `rule` / not found | Category of the first detected threat. `rule` for custom file-driven rules. Not found if no threat was detected. |
| `$waf_ban_entries` | decimal | Number of occupied shared reputation entries (maximum 256). |
| `$waf_ban_capacity_rejected` | decimal | Cumulative new reputation identities rejected because all entries are live. Existing state is never evicted to make room. |
| `$waf_ban_reclaimed` | decimal | Cumulative inactive entries safely reclaimed for a new identity. |

These variables let `nginz-njs` scripted modules compose unified security decisions, add observability, or shape denial responses without duplicating WAF logic.

### Practical policy note

Static IP allow/deny policy should continue to use nginx's built-in access controls (`allow` / `deny`).

`ngx_http_waf` is now focused on dynamic inspection, rule-driven blocking, and temporary shared-memory bans rather than duplicating nginx's coarse static IP ACL layer.

### Response Format

When a request is blocked, the module returns HTTP 403 with a JSON body:

```json
{"error":"waf_blocked","rule":"sqli"}
```

or

```json
{"error":"waf_blocked","rule":"xss"}
```

### Usage

```nginx
http {
    server {
        # Block both SQLi and XSS attacks
        location /api {
            waf on;
            waf_mode block;
            waf_sqli on;
            waf_xss on;
            waf_check_body on;

            proxy_pass http://backend;
        }

        # Detection-only mode for monitoring
        location /legacy {
            waf on;
            waf_mode detect;

            proxy_pass http://legacy-backend;
        }

        # Only check for SQLi (skip XSS)
        location /database-api {
            waf on;
            waf_sqli on;
            waf_xss off;

            proxy_pass http://db-backend;
        }

        # Disable WAF for trusted endpoints
        location /internal {
            waf off;

            proxy_pass http://internal-backend;
        }
    }
}
```

### Limitations

- Native pattern-based detection may still have false positives for certain legitimate inputs
- Limited to a small native subset of operators and actions; this is still far smaller than full ModSecurity syntax
- Request body inspection limited to 8KB for performance
- Temporary bans now keep shared-memory strike history, score-based banning, and escalating durations, but they are still a lightweight native reputation model rather than a full WAF reputation engine
- `libinjection` improves SQLi/XSS coverage but does not make the module full ModSecurity or CRS compatible
- `waf_rules_file` currently supports only a small native ModSecurity-like subset, not full ModSecurity or CRS compatibility

### Future Enhancements

- OWASP Core Rule Set compatibility
- IP blocklist/allowlist integration
- Response body filtering
- Anomaly scoring mode

### References

- [OWASP SQL Injection Prevention](https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html)
- [OWASP XSS Prevention](https://cheatsheetseries.owasp.org/cheatsheets/Cross_Site_Scripting_Prevention_Cheat_Sheet.html)

### Documentation Audit Checklist

- [x] Audit date: 2026-04-11
- [x] Bun integration coverage exists at `tests/waf/`.
- [x] Bun integration coverage now verifies nested child-location inheritance of detect mode, selective SQLi/XSS toggles, URL-decoded payloads, POST/PUT/PATCH body inspection, and detect-vs-block behavior.
- [x] Gap fixed in this audit pass: child locations under a parent `waf_mode detect` configuration now inherit detect mode correctly instead of silently falling back to block behavior.
- [x] Initial native ModSecurity-like subset is now implemented via `waf_rules_file`, with Bun coverage for file-driven `SecRule` matches on `REQUEST_URI`, `ARGS`, `REQUEST_BODY`, `REQUEST_HEADERS`, `REQUEST_COOKIES`, `REQUEST_METHOD`, and `REMOTE_ADDR` using `@contains` plus `phase` parsing.
- [x] `libinjection` is now vendored and compiled in-tree, and Bun coverage verifies improved detection of obfuscated SQLi/XSS payloads beyond the original substring signatures.
- [x] `waf_rules_file` now supports explicit `@libinjection_sqli` and `@libinjection_xss` operators with Bun coverage for file-driven rule execution.
- [x] `waf_rules_file` now supports `@rx`, equals-style operators, and scoped `REQUEST_HEADERS:<name>` / `REQUEST_COOKIES:<name>` selectors.
- [x] `waf_rules_file` now supports the `REQUEST_HEADER_NAMES` request collection for matching on normalized incoming header names.
- [x] `waf_rules_file` now supports scoped `RESPONSE_HEADERS:<name>` selectors for response-phase header matching.
- [x] `waf_rules_file` now supports the low-risk `@within` operator for exact token-set membership checks.
- [x] `waf_rules_file` now supports the safe request metadata collection `REQUEST_PROTOCOL`.
- [x] `waf_rules_file` now supports the safe request metadata collection `REQUEST_SCHEME`, derived from nginx connection TLS state.
- [x] `waf_rules_file` now supports the safe path-derived request metadata collection `REQUEST_BASENAME`.
- [x] `waf_rules_file` now supports the safe path-derived request metadata collection `REQUEST_EXT`.
- [x] `waf_rules_file` now supports per-rule `score:<n>` weighting for shared-memory reputation escalation.
- [x] `waf_rules_file` now supports a narrow `setvar:ip.score=+<n>` compatibility alias that maps to native reputation weighting.
- [x] `waf_rules_file` now supports a narrow `severity:'...'` subset mapped onto native reputation weighting.
- [x] `waf_rules_file` now supports low-risk numeric comparison operators `@lt`, `@le`, `@gt`, and `@ge`.
- [x] `waf_rules_file` now supports `@ipMatch` for exact-IP and CIDR matching on address-style targets.
- [x] `waf_rules_file` now supports a bounded local-file `@ipMatchFromFile` subset for config-loaded IP/CIDR lists.
- [x] `waf_rules_file` now supports `@containsWord` for low-risk word-boundary string matching.
- [x] `waf_rules_file` now supports `@strmatch` as a bounded single-pattern string matcher.
- [x] `waf_rules_file` now supports utility operators `@noMatch` and `@unconditionalMatch`.
- [x] `waf_rules_file` now supports `@validateUrlEncoding` for strict malformed percent-encoding detection.
- [x] `waf_rules_file` now supports `@validateUtf8Encoding` for strict malformed UTF-8 detection.
- [x] `waf_rules_file` now supports a bounded local-file `@pmFromFile` subset with config-time phrase loading.

`REQUEST_FILENAME` is still intentionally not supported. In this module it would require path mapping through nginx location/root resolution (`ngx_http_map_uri_to_path`) and that is not a clean access-phase metadata slice to emulate casually. The config parser now rejects it explicitly with a line-specific startup error.

Short aliases such as `@pmf` and `@ipMatchF` are also intentionally not supported right now. The native subset accepts the explicit forms `@pmFromFile` and `@ipMatchFromFile` only, and rejects unsupported aliases with line-specific startup errors.

The next reputation-model step remains intentionally deferred. A first attempt at configurable score-decay step sizing was reverted because it destabilized existing score-ban behavior, so richer expiry/escalation tuning still needs a more careful design pass.
- [x] Shared-memory temporary IP bans are now supported via `waf_ban_threshold`, `waf_ban_window`, and `waf_ban_duration`, with Bun coverage for threshold, active ban, and expiry behavior.
- [x] `waf_rules_file` now supports `ARGS:name` selectors and per-rule `status:<code>` actions for more practical application-facing policies.
- [x] `waf_rules_file` now supports `REQUEST_BODY:name` selectors for form-encoded and top-level JSON request bodies.
- [x] Supported native-compatibility coverage is now spread across multiple checked-in fixtures under `tests/waf/` (`native-subset.rules`, `operators.rules`, `collections.rules`, `action.rules`, `transform.rules`, `ban.rules`, `libinjection.rules`, `unsupported.rules`) instead of relying on one monolithic example file.
- [x] `waf_rules_file` now gives `deny` and `pass` explicit per-rule semantics while keeping `waf_mode` as the default enforcement policy when neither override is present.
- [x] `waf_rules_file` now supports safe action-slice additions `block` (alias of `deny`) and `nolog` for suppressing match logging.
- [x] `waf_rules_file` now supports `allow` as a narrow compatibility alias for `pass`.
- [x] `waf_rules_file` now emits line-specific config-time parser errors for unsupported native subset syntax.
- [x] Shared-memory bans now retain short-term offender reputation and escalate repeat-ban duration instead of always resetting to the same flat penalty.
- [x] `waf_rules_file` now supports prefix/suffix string operators via `@beginsWith` and `@endsWith`.
- [x] `waf_rules_file` now supports `QUERY_STRING` and `REQUEST_LINE` request metadata collections.
- [x] `waf_rules_file` now supports a native `@pm` subset for simple multi-phrase matching.
- [x] Detect-mode and `pass,log` matches now emit richer warning log lines with rule detail context.
- [x] `waf_rules_file` now supports metadata-oriented `tag:'...'` and `logdata:'...'` actions for richer non-blocking logs.
- [x] `waf_rules_file` now applies a small explicit transformation subset via `t:none`, `t:lowercase`, `t:urlDecode`, and `t:urlDecodeUni`.
- [x] `REQUEST_BODY:name` selectors now cover form-encoded fields, nested JSON selector paths, and multipart form-data fields via dedicated `body.rules` coverage.
- [x] Shared-memory reputation now also supports score-based banning via `waf_score_threshold` and `waf_score_decay_window`, with Bun coverage for thresholding and quiet-period decay.
- [x] Variable integration coverage now verifies `$waf_result`, `$waf_rule_id`, `$waf_score`, and `$waf_category` across allowed, detect-mode, rule-match, and score-enabled requests.
- [x] Body-phase blocking now preserves clean request lifecycle behavior for blocked form, nested JSON, multipart, and libinjection-backed body matches instead of leaking preread body bytes into later request parsing.
- [x] Body-phase denials now use a protocol-signaled connection close without forcing nginx lingering-close resets; Bun coverage isolates denial probes from its global keepalive pool and verifies the next request remains serviceable.
- [x] Static IP allow/deny remains intentionally delegated to nginx's built-in access controls rather than being reimplemented in the WAF module.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S1 FIXED; S2 LOCK HOLD REDUCED.** Shared reputation entries are keyed by client IP and effective policy. `waf_body_max_size` rejects oversized inspected bodies, and capacity never evicts active state. The reputation mutex now covers only lookup/decay/compound mutation: policy hashing and time sampling happen before locking, and a discarded diagnostic formatting pass was removed from both lookup and offense paths. The 128-case focused suite remains green. A future SHM-layout version may add an index; the current 256-entry bounded scan remains the correctness-preserving fallback.
