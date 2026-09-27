#!/usr/bin/env node
// Smoke test for the DirectorLink relay (docs/RELAY.md, version 0). Node 22+, no dependencies.
//
// Driver mode (the default): a fake DirectorLink driver. It speaks WebSocket byte by byte over
// node:net (ws://) or node:tls (wss://) exactly as RELAY.md describes: the handshake headers, a
// hello, "ping" every 25 s, and a canned JSON answer (an echo of the request) to every relayed
// request. It prints what happens.
//
//   node scripts/relay_smoke.mjs [--url ws://127.0.0.1:8787] [--home <32 hex>] [--secret <64 hex>]
//                                [--version 0.9.0-smoke] [--once]
//   node scripts/relay_smoke.mjs --url wss://api.directorlink.io --home <id> --secret <secret>
//
//   --home and --secret default to new random values, printed so they can be reused. --once exits
//   after the first request has been answered. Otherwise a lost connection is retried like the
//   real driver does (5 s, 10 s, 30 s, then every 60 s); being replaced (close 4000) ends the run.
//
// Client mode: calls the version 0 test endpoints.
//
//   node scripts/relay_smoke.mjs status --url https://api.directorlink.io --token <TEST_TOKEN> --home <id>
//   node scripts/relay_smoke.mjs get /v1/lights --url https://api.directorlink.io --token <TEST_TOKEN> --home <id> [--out <file>]
//
//   --token defaults to $TEST_TOKEN; ws:// and wss:// URLs work too. Exits 0 for a 2xx answer.
//
// The canned answer can be steered from the query string, for checks against a deployed relay:
//   smoke_status=<code>   answer with that HTTP status
//   smoke_delay_ms=<ms>   answer late (more than 15000: the relay answers 504 first)
//   smoke_binary=1        answer with body_base64 (the bytes 00..ff, application/octet-stream)
//
// tests/cloud/*.test.mjs import the functions below.

import { createHash, randomBytes } from "node:crypto";
import { EventEmitter } from "node:events";
import { writeFileSync } from "node:fs";
import net from "node:net";
import path from "node:path";
import process from "node:process";
import tls from "node:tls";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

export const DEFAULT_URL = "ws://127.0.0.1:8787";
export const DEFAULT_VERSION = "0.9.0-smoke";
export const PING_INTERVAL_MS = 25_000;
export const SILENCE_TIMEOUT_MS = 60_000;
export const RECONNECT_DELAYS_S = [5, 10, 30, 60];

const WEBSOCKET_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
const HANDSHAKE_TIMEOUT_MS = 15_000;
const CLOSE_TIMEOUT_MS = 5_000;
const MAX_HEAD_BYTES = 64 * 1024;
const MAX_MESSAGE_BYTES = 64 * 1024 * 1024;

export const Opcode = Object.freeze({ CONTINUATION: 0x0, TEXT: 0x1, BINARY: 0x2, CLOSE: 0x8, PING: 0x9, PONG: 0xa });

export function randomHex(bytes) {
  return randomBytes(bytes).toString("hex");
}

export function websocketAccept(key) {
  return createHash("sha1").update(key + WEBSOCKET_GUID).digest("base64");
}

// Where to connect, from ws(s):// or http(s):// with or without /relay/connect.
export function relayEndpoints(input = DEFAULT_URL) {
  const url = new URL(input);
  if (!["ws:", "wss:", "http:", "https:"].includes(url.protocol)) {
    throw new Error(`the URL must start with ws://, wss://, http:// or https:// (got ${input})`);
  }
  const secure = url.protocol === "wss:" || url.protocol === "https:";
  const base = url.pathname.replace(/\/relay\/connect\/?$/, "").replace(/\/+$/, "");
  return {
    secure,
    hostname: url.hostname.replace(/^\[|\]$/g, ""),
    port: Number(url.port) || (secure ? 443 : 80),
    host: url.host,
    connectPath: `${base}/relay/connect`,
    websocket: `${secure ? "wss" : "ws"}://${url.host}${base}/relay/connect`,
    http: `${secure ? "https" : "http"}://${url.host}${base}`,
  };
}

// --- Frames (RFC 6455 section 5) ----------------------------------------------------------------

