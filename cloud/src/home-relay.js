// One Durable Object per home (named by home_id): holds the driver's WebSocket and relays requests
// over it (docs/RELAY.md): version 0 test requests, and the sealed messages of accounts
// (docs/ACCOUNTS.md), which it passes on without being able to read them.
//
// The socket uses the WebSocket Hibernation API: while nothing is being relayed, the object can be
// evicted from memory and the connection stays open without duration charges. The keep-alive
// "ping" is answered "pong" by the runtime itself (setWebSocketAutoResponse), so it never wakes the
// object; getWebSocketAutoResponseTimestamp() tells when the last one was answered. What has to
// survive hibernation lives in the socket's attachment or in storage:
//
//   attachment  { conn, home, connectedAt, version, lastSeen }        per socket (milliseconds)
//   storage     secret_sha256                                         SHA-256 hex of the home_secret,
//                                                                     trusted on first use
//               connected_at, disconnected_at, last_seen, version     for the status (ISO times)

import { DurableObject } from "cloudflare:workers";
import { bearerToken, json, problem, sameSecret, sha256Hex } from "./http.js";

const DRIVER = "driver";
const OPEN = 1; // WebSocket readyState
const DEFAULT_TIMEOUT_MS = 15000;
const NULL_BODY_STATUS = new Set([204, 205, 304]);

