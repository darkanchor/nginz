# XPay pass-through support

Implemented server pass-through, 2026-09-16. This extends the module's existing purpose: applications
send an ordinary request through nginz; nginz handles protocol authentication
while forwarding to the upstream. The directives below are available; see the
[README](README.md#xpay-virtual-payment-server-apis) for the exact contract.

## Where the pass-through model fits

WeChat Mini Program virtual payment uses `https://api.weixin.qq.com/xpay/...`.
For `query_order` and the goods upload/publication APIs, nginz can buffer the
outgoing body, compute the required signature, attach it to the upstream query,
and forward the original body unchanged:

```text
pay_sig = lowercase_hex(HMAC_SHA256(AppKey, upstream_path + "&" + exact_body))
```

The path excludes scheme, host and query. The AppKey is literal UTF-8 text.
Whitespace, field order, Chinese text and JSON escaping affect the signature.
Any body transformation must happen before signing; the forwarded bytes must
be identical to the signed bytes. `access_token` is also an upstream query
parameter. Request `env=0` selects the live AppKey; `env=1` selects sandbox.

This is a useful new protocol mode for the existing pass-through module. It
removes repeated transport signing and credential injection from every backend.
XPay business responses remain ordinary JSON, including HTTP 200 with a nonzero
`errcode`. The reviewed XPay APIs do not document API v3 RSA response signatures
or RSA/AES-encrypted response fields. Do not run v3 verification/decryption on
these responses, or claim that HTTPS success is a verified merchant signature.

## Implemented interface

```nginx
# Credentials stay in private server configuration or private variables.
# Distinct from the merchant API v3 key and RSA certificates.
wechatpay_xpay_live_key_file /run/app/xpay-live.key;
wechatpay_xpay_sandbox_key_file /run/app/xpay-sandbox.key;
wechatpay_xpay_env 0; # live by default; body env must match

location = /xpay/query_order {
    internal;
    wechatpay_xpay_access_token $private_app_access_token;
    wechatpay_xpay_auth appkey;
    wechatpay_xpay_proxy_pass https://api.weixin.qq.com;
}
location = /xpay/notify_provide_goods {
    internal;
    wechatpay_xpay_access_token $private_app_access_token;
    wechatpay_xpay_auth token;
    wechatpay_xpay_proxy_pass https://api.weixin.qq.com;
}
```

Use a new `wechatpay_xpay_proxy_pass` family, sharing the existing upstream,
request buffering, TLS, cancellation and audit machinery where appropriate.
Keep explicit per-location authentication policies; do not assume every XPay
endpoint has identical requirements. Fail closed for a missing active key,
missing token, invalid/non-integer `env`, malformed or duplicate security fields,
unsupported method, oversized body or contradictory configured environment.
The environment is selected by `wechatpay_xpay_env` (default 0) and checked
against the strictly validated JSON body. Neither AppKeys
nor authentication parameters should be selectable by public HTTP input.
All incoming query strings and root-level body `pay_sig`, `signature`, and
`access_token` fields are rejected so callers cannot override authentication.

The reviewed `notify_provide_goods` endpoint documents `access_token` but no
`pay_sig`; forward it using token-only authentication. Keep its policy explicit
and verify against a real provider response before release. The refund endpoint
has inconsistent user-signature wording between notes and its parameter table;
defer refund-specific authentication until that is resolved. Coin/balance APIs
may also need user signatures and should be separate supported policies.

## Preserve the existing transport guarantees

- Audit before first network dispatch; audit failure must prevent dispatch.
  Capture the exact body and path, and redacted authentication metadata. Never
  persist AppKeys, session keys, app access tokens or signed token-bearing URLs.
- Use a protocol discriminator in audit evidence. Expose transport completeness
  and HTTP status separately from provider `errcode` and from v3 signature trust.
- Preserve business-error JSON and HTTP status. The application decides whether
  an order is paid, closed, mismatched, refunded or still pending.
- Do not automatically replay mutations on upstream failure. Lost upload,
  publication, delivery and refund responses require endpoint-specific recovery.
- Keep TLS peer/hostname verification and bounded request/response buffers.
  Test memory/file-buffer bodies, empty and multichunk bodies, subrequests,
  parent cancellation, timeouts, audit failure, upstream retry and key rotation.
- Retain the v3 code path and its existing signature/encryption behavior.

## What stays in the application

Preparing `wx.requestVirtualPayment` parameters has **no upstream request**.
The application generates an immutable order attempt and exact `signData`, then
returns `paySig = HMAC(AppKey, "requestVirtualPayment&" + signData)` and
`signature = HMAC(session_key, signData)` to the authenticated Mini Program.
A standalone native signer would not be a pass-through feature, so it is outside
this proposal. Keep this preparation in Gleam with the current HMAC binding.

Session ownership, Redis session storage, token refresh coordination, product
mapping, prices, idempotency, entitlements and delivery sequencing also stay in
application code. The existing access-token cache can supply a private variable
or internal subrequest; moving cache policy into this payment module is not
needed. Message push verification is a separate inbound messaging protocol,
not an extension of v3 notification AES-GCM handling.

Carve can initially use its Gleam XPay adapter, then replace only the server
request-signing/fetch boundary with internal pass-through requests using this
mode. No database or Mini Program contract change should be necessary.

## Official references

- [Virtual-payment guide and signature rules](https://developers.weixin.qq.com/miniprogram/dev/platform-capabilities/business-capabilities/virtual-payment.html)
- [wx.requestVirtualPayment](https://developers.weixin.qq.com/miniprogram/dev/api/payment/wx.requestVirtualPayment.html)
- [query_order](https://developers.weixin.qq.com/miniprogram/dev/server/API/VirtualPayment/api_query_order)
- [notify_provide_goods](https://developers.weixin.qq.com/miniprogram/dev/server/API/VirtualPayment/api_notify_provide_goods)
- [start_upload_goods](https://developers.weixin.qq.com/miniprogram/dev/server/API/VirtualPayment/api_start_upload_goods)
- [query_upload_goods](https://developers.weixin.qq.com/miniprogram/dev/server/API/VirtualPayment/api_query_upload_goods)
- [start_publish_goods](https://developers.weixin.qq.com/miniprogram/dev/server/API/VirtualPayment/api_start_publish_goods)
- [query_publish_goods](https://developers.weixin.qq.com/miniprogram/dev/server/API/VirtualPayment/api_query_publish_goods)