// One frame. Frames from a client are masked with a fresh random key.
export function encodeFrame(opcode, payload = Buffer.alloc(0), { fin = true, mask = true } = {}) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload);
  const length = data.length;
  const extended = length < 126 ? 0 : length < 0x10000 ? 2 : 8;
  const header = Buffer.alloc(2 + extended + (mask ? 4 : 0));
  header[0] = (fin ? 0x80 : 0) | opcode;
  header[1] = (mask ? 0x80 : 0) | (extended === 0 ? length : extended === 2 ? 126 : 127);
  if (extended === 2) {
    header.writeUInt16BE(length, 2);
  } else if (extended === 8) {
    header.writeBigUInt64BE(BigInt(length), 2);
  }
  if (!mask) {
    return Buffer.concat([header, data]);
  }
  const key = randomBytes(4);
  key.copy(header, 2 + extended);
  const masked = Buffer.allocUnsafe(length);
  for (let i = 0; i < length; i += 1) {
    masked[i] = data[i] ^ key[i & 3];
  }
  return Buffer.concat([header, masked]);
}

export class ProtocolError extends Error {
  constructor(closeCode, message) {
    super(message);
    this.closeCode = closeCode;
  }
}

// Splits a byte stream into frames; push() returns the frames completed by each chunk.
export class FrameParser {
  constructor({ maxPayload = MAX_MESSAGE_BYTES } = {}) {
    this.buffer = Buffer.alloc(0);
    this.maxPayload = maxPayload;
  }

  push(chunk) {
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk]);
    const frames = [];
    for (;;) {
      const buffer = this.buffer;
      if (buffer.length < 2) {
        break;
      }
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (buffer.length < 4) {
          break;
        }
        length = buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (buffer.length < 10) {
          break;
        }
        const big = buffer.readBigUInt64BE(2);
        if (big > BigInt(this.maxPayload)) {
          throw new ProtocolError(1009, `a frame of ${big} bytes is too big`);
        }
        length = Number(big);
        offset = 10;
      }
      if (length > this.maxPayload) {
        throw new ProtocolError(1009, `a frame of ${length} bytes is too big`);
      }
      const masked = (buffer[1] & 0x80) !== 0;
      const keyOffset = offset;
      if (masked) {
        offset += 4;
      }
      if (buffer.length < offset + length) {
        break;
      }
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      if (masked) {
        for (let i = 0; i < payload.length; i += 1) {
          payload[i] ^= buffer[keyOffset + (i & 3)];
        }
      }
      frames.push({ fin: (buffer[0] & 0x80) !== 0, rsv: (buffer[0] >> 4) & 0x7, opcode: buffer[0] & 0x0f, masked, payload });
      this.buffer = buffer.subarray(offset + length);
    }
    return frames;
  }
}

// --- HTTP pieces of the handshake ------------------------------------------------------------------

export class HandshakeError extends Error {
  constructor(message, response = {}) {
    super(message);
    this.status = response.status ?? null;
    this.statusText = response.statusText ?? "";
    this.headers = response.headers ?? {};
    this.body = response.body ?? "";
    this.problem = null;
    try {
      this.problem = this.body ? JSON.parse(this.body) : null;
    } catch {
      // Not JSON.
    }
  }
}

function parseHead(head) {
  const [statusLine, ...lines] = head.split("\r\n");
  const match = /^HTTP\/1\.[01] (\d{3}) ?(.*)$/.exec(statusLine);
  if (!match) {
    throw new HandshakeError(`not an HTTP response: ${JSON.stringify(statusLine.slice(0, 80))}`);
  }
  const headers = {};
  for (const line of lines) {
    const colon = line.indexOf(":");
    if (colon > 0) {
      const name = line.slice(0, colon).trim().toLowerCase();
      const value = line.slice(colon + 1).trim();
      headers[name] = name in headers ? `${headers[name]}, ${value}` : value;
    }
  }
  return { status: Number(match[1]), statusText: match[2], headers };
}

// Collects the body of a refused handshake (Content-Length, chunked, or until the socket closes).
class BodyReader {
  constructor(headers, status) {
    this.chunks = [];
    this.size = 0;
    this.done = status === 204 || status === 304 || status < 200;
    this.chunked = /\bchunked\b/i.test(headers["transfer-encoding"] ?? "");
    this.length = this.chunked ? null : headers["content-length"] !== undefined ? Number(headers["content-length"]) : null;
    this.raw = Buffer.alloc(0);
    if (this.length === 0) {
      this.done = true;
    }
  }