export class HomeRelay extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    // Relayed requests waiting for the driver: id -> { resolve, timer, conn }. Memory is enough:
    // while a request waits, its caller's fetch keeps the object awake, so hibernation never
    // drops this map with anything in it.
    this.pending = new Map();
  }

  // Called by the Worker (index.js), which has already checked the request.
  async fetch(request) {
    const homeId = request.headers.get("X-DirectorLink-Home") ?? "";
    switch (new URL(request.url).pathname) {
      case "/relay/connect":
        return this.connect(request, homeId);
      case "/status":
        return json(await this.status());
      case "/forward":
        return this.forward(request.headers.get("X-DirectorLink-Path") ?? "", homeId);
      case "/message":
        return this.message(await request.json(), homeId);
      default:
        return problem(404, "NOT_FOUND", "Unknown relay operation");
    }
  }

  // --- The driver's connection ---------------------------------------------------------------

  async connect(request, homeId) {
    const secret = bearerToken(request);
    if (!secret) {
      return problem(400, "INVALID_HOME_SECRET", "Authorization must be Bearer <home_secret>");
    }
    // Trust on first use: the first secret seen for this home is the only one accepted afterwards.
    const hash = await sha256Hex(secret.toLowerCase());
    const known = await this.ctx.storage.get("secret_sha256");
    if (known === undefined) {
      await this.ctx.storage.put("secret_sha256", hash);
      log("home_registered", { home: homeId });
    } else if (!(await sameSecret(hash, known))) {
      log("wrong_secret", { home: homeId });
      return problem(401, "WRONG_HOME_SECRET", "This home_id is registered with a different home_secret");
    }

    // One driver connection per home: a new one replaces the previous.
    let replaced = 0;
    for (const old of this.ctx.getWebSockets(DRIVER)) {
      try {
        old.close(4000, "replaced");
        replaced += 1;
      } catch {
        // Already closing.
      }
    }

    const now = Date.now();
    const version = cleanVersion(request.headers.get("X-DirectorLink-Version"));
    const [client, server] = Object.values(new WebSocketPair());
    this.ctx.acceptWebSocket(server, [DRIVER]);
    server.serializeAttachment({ conn: crypto.randomUUID(), home: homeId, connectedAt: now, version, lastSeen: now });
    const at = iso(now);
    await this.ctx.storage.put({ connected_at: at, last_seen: at, version });
    log("driver_connected", { home: homeId, version, replaced });
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws, message) {
    const attachment = ws.deserializeAttachment() ?? {};
    attachment.lastSeen = Date.now();
    let data = null;
    if (typeof message === "string") {
      try {
        data = JSON.parse(message);
      } catch {
        // Not JSON; ignored below.
      }
    }
    const type = data?.type;
    if (type === "hello") {
      attachment.version = cleanVersion(data.version) ?? attachment.version ?? null;
    }
    ws.serializeAttachment(attachment);

    switch (type) {
      case "hello":
        await this.ctx.storage.put({ version: attachment.version, last_seen: iso(attachment.lastSeen) });
        if (data.home !== attachment.home) {
          log("hello_home_mismatch", { home: attachment.home, hello_home: String(data.home) });
        }
        log("driver_hello", { home: attachment.home, version: attachment.version });
        return;
      case "response":
      case "e2e":
      case "join_result":
      case "claim_result":
        if (typeof data.id !== "string" || !this.settle(data.id, { message: data })) {
          log("response_ignored", { home: attachment.home, type, id: data.id ?? null, why: "no request is waiting for this id" });
        }
        return;
      default:
        log("message_ignored", {
          home: attachment.home,
          type: type ?? null,
          message: typeof message === "string" ? message.slice(0, 100) : `${message.byteLength} binary bytes`,
        });
    }
  }

  async webSocketClose(ws, code, reason) {
    await this.disconnected(ws, `closed with ${code}${reason ? ` ${reason}` : ""}`);
    // Completes the closing handshake on runtimes that do not answer the close frame themselves.
    try {
      ws.close(code === 1000 || (code >= 3000 && code <= 4999) ? code : 1000, "closed");
    } catch {
      // Already answered.
    }
  }

  async webSocketError(ws, error) {
    await this.disconnected(ws, `error: ${error?.message ?? error}`);
  }

  async disconnected(ws, why) {
    const attachment = ws.deserializeAttachment() ?? {};
    for (const [id, entry] of this.pending) {
      if (entry.conn === attachment.conn) {
        this.settle(id, { failed: `The home disconnected before it answered (${why})` });
      }
    }
    if (this.driverSocket({ except: attachment.conn })) {
      log("driver_replaced", { home: attachment.home, why }); // a newer connection took over
      return;
    }
    await this.ctx.storage.put({ disconnected_at: iso(Date.now()), last_seen: iso(this.lastSeen(ws)) });
    log("driver_disconnected", { home: attachment.home, why });
  }

  // The live driver socket (the newest, while a replaced one is still closing), or null.
  driverSocket({ except } = {}) {
    let newest = null;
    let newestAt = -Infinity;
    for (const ws of this.ctx.getWebSockets(DRIVER)) {
      if (ws.readyState !== OPEN) {
        continue;
      }
      const { conn, connectedAt = 0 } = ws.deserializeAttachment() ?? {};
      if (except !== undefined && conn === except) {
        continue;
      }
      if (connectedAt >= newestAt) {
        newest = ws;
        newestAt = connectedAt;
      }
    }
    return newest;
  }

  // The last time the driver was heard from: its last message, or the last auto-answered ping
  // (those never reach webSocketMessage).
  lastSeen(ws) {
    const { lastSeen = 0 } = ws.deserializeAttachment() ?? {};
    const ping = this.ctx.getWebSocketAutoResponseTimestamp(ws);
    return Math.max(lastSeen, ping ? ping.getTime() : 0);
  }

  // --- Test endpoints ------------------------------------------------------------------------

  async status() {
    const ws = this.driverSocket();
    if (ws) {
      const { connectedAt, version } = ws.deserializeAttachment() ?? {};
      return { connected: true, since: iso(connectedAt), version: version ?? null, last_seen: iso(this.lastSeen(ws)) };
    }
    const stored = await this.ctx.storage.get(["connected_at", "disconnected_at", "last_seen", "version"]);
    const connectedAt = stored.get("connected_at");
    const disconnectedAt = stored.get("disconnected_at");
    const lastSeen = stored.get("last_seen") ?? null;
    // Offline since the recorded disconnect; when none was recorded after the last connect (the
    // relay restarted under the connection), since the driver was last heard from.
    const since = disconnectedAt && (!connectedAt || disconnectedAt >= connectedAt) ? disconnectedAt : lastSeen;
    return { connected: false, since, version: stored.get("version") ?? null, last_seen: lastSeen };
  }

  async forward(path, homeId) {
    const ws = this.driverSocket();
    if (!ws) {
      return problem(503, "HOME_OFFLINE", "The home is not connected to the relay");
    }
    const { conn } = ws.deserializeAttachment() ?? {};
    const id = crypto.randomUUID();
    const timeoutMs = requestTimeoutMs(this.env);
    const started = Date.now();
    const outcome = await new Promise((resolve) => {
      const timer = setTimeout(() => this.settle(id, { timeout: true }), timeoutMs);
      this.pending.set(id, { resolve, timer, conn });
      try {
        ws.send(JSON.stringify({ type: "request", id, method: "GET", path, body: null }));
      } catch (error) {
        this.settle(id, { failed: `The home's connection could not be written (${error?.message ?? error})` });
      }
    });
    const ms = Date.now() - started;
    if (outcome.timeout) {
      log("request_timeout", { home: homeId, id, path, ms });
      return problem(504, "HOME_TIMEOUT", `The home did not answer within ${timeoutMs / 1000} s`);
    }
    if (outcome.failed) {
      log("request_failed", { home: homeId, id, path, ms, why: outcome.failed });
      return problem(502, "HOME_DISCONNECTED", outcome.failed);
    }
    const response = relayedResponse(outcome.message);
    log("request_relayed", { home: homeId, id, path, status: response.status, ms });
    return response;
  }

  // Sends one account message (e2e, join or claim) and waits for the driver's reply with the same
  // id. The reply goes back as it came: sealed contents stay sealed.
  async message(message, homeId) {
    if (!message || !["e2e", "join", "claim"].includes(message.type)) {
      return problem(400, "INVALID_MESSAGE", "Only e2e, join and claim messages are relayed");
    }
    const ws = this.driverSocket();
    if (!ws) {
      return problem(503, "HOME_OFFLINE", "The home is not connected to the relay");
    }
    const { conn } = ws.deserializeAttachment() ?? {};
    const id = crypto.randomUUID();
    const timeoutMs = requestTimeoutMs(this.env);
    const started = Date.now();
    const outcome = await new Promise((resolve) => {
      const timer = setTimeout(() => this.settle(id, { timeout: true }), timeoutMs);
      this.pending.set(id, { resolve, timer, conn });
      try {
        ws.send(JSON.stringify({ ...message, id }));
      } catch (error) {
        this.settle(id, { failed: `The home's connection could not be written (${error?.message ?? error})` });
      }
    });
    const ms = Date.now() - started;
    if (outcome.timeout) {
      log("message_timeout", { home: homeId, type: message.type, ms });
      return problem(504, "HOME_TIMEOUT", `The home did not answer within ${timeoutMs / 1000} s`);
    }
    if (outcome.failed) {
      log("message_failed", { home: homeId, type: message.type, ms, why: outcome.failed });
      return problem(502, "HOME_DISCONNECTED", outcome.failed);
    }
    const { id: _id, ...reply } = outcome.message;
    log("message_relayed", { home: homeId, type: message.type, ok: reply.ok ?? Boolean(reply.envelope), code: reply.code ?? null, ms });
    return json(reply);
  }

  settle(id, outcome) {
    const entry = this.pending.get(id);
    if (!entry) {
      return false;
    }
    this.pending.delete(id);
    clearTimeout(entry.timer);
    entry.resolve(outcome);
    return true;
  }
}

