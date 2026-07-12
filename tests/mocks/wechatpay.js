import {
  createCipheriv,
  createSign,
  createVerify,
} from "node:crypto";

let nonceSequence = 0;
function nextNonce(prefix) {
  nonceSequence += 1;
  return `${prefix}${nonceSequence}`;
}

export function signWechatpayMessage(body, { timestamp, nonce, privateKey }) {
  const signer = createSign("RSA-SHA256");
  signer.update(`${timestamp}\n${nonce}\n${body}\n`);
  signer.end();
  return signer.sign(privateKey, "base64");
}

export function buildWechatpayHeaders(body, {
  privateKey,
  timestamp = String(Math.floor(Date.now() / 1000)),
  nonce = nextNonce("testnonce"),
  serial,
  requestId = "req-123456",
  signature,
} = {}) {
  const signed = signature ?? signWechatpayMessage(body, { timestamp, nonce, privateKey });
  return {
    "Content-Type": "application/json",
    "Request-ID": requestId,
    "Wechatpay-Serial": serial,
    "Wechatpay-Nonce": nonce,
    "Wechatpay-Timestamp": timestamp,
    "Wechatpay-Signature": signed,
  };
}

export function signedUpstreamResponse(body, {
  privateKey,
  serial,
  status = 200,
  timestamp = String(Math.floor(Date.now() / 1000)),
  nonce = nextNonce("upstreamnonce"),
  requestId = "upstream-req-1",
  signature,
  extraHeaders = {},
} = {}) {
  const signed = signature ?? signWechatpayMessage(body, { timestamp, nonce, privateKey });
  return {
    status,
    body,
    headers: {
      "Content-Type": "application/json",
      "Request-ID": requestId,
      "Wechatpay-Serial": serial,
      "Wechatpay-Nonce": nonce,
      "Wechatpay-Timestamp": timestamp,
      "Wechatpay-Signature": signed,
      ...extraHeaders,
    },
  };
}

export function encryptWechatpayResource(plaintext, {
  aesKey,
  associatedData = "certificate",
  nonce = "nonce-1234567",
} = {}) {
  const cipher = createCipheriv("aes-256-gcm", Buffer.from(aesKey, "utf8"), Buffer.from(nonce, "utf8"));
  cipher.setAAD(Buffer.from(associatedData, "utf8"));
  const ciphertext = Buffer.concat([
    cipher.update(Buffer.from(plaintext, "utf8")),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return {
    algorithm: "AEAD_AES_256_GCM",
    ciphertext: Buffer.concat([ciphertext, tag]).toString("base64"),
    associated_data: associatedData,
    nonce,
  };
}

export function parseAuthorizationHeader(header) {
  const [scheme, rawParams] = header.split(" ", 2);
  const params = {};
  for (const part of rawParams.split(",")) {
    const match = part.match(/([^=]+)="([^"]*)"/);
    if (match) params[match[1]] = match[2];
  }
  return { scheme, params };
}

export function verifyProxyAuthorization(header, {
  method,
  path,
  query,
  body,
  publicKey,
  mchId,
  serial,
}) {
  const { scheme, params } = parseAuthorizationHeader(header);
  if (scheme !== "WECHATPAY2-SHA256-RSA2048") return false;
  if (params.mchid !== mchId) return false;
  if (params.serial_no !== serial) return false;
  if (!params.timestamp || !params.nonce_str || !params.signature) return false;

  const verifier = createVerify("RSA-SHA256");
  verifier.update(`${method}\n${path}?${query}\n${params.timestamp}\n${params.nonce_str}\n${body}\n`);
  verifier.end();
  return verifier.verify(publicKey, params.signature, "base64");
}