  push(chunk) {
    if (this.done) {
      return;
    }
    if (this.chunked) {
      this.raw = Buffer.concat([this.raw, chunk]);
      for (;;) {
        const lineEnd = this.raw.indexOf("\r\n");
        if (lineEnd < 0) {
          return;
        }
        const size = Number.parseInt(this.raw.subarray(0, lineEnd).toString("latin1"), 16);
        if (!Number.isFinite(size)) {
          this.done = true;
          return;
        }
        if (size === 0) {
          this.done = true;
          return;
        }
        if (this.raw.length < lineEnd + 2 + size + 2) {
          return;
        }
        this.chunks.push(this.raw.subarray(lineEnd + 2, lineEnd + 2 + size));
        this.raw = this.raw.subarray(lineEnd + 2 + size + 2);
      }
    }
    this.chunks.push(chunk);
    this.size += chunk.length;
    if (this.length !== null && this.size >= this.length) {
      this.done = true;
    }
  }

  text() {
    const body = Buffer.concat(this.chunks);
    return (this.length !== null ? body.subarray(0, this.length) : body).toString("utf8");
  }
}

// --- The driver's side of the relay connection -----------------------------------------------------

// Events: "text" (text, { fragments }), "request" (message), "response" (message), "pong" (rtt ms),
// "ping" (payload of a protocol ping), "unknown" (text), "close" ({ code, reason, by }).
// `ready` resolves once connected (or rejects, with a HandshakeError when the relay refused);
// `closed` resolves with { code, reason, by } once the connection is over (by: server, client,
// network).
export class DriverConnection extends EventEmitter {
  constructor(options = {}) {
    super();
    this.endpoints = relayEndpoints(options.url ?? DEFAULT_URL);
    this.home = options.home ?? randomHex(16);
    this.secret = options.secret ?? randomHex(32);
    this.version = options.version ?? DEFAULT_VERSION;
    this.helloVersion = options.helloVersion ?? this.version;
    this.sendHello = options.hello !== false;
    this.onRequest = options.onRequest ?? null;
    this.log = options.log ?? (() => {});
    this.pingIntervalMs = options.pingIntervalMs ?? PING_INTERVAL_MS;
    this.silenceTimeoutMs = options.silenceTimeoutMs ?? SILENCE_TIMEOUT_MS;
    this.handshakeTimeoutMs = options.handshakeTimeoutMs ?? HANDSHAKE_TIMEOUT_MS;
    this.state = "connecting"; // connecting, handshake, refused, open, closing, closed
    this.key = randomBytes(16).toString("base64");
    this.requestHeaders = this.buildHeaders(options.headers ?? {});
    this.parser = new FrameParser();
    this.head = Buffer.alloc(0);
    this.message = null; // a fragmented message being assembled
    this.closeSent = false;
    this.lastPingAt = 0;
    this.stats = { requests: 0, responses: 0, pings: 0, pongs: 0 };
    this.timers = {};
    this.ready = new Promise((resolve, reject) => {
      this.resolveReady = resolve;
      this.rejectReady = reject;
    });
    this.closed = new Promise((resolve) => {
      this.resolveClosed = resolve;
    });
    this.openSocket();
  }

  get isOpen() {
    return this.state === "open";
  }

  // The headers of RELAY.md; `overrides` replaces them by name (any case), null removes one.
  buildHeaders(overrides) {
    const headers = {
      Host: this.endpoints.host,
      Upgrade: "websocket",
      Connection: "Upgrade",
      "Sec-WebSocket-Key": this.key,
      "Sec-WebSocket-Version": "13",
      Authorization: `Bearer ${this.secret}`,
      "X-DirectorLink-Home": this.home,
      "X-DirectorLink-Version": this.version,
      "User-Agent": `DirectorLink/${this.version}`,
    };
    for (const [name, value] of Object.entries(overrides)) {
      const existing = Object.keys(headers).find((header) => header.toLowerCase() === name.toLowerCase());
      if (existing) {
        delete headers[existing];
      }
      if (value !== null && value !== undefined) {
        headers[name] = String(value);
      }
    }
    return headers;
  }

  openSocket() {
    const { secure, hostname, port, connectPath } = this.endpoints;
    const socket = secure
      ? tls.connect({ host: hostname, port, servername: net.isIP(hostname) ? undefined : hostname, ALPNProtocols: ["http/1.1"] })
      : net.connect({ host: hostname, port });
    this.socket = socket;
    this.timers.handshake = setTimeout(() => {
      this.refuse(new Error(`no answer to the WebSocket handshake within ${this.handshakeTimeoutMs / 1000} s`));
    }, this.handshakeTimeoutMs);
    socket.once(secure ? "secureConnect" : "connect", () => {
      socket.setNoDelay(true);
      this.state = "handshake";
      const lines = Object.entries(this.requestHeaders).map(([name, value]) => `${name}: ${value}\r\n`);
      socket.write(`GET ${connectPath} HTTP/1.1\r\n${lines.join("")}\r\n`);
      this.log(`-> GET ${connectPath} (Upgrade: websocket, X-DirectorLink-Home: ${this.home})`);
    });
    socket.on("data", (chunk) => this.onData(chunk));
    socket.on("error", (error) => this.onSocketError(error));
    socket.on("close", () => this.onSocketClose());
  }

