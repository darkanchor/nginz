/**
 * Mock server exports for testing nginx modules
 *
 * Each mock server simulates a real upstream service:
 * - Redis: TCP-based key-value store (RESP protocol)
 * - PostgreSQL: TCP-based database (wire protocol)
 * - Consul: HTTP-based service discovery and KV store
 * - OIDC: HTTP-based OAuth2/OpenID Connect provider
 * - ACME: HTTP-based Let's Encrypt protocol
 * - HTTP: Generic HTTP upstream with configurable responses
 */

export { RedisMock, createRedisMock } from "./redis.js";
export { PostgresMock, createPostgresMock } from "./postgres.js";
export { ConsulMock, createConsulMock } from "./consul.js";
export { OIDCMock, createOIDCMock } from "./oidc.js";
export { ACMEMock, createACMEMock } from "./acme.js";
export {
  signWechatpayMessage,
  buildWechatpayHeaders,
  signedUpstreamResponse,
  encryptWechatpayResource,
  parseAuthorizationHeader,
  verifyProxyAuthorization,
} from "./wechatpay.js";
export {
  HTTPMock,
  StaticMock,
  ProxyMock,
  createHTTPMock,
  createStaticMock,
  createProxyMock,
} from "./http.js";
