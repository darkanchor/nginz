## Wechatpay

`wechatpay` is a nginx proxy module to the upstream [wechat pay][1] gateway. It provides **4** major functionalities

1. A upstream proxy which signs the request as [wechat pay][1] gateway requires,
   meanwhile it verifies the signature in the upstream response.
2. Put in a nginx `access` phase by `wechatpay_access` directive, it verifies the signature
   from the request initiated by [wechat pay][1] gateway, such as `notification` request.
   Optionally it decrypts every `AES-GCM-256` ciphertxt which might present in the request body on the fly.
3. Provides content handlers which either encrypt to or decrypt from the base64 encoded ciphertxt
   found in a request body using **RSA** algorithm specified by [wechat pay][1]

4. XPay upstream pass-through for Mini Program virtual-payment server APIs: injects the app access token and signs the exact request body with the selected AppKey.

### Synopsis

```nginx

    http {
        #...
        wechatpay_apiclient_key_file prvkey.pem;
        wechatpay_public_key_file pubkey.pem;
        wechatpay_apiclient_serial 0000000000;
        wechatpay_serial FFFFFFFFFF;
        wechatpay_mch_id 1234567890;

        server {
            listen 443;
            #...

            location /notify {
                wechatpay_access aes_secret;
                proxy_pass http://localhost/confirm;
            }
        }

        server {
            listen 80;
            resolver 223.5.5.5;

            location / {
                wechatpay_proxy_pass https://api.mch.weixin.qq.com;
            }

            location /encrypt {
                wechatpay_oaep_encrypt on;
            }

            location /decrypt {
                wechatpay_oaep_decrypt on;
            }

            location /confirm {
                allow 127.0.0.1;
                deny all;
                #...;
            }
        }
    }

```

### Deployment