  onData(chunk) {
    switch (this.state) {
      case "handshake":
        return this.onHead(chunk);
      case "refused":
        this.body.push(chunk);
        return this.body.done ? this.finishRefusal() : undefined;
      case "open":
      case "closing":
        return this.onFrames(chunk);
      default:
        return undefined;
    }
  }

  onHead(chunk) {
    this.head = Buffer.concat([this.head, chunk]);
    const end = this.head.indexOf("\r\n\r\n");
    if (end < 0) {
      if (this.head.length > MAX_HEAD_BYTES) {
        this.refuse(new Error("the handshake answer's headers are too long"));
      }
      return;
    }
    const rest = this.head.subarray(end + 4);
    let response;
    try {
      response = parseHead(this.head.subarray(0, end).toString("latin1"));
    } catch (error) {
      this.refuse(error);
      return;
    }
    this.response = response;
    this.head = Buffer.alloc(0);
    if (response.status !== 101) {
      this.state = "refused";
      this.body = new BodyReader(response.headers, response.status);
      this.body.push(rest);
      if (this.body.done) {
        this.finishRefusal();
      }
      return;
    }
    this.accept(rest);
  }

  finishRefusal() {
    const { status, statusText, headers } = this.response;
    const body = this.body.text();
    this.log(`<- ${status} ${statusText} ${body}`);
    this.refuse(new HandshakeError(`the relay refused the connection: ${status} ${statusText}`, { status, statusText, headers, body }));
  }

  accept(rest) {
    const { headers, statusText } = this.response;
    const expected = websocketAccept(this.key);
    const problems = [];
    if (headers["sec-websocket-accept"] !== expected) {
      problems.push(`Sec-WebSocket-Accept is ${JSON.stringify(headers["sec-websocket-accept"] ?? null)}, expected ${expected}`);
    }
    if ((headers.upgrade ?? "").toLowerCase() !== "websocket") {
      problems.push(`Upgrade is ${JSON.stringify(headers.upgrade ?? null)}`);
    }
    if (!/(^|,)\s*upgrade\s*(,|$)/i.test(headers.connection ?? "")) {
      problems.push(`Connection is ${JSON.stringify(headers.connection ?? null)}`);
    }
    if (headers["sec-websocket-extensions"]) {
      problems.push(`the relay chose extensions that were not offered: ${headers["sec-websocket-extensions"]}`);
    }
    if (problems.length > 0) {
      this.refuse(new HandshakeError(`bad 101 answer: ${problems.join("; ")}`, { ...this.response, body: "" }));
      return;
    }
    clearTimeout(this.timers.handshake);
    this.state = "open";
    this.log(`<- 101 ${statusText} (Sec-WebSocket-Accept verified)`);
    this.resetSilenceTimer();
    if (this.pingIntervalMs > 0) {
      this.timers.ping = setInterval(() => this.ping(), this.pingIntervalMs);
      this.timers.ping.unref?.();
    }
    if (this.sendHello) {
      this.sendJson({ type: "hello", home: this.home, version: this.helloVersion });
      this.log(`-> hello (version ${this.helloVersion})`);
    }
    this.resolveReady(this);
    if (rest.length > 0) {
      // Frames that came with the 101: handle them once the caller has the connection.
      this.socket.pause();
      setImmediate(() => {
        this.onFrames(rest);
        this.socket.resume();
      });
    }
  }

  refuse(error) {
    if (this.state === "closed") {
      return;
    }
    this.finish({ code: 1006, reason: error.message, by: "client" }, error);
  }

  onFrames(chunk) {
    this.resetSilenceTimer();
    let frames;
    try {
      frames = this.parser.push(chunk);
    } catch (error) {
      this.fail(error.closeCode ?? 1002, error.message);
      return;
    }
    for (const frame of frames) {
      if (this.state === "closed") {
        return;
      }
      this.onFrame(frame);
    }
  }

