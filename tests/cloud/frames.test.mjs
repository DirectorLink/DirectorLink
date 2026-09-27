// scripts/relay_smoke.mjs byte by byte, against a fake relay written with node:net: the handshake
// it sends, the Sec-WebSocket-Accept check, and server frames the real relay seldom sends
// (fragments, protocol pings, 64-bit lengths, masked frames, close codes). No wrangler needed.
//   node --test tests/cloud/frames.test.mjs

import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { once } from "node:events";
import net from "node:net";
import { test } from "node:test";

import { FrameParser, HandshakeError, Opcode, connectDriver, encodeFrame, websocketAccept } from "../../scripts/relay_smoke.mjs";

// A fake relay; `script(peer)` drives each connection it accepts.
async function fakeRelay(script) {
  const peers = [];
  const server = net.createServer((socket) => {
    const peer = new Peer(socket);
    peers.push(peer);
    Promise.resolve(script(peer)).catch((error) => {
      peer.error = error;
      socket.destroy();
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  return {
    url: `ws://127.0.0.1:${server.address().port}`,
    peers,
    async close() {
      for (const peer of peers) {
        peer.socket.destroy();
        if (peer.error) {
          throw peer.error;
        }
      }
      server.close();
      await once(server, "close");
    },
  };
}

// The relay's side of one connection: the handshake request, then the client's frames.
class Peer {
  constructor(socket) {
    this.socket = socket;
    this.parser = new FrameParser();
    this.head = Buffer.alloc(0);
    this.frames = [];
    this.waiting = [];
    this.request = new Promise((resolve) => {
      this.resolveRequest = resolve;
    });
    socket.on("data", (chunk) => this.onData(chunk));
    socket.on("error", () => {});
  }

  onData(chunk) {
    if (!this.handshake) {
      this.head = Buffer.concat([this.head, chunk]);
      const end = this.head.indexOf("\r\n\r\n");
      if (end < 0) {
        return;
      }
      const [requestLine, ...lines] = this.head.subarray(0, end).toString("latin1").split("\r\n");
      const headers = new Map(lines.map((line) => [line.slice(0, line.indexOf(":")).toLowerCase(), line.slice(line.indexOf(":") + 1).trim()]));
      this.handshake = { requestLine, headers };
      this.resolveRequest(this.handshake);
      chunk = this.head.subarray(end + 4);
    }
    for (const frame of this.parser.push(chunk)) {
      const waiter = this.waiting.shift();
      if (waiter) {
        waiter(frame);
      } else {
        this.frames.push(frame);
      }
    }
  }

  nextFrame(ms = 3000) {
    if (this.frames.length > 0) {
      return Promise.resolve(this.frames.shift());
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("no frame from the client")), ms);
      this.waiting.push((frame) => {
        clearTimeout(timer);
        resolve(frame);
      });
    });
  }

  async accept(acceptValue) {
    const { headers } = await this.request;
    const accept = acceptValue ?? websocketAccept(headers.get("sec-websocket-key"));
    this.socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  }

  send(opcode, payload, options = {}) {
    this.socket.write(encodeFrame(opcode, payload, { mask: false, ...options }));
  }
}

function closePayload(code, reason = "") {
  const payload = Buffer.alloc(2 + Buffer.byteLength(reason));
  payload.writeUInt16BE(code, 0);
  payload.write(reason, 2);
  return payload;
}

test("frames round-trip with 7-bit, 16-bit and 64-bit lengths, masked or not", () => {
  for (const length of [0, 1, 125, 126, 65535, 65536, 70000]) {
    for (const mask of [true, false]) {
      const payload = randomBytes(length);
      const frame = encodeFrame(Opcode.BINARY, payload, { mask });
      const extended = length < 126 ? 0 : length < 65536 ? 2 : 8;
      assert.equal(frame.length, 2 + extended + (mask ? 4 : 0) + length);
      assert.equal(frame[0], 0x80 | Opcode.BINARY);
      assert.equal(frame[1] & 0x7f, extended === 0 ? length : extended === 2 ? 126 : 127);
      assert.equal((frame[1] & 0x80) !== 0, mask);
      const parser = new FrameParser();
      const split = Math.min(3, frame.length - 1);
      assert.deepEqual(parser.push(frame.subarray(0, split)), [], "an incomplete frame waits for more bytes");
      const frames = parser.push(frame.subarray(split));
      assert.equal(frames.length, 1);
      assert.equal(frames[0].opcode, Opcode.BINARY);
      assert.equal(frames[0].fin, true);
      assert.equal(frames[0].masked, mask);
      assert.ok(frames[0].payload.equals(payload), `payload of ${length} bytes, mask ${mask}`);
    }
  }
  // Two frames fed one byte at a time.
  const both = Buffer.concat([encodeFrame(Opcode.TEXT, "a", { fin: false }), encodeFrame(Opcode.CONTINUATION, "b", { mask: false })]);
  const parser = new FrameParser();
  const frames = [];
  for (const byte of both) {
    frames.push(...parser.push(Buffer.from([byte])));
  }
  assert.deepEqual(frames.map((frame) => [frame.opcode, frame.fin, frame.masked, frame.payload.toString()]), [
    [Opcode.TEXT, false, true, "a"],
    [Opcode.CONTINUATION, true, false, "b"],
  ]);
});

test("the handshake sends the headers of RELAY.md, then a masked hello", async () => {
  const relay = await fakeRelay((peer) => peer.accept());
  try {
    const home = "0123456789abcdef0123456789abcdef";
    const secret = "ab".repeat(32);
    const connection = await connectDriver({ url: relay.url, home, secret, version: "0.9.0", pingIntervalMs: 0 });
    const [peer] = relay.peers;
    const { requestLine, headers } = await peer.request;
    assert.equal(requestLine, "GET /relay/connect HTTP/1.1");
    assert.equal(headers.get("host"), new URL(relay.url).host);
    assert.equal(headers.get("upgrade"), "websocket");
    assert.equal(headers.get("connection"), "Upgrade");
    assert.equal(Buffer.from(headers.get("sec-websocket-key"), "base64").length, 16);
    assert.equal(headers.get("sec-websocket-version"), "13");
    assert.equal(headers.get("authorization"), `Bearer ${secret}`);
    assert.equal(headers.get("x-directorlink-home"), home);
    assert.equal(headers.get("x-directorlink-version"), "0.9.0");
    assert.equal(headers.get("user-agent"), "DirectorLink/0.9.0");
    assert.equal(headers.has("sec-websocket-extensions"), false, "no compression is offered");

    const hello = await peer.nextFrame();
    assert.equal(hello.opcode, Opcode.TEXT);
    assert.equal(hello.fin, true);
    assert.equal(hello.masked, true);
    assert.equal(hello.payload.toString(), JSON.stringify({ type: "hello", home, version: "0.9.0" }));
    connection.destroy();
  } finally {
    await relay.close();
  }
});

test("a 101 with the wrong Sec-WebSocket-Accept is refused", async () => {
  const relay = await fakeRelay((peer) => peer.accept("dGhlIHNhbXBsZSBub25jZQ=="));
  try {
    await assert.rejects(connectDriver({ url: relay.url }), (error) => {
      assert.ok(error instanceof HandshakeError);
      assert.match(error.message, /Sec-WebSocket-Accept/);
      return true;
    });
  } finally {
    await relay.close();
  }
});

test("a refused handshake reports the status and problem, with Content-Length or chunked", async () => {
  const body = JSON.stringify({ type: "about:blank", title: "Unauthorized", status: 401, code: "WRONG_HOME_SECRET", detail: "no" });
  let count = 0;
  const relay = await fakeRelay(async (peer) => {
    await peer.request;
    count += 1;
    if (count === 1) {
      // Keep-alive: the body ends by its length, not by the connection closing.
      peer.socket.write(`HTTP/1.1 401 Unauthorized\r\nContent-Type: application/problem+json\r\nContent-Length: ${body.length}\r\n\r\n${body}`);
    } else {
      const half = body.length >> 1;
      peer.socket.write("HTTP/1.1 401 Unauthorized\r\nContent-Type: application/problem+json\r\nTransfer-Encoding: chunked\r\n\r\n");
      peer.socket.write(`${half.toString(16)}\r\n${body.slice(0, half)}\r\n`);
      peer.socket.write(`${(body.length - half).toString(16)}\r\n${body.slice(half)}\r\n0\r\n\r\n`);
    }
  });
  try {
    for (let i = 0; i < 2; i += 1) {
      await assert.rejects(connectDriver({ url: relay.url }), (error) => {
        assert.ok(error instanceof HandshakeError);
        assert.equal(error.status, 401);
        assert.equal(error.headers["content-type"], "application/problem+json");
        assert.equal(error.body, body);
        assert.equal(error.problem.code, "WRONG_HOME_SECRET");
        return true;
      });
    }
  } finally {
    await relay.close();
  }
});

test("a fragmented request with a ping in between is reassembled; the ping gets a pong, the answer is masked", async () => {
  const request = { type: "request", id: "r1", method: "GET", path: "/v1/rooms?name=סלון", body: null };
  const bytes = Buffer.from(JSON.stringify(request));
  const cut = bytes.indexOf(Buffer.from("סלון")) + 1; // inside a two-byte letter
  const relay = await fakeRelay(async (peer) => {
    await peer.accept();
    await peer.nextFrame(); // hello
    peer.send(Opcode.TEXT, bytes.subarray(0, 10), { fin: false });
    peer.send(Opcode.PING, Buffer.from("are you there"));
    peer.send(Opcode.CONTINUATION, bytes.subarray(10, cut), { fin: false });
    peer.send(Opcode.CONTINUATION, bytes.subarray(cut));
  });
  try {
    const seen = [];
    const connection = await connectDriver({
      url: relay.url,
      pingIntervalMs: 0,
      onRequest: (message) => {
        seen.push(message);
        return { status: 200, content_type: "application/json; charset=utf-8", body: '{"ok":true}' };
      },
    });
    const [peer] = relay.peers;
    const pong = await peer.nextFrame();
    assert.equal(pong.opcode, Opcode.PONG);
    assert.equal(pong.masked, true);
    assert.equal(pong.payload.toString(), "are you there");
    const response = await peer.nextFrame();
    assert.equal(response.opcode, Opcode.TEXT);
    assert.equal(response.masked, true);
    assert.deepEqual(JSON.parse(response.payload.toString()), {
      type: "response",
      id: "r1",
      status: 200,
      content_type: "application/json; charset=utf-8",
      body: '{"ok":true}',
    });
    assert.deepEqual(seen, [request]);
    connection.destroy();
  } finally {
    await relay.close();
  }
});

test("a close from the relay is echoed with its code", async () => {
  const relay = await fakeRelay(async (peer) => {
    await peer.accept();
    await peer.nextFrame(); // hello
    peer.send(Opcode.CLOSE, closePayload(4000, "replaced"));
  });
  try {
    const connection = await connectDriver({ url: relay.url, pingIntervalMs: 0 });
    assert.deepEqual(await connection.closed, { code: 4000, reason: "replaced", by: "server" });
    const echo = await relay.peers[0].nextFrame();
    assert.equal(echo.opcode, Opcode.CLOSE);
    assert.equal(echo.masked, true);
    assert.equal(echo.payload.readUInt16BE(0), 4000);
  } finally {
    await relay.close();
  }
});

test("close() sends a close frame and waits for the relay's answer", async () => {
  const relay = await fakeRelay(async (peer) => {
    await peer.accept();
    await peer.nextFrame(); // hello
    const close = await peer.nextFrame();
    assert.equal(close.opcode, Opcode.CLOSE);
    assert.equal(close.payload.readUInt16BE(0), 1000);
    assert.equal(close.payload.subarray(2).toString(), "done");
    peer.send(Opcode.CLOSE, closePayload(1000));
  });
  try {
    const connection = await connectDriver({ url: relay.url, pingIntervalMs: 0 });
    assert.deepEqual(await connection.close(1000, "done"), { code: 1000, reason: "done", by: "client", answer: { code: 1000, reason: "" } });
  } finally {
    await relay.close();
  }
});

test('keep-alive: "ping" text frames on the interval; silence drops the connection', async () => {
  const relay = await fakeRelay(async (peer) => {
    await peer.accept();
    await peer.nextFrame(); // hello
    const ping = await peer.nextFrame();
    assert.equal(ping.opcode, Opcode.TEXT);
    assert.equal(ping.payload.toString(), "ping");
    peer.send(Opcode.TEXT, "pong");
    // Then nothing more.
  });
  try {
    const connection = await connectDriver({ url: relay.url, pingIntervalMs: 100, silenceTimeoutMs: 600 });
    const [rtt] = await once(connection, "pong");
    assert.equal(typeof rtt, "number");
    const heard = Date.now();
    assert.deepEqual(await connection.closed, { code: 1006, reason: "silence", by: "client" });
    assert.ok(Date.now() - heard >= 500, "dropped only after the silence timeout");
  } finally {
    await relay.close();
  }
});

test("a masked frame from the relay is a protocol error (1002)", async () => {
  const relay = await fakeRelay(async (peer) => {
    await peer.accept();
    await peer.nextFrame(); // hello
    peer.send(Opcode.TEXT, "hi", { mask: true });
  });
  try {
    const connection = await connectDriver({ url: relay.url, pingIntervalMs: 0 });
    const closed = await connection.closed;
    assert.equal(closed.code, 1002);
    assert.match(closed.reason, /masked/);
    const close = await relay.peers[0].nextFrame();
    assert.equal(close.opcode, Opcode.CLOSE);
    assert.equal(close.payload.readUInt16BE(0), 1002);
  } finally {
    await relay.close();
  }
});
