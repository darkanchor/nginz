## Wechatpay

`wechatpay` is a nginx proxy module to the upstream [wechat pay][1] gateway. It provides **3** major functionalies

1. A upstream proxy which signs the request as [wechat pay][1] gateway requires,
   meanwhile it verifies the signature in the upstream response.
2. Put in a nginx `access` phase by `wechatpay_access` directive, it verifies the signature
   from the request initiated by [wechat pay][1] gateway, such as `notification` request.
   Optionally it decrypts every `AES-GCM-256` ciphertxt which might present in the request body on the fly.
3. Provides content handlers which either encrypt to or decrypt from the base64 encoded ciphertxt
   found in a request body using **RSA** algorithm specified by [wechat pay][1]

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

**Verdict: S0 TRANSPORT/AUTHENTICITY FIXED; S1 CAPACITY OPEN.** HTTPS upstreams use system CA trust, SNI, certificate verification, and hostname validation; plain HTTP requires explicit `wechatpay_allow_insecure_http on`. Signed requests and upstream responses outside a ±300-second window are rejected. Successfully verified nonces enter a 1,024-entry shared-memory replay window, and a two-worker parallel regression proves twelve reuses are rejected after the first acceptance. Configurable replay capacity/telemetry and request/upstream body-size limits remain S1 work.