  onFrame(frame) {
    if (frame.rsv !== 0) {
      return this.fail(1002, "reserved bits are set, but no extension was negotiated");
    }
    if (frame.masked) {
      return this.fail(1002, "the relay masked a frame (RFC 6455: servers must not)");
    }
    if (frame.opcode >= 0x8) {
      if (!frame.fin || frame.payload.length > 125) {
        return this.fail(1002, "a control frame is fragmented or longer than 125 bytes");
      }
      switch (frame.opcode) {
        case Opcode.CLOSE:
          return this.onCloseFrame(frame.payload);
        case Opcode.PING:
          this.log(`<- protocol ping (${frame.payload.length} bytes), answered with a protocol pong`);
          this.sendFrame(Opcode.PONG, frame.payload);
          this.emit("ping", frame.payload);
          return undefined;
        case Opcode.PONG:
          this.log("<- protocol pong");
          return undefined;
        default:
          return this.fail(1002, `unknown control opcode ${frame.opcode}`);
      }
    }
    if (frame.opcode === Opcode.CONTINUATION) {
      if (!this.message) {
        return this.fail(1002, "a continuation frame without a message to continue");
      }
    } else if (frame.opcode === Opcode.TEXT || frame.opcode === Opcode.BINARY) {
      if (this.message) {
        return this.fail(1002, "a new message started before the previous one ended");
      }
      this.message = { opcode: frame.opcode, parts: [], size: 0 };
    } else {
      return this.fail(1002, `unknown opcode ${frame.opcode}`);
    }
    this.message.parts.push(frame.payload);
    this.message.size += frame.payload.length;
    if (this.message.size > MAX_MESSAGE_BYTES) {
      return this.fail(1009, "the message is too big");
    }
    if (!frame.fin) {
      return undefined;
    }
    const { opcode, parts } = this.message;
    this.message = null;
    const data = Buffer.concat(parts);
    if (opcode === Opcode.BINARY) {
      this.log(`<- binary message (${data.length} bytes), ignored: RELAY.md uses text frames only`);
      return undefined;
    }
    let text;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(data);
    } catch {
      return this.fail(1007, "a text message is not valid UTF-8");
    }
    this.emit("text", text, { fragments: parts.length });
    return this.onText(text, parts.length);
  }

  onText(text, fragments) {
    if (text === "pong") {
      this.stats.pongs += 1;
      const rtt = this.lastPingAt ? Date.now() - this.lastPingAt : null;
      this.log(`<- pong${rtt === null ? "" : ` (${rtt} ms)`}`);
      this.emit("pong", rtt);
      return;
    }
    let message = null;
    try {
      message = JSON.parse(text);
    } catch {
      // Not JSON.
    }
    if (message?.type === "request") {
      if (fragments > 1) {
        this.log(`   (the request came in ${fragments} fragments)`);
      }
      this.handleRequest(message).catch((error) => this.log(`!! answering ${message.id} failed: ${error.message}`));
      return;
    }
    this.log(`<- unexpected message, ignored: ${text.slice(0, 200)}`);
    this.emit("unknown", text);
  }

  async handleRequest(request) {
    this.stats.requests += 1;
    this.log(`<- request ${request.id} ${request.method} ${request.path}`);
    this.emit("request", request);
    if (!this.onRequest) {
      return;
    }
    let answer;
    try {
      answer = await this.onRequest(request, this);
    } catch (error) {
      answer = {
        status: 500,
        content_type: "application/problem+json",
        body: JSON.stringify({ type: "about:blank", title: "Internal Server Error", status: 500, code: "INTERNAL_ERROR", detail: String(error?.message ?? error) }),
      };
    }
    if (answer !== null && answer !== undefined) {
      this.respond(request.id, answer);
    }
  }

  // Sends a `response`. `answer` has the fields of RELAY.md: status, content_type and body or
  // body_base64. `fragmentSize` splits the message into frames of that many bytes.
  respond(id, answer, { fragmentSize } = {}) {
    const message = { type: "response", id, status: answer.status ?? 200, content_type: answer.content_type ?? "application/json; charset=utf-8" };
    if (answer.body_base64 !== undefined) {
      message.body_base64 = answer.body_base64;
    } else {
      message.body = answer.body ?? null;
    }
    if (!this.sendJson(message, { fragmentSize })) {
      this.log(`   (could not answer ${id}: the connection is ${this.state})`);
      return false;
    }
    this.stats.responses += 1;
    const size = message.body_base64 !== undefined ? `${Buffer.byteLength(message.body_base64, "base64")} bytes as body_base64` : `${Buffer.byteLength(message.body ?? "")} bytes`;
    this.log(`-> response ${id} ${message.status} ${message.content_type} (${size})`);
    this.emit("response", message);
    return true;
  }

  ping() {
    if (this.sendText("ping")) {
      this.stats.pings += 1;
      this.lastPingAt = Date.now();
      this.log("-> ping");
    }
  }

  sendText(text, { fragmentSize } = {}) {
    const data = Buffer.from(text, "utf8");
    if (!fragmentSize || data.length <= fragmentSize) {
      return this.sendFrame(Opcode.TEXT, data);
    }
    let ok = true;
    for (let offset = 0; offset < data.length; offset += fragmentSize) {
      const opcode = offset === 0 ? Opcode.TEXT : Opcode.CONTINUATION;
      ok = this.sendFrame(opcode, data.subarray(offset, offset + fragmentSize), { fin: offset + fragmentSize >= data.length }) && ok;
    }
    return ok;
  }

  sendJson(value, options) {
    return this.sendText(JSON.stringify(value), options);
  }

  sendFrame(opcode, payload, { fin = true } = {}) {
    if (this.state !== "open" || this.closeSent || !this.socket.writable) {
      return false;
    }
    this.socket.write(encodeFrame(opcode, payload, { fin, mask: true }));
    return true;
  }

  onCloseFrame(payload) {
    const code = payload.length >= 2 ? payload.readUInt16BE(0) : 1005;
    const reason = payload.length > 2 ? payload.subarray(2).toString("utf8") : "";
    if (this.closeSent) {
      this.log(`<- close ${code}${reason ? ` ${reason}` : ""} (closing handshake complete)`);
      this.finish({ ...this.closeRequested, by: "client", answer: { code, reason } });
    } else {
      this.log(`<- close ${code}${reason ? ` ${reason}` : ""}`);
      // Echo the status code (RFC 6455 section 5.5.1); the relay then ends the TCP connection.
      this.sendFrame(Opcode.CLOSE, payload.length >= 2 ? payload.subarray(0, 2) : Buffer.alloc(0));
      this.closeSent = true;
      this.log(`-> close ${payload.length >= 2 ? code : "(no code)"} (echo)`);
      this.finish({ code, reason, by: "server" });
    }
  }

  // Starts the closing handshake; resolves with `closed`.
  close(code = 1000, reason = "") {
    if (this.state === "open") {
      const payload = Buffer.alloc(2 + Buffer.byteLength(reason));
      payload.writeUInt16BE(code, 0);
      payload.write(reason, 2);
      this.sendFrame(Opcode.CLOSE, payload);
      this.closeSent = true;
      this.closeRequested = { code, reason };
      this.state = "closing";
      this.log(`-> close ${code}${reason ? ` ${reason}` : ""}`);
      this.timers.close = setTimeout(() => {
        this.finish({ code, reason, by: "client", answer: null });
      }, CLOSE_TIMEOUT_MS);
    } else if (this.state !== "closing" && this.state !== "closed") {
      this.refuse(new Error("closed before the connection was open"));
    }
    return this.closed;
  }

  // Drops the TCP connection without a closing handshake.
  destroy(reason = "dropped") {
    this.finish({ code: 1006, reason, by: "client" });
  }

  fail(code, reason) {
    this.log(`!! protocol error: ${reason}`);
    if (this.state === "open") {
      const payload = Buffer.alloc(2 + Buffer.byteLength(reason));
      payload.writeUInt16BE(code, 0);
      payload.write(reason, 2);
      this.sendFrame(Opcode.CLOSE, payload);
      this.closeSent = true;
    }
    this.finish({ code, reason, by: "client" });
  }

  resetSilenceTimer() {
    clearTimeout(this.timers.silence);
    if (this.silenceTimeoutMs > 0) {
      this.timers.silence = setTimeout(() => {
        this.log(`!! nothing heard for ${this.silenceTimeoutMs / 1000} s: dropping the connection`);
        this.finish({ code: 1006, reason: "silence", by: "client" });
      }, this.silenceTimeoutMs);
      this.timers.silence.unref?.();
    }
  }

  onSocketError(error) {
    this.log(`!! ${error.message}`);
    this.finish({ code: 1006, reason: error.message, by: "network" }, error);
  }

  onSocketClose() {
    if (this.state === "refused" && !this.body.done) {
      this.body.done = true;
      this.finishRefusal();
      return;
    }
    if (this.state !== "closed") {
      const error = this.state === "open" || this.state === "closing" ? null : new Error("the connection closed during the handshake");
      this.log("!! the TCP connection closed");
      this.finish({ code: 1006, reason: "connection lost", by: "network" }, error);
    }
  }

  finish(result, error = null) {
    if (this.state === "closed") {
      return;
    }
    const wasOpen = this.state === "open" || this.state === "closing";
    this.state = "closed";
    clearTimeout(this.timers.handshake);
    clearTimeout(this.timers.silence);
    clearTimeout(this.timers.close);
    clearInterval(this.timers.ping);
    if (wasOpen) {
      this.socket.end();
      setTimeout(() => this.socket.destroy(), 1000).unref?.();
    } else {
      this.socket.destroy();
      this.rejectReady(error ?? new Error(result.reason));
    }
    this.resolveClosed(result);
    this.emit("close", result);
  }
}