// The driver's `response` message as the HTTP answer: its status, content type and body, byte
// for byte (`body_base64` for binary answers such as camera pictures).
function relayedResponse(message) {
  const { status } = message;
  if (!Number.isInteger(status) || status < 200 || status > 599) {
    return invalidResponse(`status must be a whole number from 200 to 599, not ${JSON.stringify(status)}`);
  }
  let body = null;
  if (message.body_base64 !== undefined && message.body_base64 !== null) {
    if (typeof message.body_base64 !== "string") {
      return invalidResponse("body_base64 must be a string");
    }
    try {
      body = decodeBase64(message.body_base64);
    } catch {
      return invalidResponse("body_base64 is not valid base64");
    }
  } else if (typeof message.body === "string") {
    body = message.body;
  } else if (message.body !== undefined && message.body !== null) {
    return invalidResponse("body must be a string or null");
  }
  const headers = { "cache-control": "no-store" };
  if (typeof message.content_type === "string" && message.content_type !== "") {
    headers["content-type"] = message.content_type;
  }
  try {
    return new Response(NULL_BODY_STATUS.has(status) ? null : body, { status, headers });
  } catch (error) {
    return invalidResponse(error?.message ?? String(error));
  }
}

function invalidResponse(detail) {
  return problem(502, "INVALID_RESPONSE", `The home sent an invalid response: ${detail}`);
}

function decodeBase64(text) {
  // Encoders that wrap lines (MIME, OpenSSL) are fine: whitespace is not part of the data.
  const binary = atob(text.replace(/[\t\n\f\r ]+/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function requestTimeoutMs(env) {
  const value = Number(env.REQUEST_TIMEOUT_MS);
  return Number.isInteger(value) && value > 0 ? value : DEFAULT_TIMEOUT_MS;
}

function cleanVersion(value) {
  if (typeof value !== "string") {
    return null;
  }
  const version = value.trim();
  return /^[\x21-\x7e]{1,64}$/.test(version) ? version : null;
}

function iso(ms) {
  return ms ? new Date(ms).toISOString() : null;
}

function log(event, fields) {
  console.log(JSON.stringify({ event, ...fields }));
}