Provider requests include `User-Agent: nginz-wechatpay/1.0` and use
`wechatpay_serial` as the `Wechatpay-Serial` request header. For public-key
mode, configure the complete `PUB_KEY_ID_...` identifier with its matching
public key. This also selects public-key response signing during a merchant's
migration from platform certificates. See WeChat Pay's
[request rules](https://pay.weixin.qq.com/doc/v3/merchant/4012081709) and
[public-key migration guide](https://pay.weixin.qq.com/doc/v3/merchant/4012154180).

Successful response verification is available as `$wechatpay_verification`
(`success`), including for signed business errors such as `404 ORDER_NOT_EXIST`.
A business error does not itself mean that signing or verification failed.

Instead of providing standard nginx building routines, the project artifacts are module object files,
with which one shall build into a target `nginx` binary.

`ngx_http_wechatpay_module.o` provides **2** nginx modules, a content/access handler module and a filter module,
they can be added in the `objs/ngx_modules.c` as following.

> [!NOTE]
> Since [wechat pay][1] requires the request body as part of signature verification, the filter module
> holds both header and body until the signature is verified for downstream. A failed verification will
> be indicated from the response status line to the downstream.

```c

  extern ngx_module_t ngx_core_module;
  /*...*/
  extern ngx_module_t ngx_http_wechatpay_module;
  extern ngx_module_t ngx_http_wechatpay_filter_module;

  ngx_module_t *ngx_modules[] = {
      &ngx_core_module,
      &ngx_errlog_module,
      /*...*/
      &ngx_http_wechatpay_module,
      /*...*/
      /*...*/
      &ngx_http_wechatpay_filter_module,
      /*...*/
      &ngx_http_not_modified_filter_module,
      NULL
  };

  char* ngx_module_names[] = {
      "ngx_core_module",
      "ngx_errlog_module",
      /*...*/
      "ngx_http_wechatpay_module",
      /*...*/
      /*...*/
      "ngx_http_wechatpay_filter_module",
      /*...*/
      "ngx_http_not_modified_filter_module",
      NULL
  };

```

### Versions

`wechatpay` is tested with following `nginx` releases

- 1.27.4
- 1.27.3

### Directives

#### wechatpay_proxy_pass

*syntax: wechatpay_proxy_pass \[https://|http://\]wechatpay_gateway\[:port\]*          
*default: no, default to http://wechatpay_gateway:80 without schema or port, in production it shall be https://api.mch.weixin.qq.com*          
*context: location*          
*phase: content*            

The directive specifies the upstream wechatpay gateway. *note* apart from `ngx_http_proxy_module` whose *proxy_pass* directive usually
requires an explicit `$request_uri`, *wechatpay_proxy_pass* does not need them as wechatpay gateway uses uri path and args to compute

#### wechatpay_body_max_size

*syntax: wechatpay_body_max_size size*

*default: 1m*

*context: http, server, location*

Bounds request bodies used for signing, access verification, and OAEP operations, and bounds upstream response bodies retained for signature verification. Oversized client bodies return 413; oversized or invalidly framed upstream responses return 502. The limit applies to both fixed-length and chunked bodies.
the signature and it makes little sense to modify them. The module uses the *method*, *uri path* and *uri args* of the original request
for the upstream.

#### wechatpay_apiclient_key_file

*syntax: wechatpay_apiclient_key_file path/to/prvkey.pem*           
*default: no*          
*context: http, server, location*          
*phase: content*            

The directive takes a file path parameter, it can be either an absolute path or one path relative to the nginx conf directory.
The module aborts if the key file cannot be validated.

#### wechatpay_apiclient_serial

*syntax: wechatpay_apiclient_serial serial_no*           
*default: no*          
*context: http, server, location*          
*phase: content*            

The directive specifies the apiclient serial to compute the signature.

#### wechatpay_public_key_file

*syntax: wechatpay_public_key_file path/to/pubkey.pem*           
*default: no*          
*context: http, server, location*          
*phase: content*            

The directive takes a file path parameter, it can be either an absolute path or one path relative to the nginx conf directory.
The module aborts if the key file cannot be validated. This file is the wechatpay platform public key file.

#### wechatpay_serial

*syntax: wechatpay_serial serial_no*           
*default: no*          
*context: http, server, location*          
*phase: content*            

The directive specifies the wechatpay platform serial to verify the signature. It is also named as *Public Key ID*.

#### wechatpay_mch_id

*syntax: wechatpay_mch_id id_string*           
*default: no*          
*context: http, server, location*          
*phase: content*            

The directive specifies the *mch_id* to compute the signature.

#### wechatpay_oaep_encrypt

*syntax: wechatpay_oaep_encrypt on|off*           
*default: off*          
*context: location*          
*phase: content*            

When turns *on*, the location will encrypt the request body with public key provided by *wechatpay_public_key_file*
using *RSA_PKCS1_OAEP_PADDING* and response the base64 encoded ciphertxt

#### wechatpay_oaep_decrypt

*syntax: wechatpay_oaep_decrypt on|off*           
*default: off*          
*context: location*          
*phase: content*            

When turns *on*, the location will decrypt the base64 encoded request body with private key provided by *wechatpay_apiclient_key_file*
using *RSA_PKCS1_OAEP_PADDING* and response decrypted plaintxt

#### wechatpay_access

*syntax: wechatpay_access \[aes_secret\]*           
*default: no*          
*context: location*          
*phase: access*            

The directive applies the signature verification in *access* phase and rejects the request if the verification fails. When provisioned
with an optional 32 bytes AES secret (aka API v3 AES secret in wechatpay term), it iterates and locates the AES encrypted message in the
request body, decrypts and appends plaintxt for the location's content handler, only if the verification succeeds.

*Note* since the verification requires request body, the module will read entire request body in the *access* phase already.

[1]: https://pay.weixin.qq.com/ "wechat pay"

### Documentation Audit Checklist

- [x] Audit date: 2026-04-10
- [x] Verified the README still matches the reviewed multi-module shape and exported directive surface.
- [x] Bun integration coverage now exists under `tests/wechatpay/` for proxy signing/verification, access-phase verification, and OAEP encrypt/decrypt flows.
- [x] Gap recorded: this audit pass fixed real upstream/body lifecycle bugs that the new Bun suite exposed, including premature finalize-on-`NGX_DONE` handling and incorrect upstream body buffering/copying.
- [x] No additional documentation gaps were identified in this audit pass.

### Engineering Audit Verdict (2026-07-12)

**Verdict: S0 TRANSPORT/AUTHENTICITY FIXED; S1 CORE BOUNDS FIXED.** HTTPS upstreams use system CA trust, SNI, certificate verification, and hostname validation; plain HTTP requires explicit `wechatpay_allow_insecure_http on`. Signed requests and upstream responses outside a ±300-second window are rejected. Successfully verified nonces enter a 1,024-entry shared-memory replay window, fail closed at capacity without overwriting fresh entries, and reclaim only expired slots. `wechatpay_body_max_size` bounds fixed-length and chunked request/upstream bodies before signature-path allocations; focused 413/502 regressions keep transport failures distinct from authentication failures. The 24-case focused suite is green; capacity telemetry and TLS-negative integration remain proof work.

### XPay virtual-payment server APIs

`wechatpay_xpay_proxy_pass` forwards JSON POST requests to WeChat's XPay APIs.
It shares the bounded upstream transport with API v3, but uses separate
credentials and does not apply API v3 response verification or decryption.
No merchant RSA key, merchant ID, or platform serial is needed for XPay.

```nginx
http {
    resolver 223.5.5.5;
    # Raw AppKey bytes, without an added newline. Relative paths use the
    # nginx configuration directory. Files are loaded at startup/reload.
    wechatpay_xpay_live_key_file /run/app/xpay-live.key;
    wechatpay_xpay_sandbox_key_file /run/app/xpay-sandbox.key; # optional
    wechatpay_xpay_env 0; # default: live; sandbox is explicitly 1

    # Define/populate this private variable in the application before making
    # the payment subrequest. Token acquisition/refresh stays in the app.
    js_var $private_app_access_token "";
    wechatpay_xpay_access_token $private_app_access_token;

    server {
        listen 8080;
        location = /xpay/query_order {
            internal;
            wechatpay_xpay_auth appkey;
            wechatpay_audit_request /_payment/audit_request;
            wechatpay_xpay_proxy_pass https://api.weixin.qq.com;
        }
        location = /xpay/notify_provide_goods {
            internal;
            wechatpay_xpay_auth token;
            wechatpay_audit_request /_payment/audit_request;
            wechatpay_xpay_proxy_pass https://api.weixin.qq.com;
        }
        # Define /_payment/audit_request in the application. It must commit
        # $wechatpay_request and return 2xx before dispatch is allowed.
    }
}
```

Send the final JSON body, including integer `env: 0`, to the internal location.
The URI must be `/xpay/<endpoint>`; rewrites must finish before the handler runs.
The configured upstream is an origin (scheme, DNS/IPv4 hostname, optional port),
without a path, query, or user information. HTTPS verifies the peer and hostname;
HTTP requires the existing `wechatpay_allow_insecure_http on` test override.

| Directive | Context | Behavior |
| --- | --- | --- |
| `wechatpay_xpay_proxy_pass origin` | location | XPay handler; cannot share a location with v3 proxy/access/OAEP handlers |
| `wechatpay_xpay_auth appkey\|token` | http/server/location | Required explicit policy, inherited; `appkey` adds `pay_sig`, `token` adds only `access_token` |
| `wechatpay_xpay_access_token value` | http/server/location | Required nginx complex value; evaluated per request; empty or >8192-byte token fails with 500 |
| `wechatpay_xpay_env 0\|1` | http/server/location | Inherited, defaults to live `0`; body `env` must match |
| `wechatpay_xpay_live_key_file path` | http/server/location | Literal live AppKey file; required when selected in `appkey` mode |
| `wechatpay_xpay_sandbox_key_file path` | http/server/location | Literal sandbox AppKey file; required when selected in `appkey` mode |

In `appkey` mode the signature is lowercase HMAC-SHA256 over
`upstream_path + "&" + exact_body`, keyed by the configured AppKey. The module
URL-encodes the private access token and attaches it with `pay_sig`. The
forwarded body is the same immutable byte buffer that was signed, including
whitespace and UTF-8 text. Caller cookies, Authorization, and Wechatpay headers
are not forwarded. The body must be a valid JSON object with one integer `env`
(`0` or `1`, not a string, decimal, or exponent). Duplicate JSON members,
root-level `access_token`/`pay_sig`/`signature`, environment mismatches, and
incoming query strings return 400. Other methods return 405.

Use `appkey` for `query_order`, `start_upload_goods`, `query_upload_goods`,
`start_publish_goods`, and `query_publish_goods`. The reviewed
`notify_provide_goods` specification requires token-only authentication.
The module deliberately requires an explicit policy rather than inferring one
from the endpoint name. Session-key/user-signature modes (coin/balance and
refund-specific requirements) are not implemented.

`wechatpay_body_max_size` limits both request and response bodies (default 1 MiB).
Request overflow returns 413. Incomplete, invalid, oversized, or timed-out
upstream responses return 502. Connect/send/read timeouts are each 60 seconds.
There is one upstream attempt and no automatic mutation retry. Complete HTTP
responses retain their status and body, including HTTP 200 with nonzero
`errcode`; the application interprets business outcomes.

With `wechatpay_audit_request`, any non-2xx audit result prevents dispatch and
returns 503. XPay audit evidence contains the exact path and body plus protocol,
authentication mode, and environment, **without** AppKeys, access tokens, or
`pay_sig`. It is a redacted evidence record, not the authenticated wire request.
The following variables are available to the audit handler and the completed
payment subrequest:

| Variable | XPay value |
| --- | --- |
| `$wechatpay_protocol` | `xpay` (`v3` on existing API v3 requests) |
| `$wechatpay_request` | Redacted request evidence and exact JSON body |
| `$wechatpay_response` | Captured response body; may be partial on transport failure |
| `$wechatpay_transport` | `complete` after a full response; otherwise `incomplete` |
| `$wechatpay_verification` | Always `unverified`; HTTPS is not an API v3 signature |

Header-only subrequests cannot establish body completeness and remain
`incomplete`. Use an ordinary body-capturing subrequest for payments. Standard
nginx debug logging can expose evaluated variables; keep credential-bearing
variables out of application/access logs and disable debug logging in production.

Client `wx.requestVirtualPayment` parameter signing, session storage, token
refresh, catalog consistency, order validation, and fulfillment stay in the
application. See [the design and official references](XPAY-PROPOSAL.md).

Validation: `zig test src/modules/wechatpay-nginx-module/xpay.zig -lc` and
`bun test tests/xpay/ tests/wechatpay/` (the Bun suite builds nginz first).