// Connects as the driver; resolves with the open DriverConnection.
export async function connectDriver(options = {}) {
  const connection = new DriverConnection(options);
  await connection.ready;
  return connection;
}

// The canned answer of driver mode: a JSON echo of the request, steered by smoke_* parameters.
export async function cannedAnswer(request, { home } = {}) {
  const query = request.path.includes("?") ? request.path.slice(request.path.indexOf("?") + 1) : "";
  const params = new URLSearchParams(query);
  const delay = Number(params.get("smoke_delay_ms") ?? 0);
  if (delay > 0) {
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
  const status = Number(params.get("smoke_status") ?? 200) || 200;
  if (params.get("smoke_binary") === "1") {
    const bytes = Buffer.from(Array.from({ length: 256 }, (_, i) => i));
    return { status, content_type: "application/octet-stream", body_base64: bytes.toString("base64") };
  }
  const body = { relayed: true, home: home ?? null, method: request.method, path: request.path, id: request.id, answered_at: new Date().toISOString() };
  return { status, content_type: "application/json; charset=utf-8", body: JSON.stringify(body) };
}

// --- Client of the test endpoints ------------------------------------------------------------------

// GET (or `method`) /test/homes/{home}{path} with the test token.
export async function callTestEndpoint({ url = DEFAULT_URL, token, home, path: apiPath = "/status", method = "GET", headers = {} }) {
  const target = `${relayEndpoints(url).http}/test/homes/${home}${apiPath}`;
  const response = await fetch(target, {
    method,
    headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...headers },
  });
  const body = Buffer.from(await response.arrayBuffer());
  const contentType = response.headers.get("content-type") ?? "";
  let json = null;
  if (/[/+]json\b/i.test(contentType)) {
    try {
      json = JSON.parse(body.toString("utf8"));
    } catch {
      // Not valid JSON.
    }
  }
  return { url: target, status: response.status, statusText: response.statusText, headers: response.headers, contentType, body, text: body.toString("utf8"), json };
}

