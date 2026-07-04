/**
 * Minimal MQTT TCP mock and packet helpers for stream-module tests.
 *
 * This is intentionally not a broker. It captures MQTT CONNECT identity fields
 * and can send a successful CONNACK so nginx stream proxy/filter behavior can
 * be tested without a Mosquitto dependency.
 */

export function encodeRemainingLength(length) {
  const out = [];
  let value = length;
  do {
    let encoded = value % 128;
    value = Math.floor(value / 128);
    if (value > 0) encoded |= 0x80;
    out.push(encoded);
  } while (value > 0);
  return Buffer.from(out);
}

export function mqttString(value) {
  const body = Buffer.from(value);
  const len = Buffer.alloc(2);
  len.writeUInt16BE(body.length, 0);
  return Buffer.concat([len, body]);
}

export function buildMqttConnect({
  version = 4,
  clientId = "client-a",
  username = null,
  password = null,
  keepAlive = 60,
  connectProperties = Buffer.alloc(0),
} = {}) {
  const parts = [];
  parts.push(mqttString("MQTT"));
  parts.push(Buffer.from([version]));

  let flags = 0x02;
  if (username !== null) flags |= 0x80;
  if (password !== null) flags |= 0x40;
  parts.push(Buffer.from([flags]));

  const keepAliveBuf = Buffer.alloc(2);
  keepAliveBuf.writeUInt16BE(keepAlive, 0);
  parts.push(keepAliveBuf);

  if (version === 5) {
    const properties = Buffer.from(connectProperties);
    parts.push(encodeRemainingLength(properties.length));
    parts.push(properties);
  }

  parts.push(mqttString(clientId));
  if (username !== null) parts.push(mqttString(username));
  if (password !== null) parts.push(mqttString(password));

  const body = Buffer.concat(parts);
  return Buffer.concat([Buffer.from([0x10]), encodeRemainingLength(body.length), body]);
}

function decodeRemainingLength(buf, offset = 1) {
  let multiplier = 1;
  let value = 0;
  let width = 0;
  while (width < 4) {
    if (offset + width >= buf.length) return null;
    const encoded = buf[offset + width];
    value += (encoded & 0x7f) * multiplier;
    width++;
    if ((encoded & 0x80) === 0) return { value, width };
    multiplier *= 128;
  }
  return null;
}

function readUtf8(buf, state) {
  if (state.offset + 2 > state.end) return null;
  const len = buf.readUInt16BE(state.offset);
  state.offset += 2;
  if (state.offset + len > state.end) return null;
  const value = buf.subarray(state.offset, state.offset + len).toString();
  state.offset += len;
  return value;
}

export function parseMqttConnect(buf) {
  if (buf.length < 2 || buf[0] !== 0x10) return null;
  const remaining = decodeRemainingLength(buf);
  if (!remaining) return null;

  const headerLen = 1 + remaining.width;
  const end = headerLen + remaining.value;
  if (buf.length < end) return null;

  const state = { offset: headerLen, end };
  const protocol = readUtf8(buf, state);
  const version = buf[state.offset++];
  const flags = buf[state.offset++];
  const keepAlive = buf.readUInt16BE(state.offset);
  state.offset += 2;

  if (version === 5) {
    const props = decodeRemainingLength(buf, state.offset);
    if (!props) return null;
    state.offset += props.width + props.value;
  }

  const clientId = readUtf8(buf, state);
  const username = (flags & 0x80) !== 0 ? readUtf8(buf, state) : null;
  const password = (flags & 0x40) !== 0 ? readUtf8(buf, state) : null;

  return { protocol, version, flags, keepAlive, clientId, username, password, raw: buf.subarray(0, end) };
}

export class MqttMock {
  constructor(port = 18884) {
    this.port = port;
    this.server = null;
    this.connects = [];
  }

  start() {
    this.server = Bun.listen({
      hostname: "127.0.0.1",
      port: this.port,
      socket: {
        data: (socket, data) => {
          const parsed = parseMqttConnect(Buffer.from(data));
          if (parsed) this.connects.push(parsed);
          socket.write(Buffer.from([0x20, 0x02, 0x00, 0x00]));
        },
        error: (_socket, error) => console.error("MQTT mock error:", error),
      },
    });
    return this;
  }

  stop() {
    if (this.server) {
      this.server.stop();
      this.server = null;
    }
    this.connects = [];
  }

  getLastConnect() {
    return this.connects[this.connects.length - 1] ?? null;
  }
}

export function createMqttMock(port) {
  return new MqttMock(port);
}