// --- Command line ------------------------------------------------------------------------------------

const USAGE = `DirectorLink relay smoke test (docs/RELAY.md)

  node scripts/relay_smoke.mjs [driver] [--url ws://127.0.0.1:8787] [--home <32 hex>] [--secret <64 hex>]
                               [--version ${DEFAULT_VERSION}] [--once]
  node scripts/relay_smoke.mjs status --home <id> [--url ...] [--token <TEST_TOKEN>]
  node scripts/relay_smoke.mjs get <path> --home <id> [--url ...] [--token <TEST_TOKEN>] [--out <file>]
`;

function timestamp() {
  return new Date().toISOString().slice(11, 23);
}

function print(line) {
  console.log(`${timestamp()} ${line}`);
}

async function runDriver(values) {
  const endpoints = relayEndpoints(values.url ?? DEFAULT_URL);
  const home = values.home ?? randomHex(16);
  const secret = values.secret ?? randomHex(32);
  const version = values.version ?? DEFAULT_VERSION;
  if (!/^[0-9a-f]{32}$/.test(home)) {
    console.log("warning: --home is not 32 lowercase hex characters; the relay will answer 400");
  }
  if (!/^[0-9a-f]{64}$/i.test(secret)) {
    console.log("warning: --secret is not 64 hex characters; the relay will answer 400");
  }
  console.log("DirectorLink relay smoke driver");
  console.log(`  relay    ${endpoints.websocket}`);
  console.log(`  home     ${home}${values.home ? "" : "   (new; reuse it with --home)"}`);
  console.log(`  secret   ${secret}${values.secret ? "" : "   (new; reuse it with --secret)"}`);
  console.log(`  version  ${version}`);
  console.log(`  try      node scripts/relay_smoke.mjs get /v1/system --url ${endpoints.http} --home ${home} --token <TEST_TOKEN>`);
  console.log("");

  let current = null;
  let stopping = false;
  process.once("SIGINT", () => {
    stopping = true;
    print("stopping");
    if (current?.isOpen) {
      current.close(1000, "stopped");
    } else {
      process.exit(130);
    }
  });

  let failures = 0;
  for (;;) {
    let answered = false;
    try {
      current = await connectDriver({
        url: values.url ?? DEFAULT_URL,
        home,
        secret,
        version,
        log: print,
        onRequest: async (request, connection) => {
          const answer = await cannedAnswer(request, { home });
          connection.respond(request.id, answer);
          if (values.once) {
            answered = true;
            await connection.close(1000, "done");
          }
          return null;
        },
      });
      failures = 0;
      const result = await current.closed;
      if (values.once) {
        return answered ? 0 : 1;
      }
      if (stopping) {
        return 0;
      }
      if (result.by === "server" && result.code === 4000) {
        print("replaced by a newer connection for this home; not reconnecting");
        return 3;
      }
    } catch (error) {
      if (error instanceof HandshakeError && (error.status === 400 || error.status === 401)) {
        print(`refused (${error.problem?.code ?? error.status}); not retrying`);
        return 1;
      }
      print(`could not connect: ${error.message}`);
      if (values.once || stopping) {
        return 1;
      }
    }
    const delay = RECONNECT_DELAYS_S[Math.min(failures, RECONNECT_DELAYS_S.length - 1)];
    failures += 1;
    print(`reconnecting in ${delay} s`);
    await new Promise((resolve) => setTimeout(resolve, delay * 1000));
    if (stopping) {
      return 0;
    }
  }
}

async function runClient(values, apiPath) {
  const token = values.token ?? process.env.TEST_TOKEN;
  if (!values.home) {
    console.error("--home <home_id> is required");
    return 2;
  }
  if (!token) {
    console.error("warning: no --token (or TEST_TOKEN in the environment); the relay will answer 401");
  }
  const started = Date.now();
  const result = await callTestEndpoint({ url: values.url ?? DEFAULT_URL, token, home: values.home, path: apiPath });
  console.log(`GET ${result.url}`);
  console.log(`${result.status} ${result.statusText} in ${Date.now() - started} ms`);
  for (const name of ["content-type", "content-length", "cache-control"]) {
    const value = result.headers.get(name);
    if (value) {
      console.log(`${name}: ${value}`);
    }
  }
  console.log("");
  if (values.out) {
    writeFileSync(values.out, result.body);
    console.log(`${result.body.length} bytes written to ${values.out}`);
  } else if (result.json !== null) {
    console.log(JSON.stringify(result.json, null, 2));
  } else if (/^text\/|charset=/i.test(result.contentType)) {
    console.log(result.text);
  } else {
    console.log(`${result.body.length} bytes of ${result.contentType || "data"} (save them with --out <file>)`);
  }
  return result.status >= 200 && result.status < 300 ? 0 : 1;
}

async function main(argv) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      options: {
        url: { type: "string" },
        home: { type: "string" },
        secret: { type: "string" },
        token: { type: "string" },
        version: { type: "string" },
        once: { type: "boolean" },
        out: { type: "string" },
        help: { type: "boolean", short: "h" },
      },
    });
  } catch (error) {
    console.error(`${error.message}\n\n${USAGE}`);
    return 2;
  }
  const { values, positionals } = parsed;
  if (values.help) {
    console.log(USAGE);
    return 0;
  }
  const [mode = "driver", argument] = positionals;
  switch (mode) {
    case "driver":
      return runDriver(values);
    case "status":
      return runClient(values, "/status");
    case "get":
      if (!argument) {
        console.error(`get needs an API path such as /v1/system\n\n${USAGE}`);
        return 2;
      }
      return runClient(values, argument.startsWith("/") ? argument : `/${argument}`);
    default:
      console.error(`unknown mode ${JSON.stringify(mode)}\n\n${USAGE}`);
      return 2;
  }
}

function invokedDirectly() {
  if (!process.argv[1]) {
    return false;
  }
  const self = fileURLToPath(import.meta.url);
  const invoked = path.resolve(process.argv[1]);
  return process.platform === "win32" ? self.toLowerCase() === invoked.toLowerCase() : self === invoked;
}

if (invokedDirectly()) {
  main(process.argv.slice(2)).then(
    (code) => {
      process.exitCode = code;
    },
    (error) => {
      console.error(error);
      process.exitCode = 1;
    },
  );
}
