// The app's lock (app/js/lock.js, WebCrypto) against tests/vectors/lock.json, which the driver and
// the cloud tests check too.
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import { deriveLock, invitationLock, open, seal } from "../../app/js/lock.js";

const vectors = JSON.parse(readFileSync(new URL("../vectors/lock.json", import.meta.url), "utf8"));
const hexBytes = (hex) => Uint8Array.from(hex.match(/../g), (pair) => parseInt(pair, 16));

test("keys are derived as the vectors say", async () => {
  assert.equal((await deriveLock(vectors.device.api_key)).lockHex, vectors.device.lock_key_hex);
  assert.equal((await invitationLock(vectors.invitation.secret)).lockHex, vectors.invitation.lock_key_hex);
});

test("sealing matches the vectors byte for byte", async () => {
  const lock = await deriveLock(vectors.device.api_key);
  for (const name of ["request", "answer"]) {
    const { envelope, plaintext, dir, iv_hex } = vectors[name];
    assert.deepEqual(await seal(lock, envelope, dir, plaintext, hexBytes(iv_hex)), envelope, name);
  }
  const invite = await invitationLock(vectors.invitation.secret);
  const { envelope, plaintext, dir, iv_hex } = vectors.join;
  assert.deepEqual(await seal(invite, envelope, dir, plaintext, hexBytes(iv_hex)), envelope, "invitation");
});

test("envelopes from Node open; changed, turned or foreign ones do not", async () => {
  const lock = await deriveLock(vectors.device.api_key);
  const { envelope } = vectors.request;
  assert.equal(await open(lock, envelope, "req"), vectors.request.plaintext);
  assert.equal(await open(lock, vectors.answer.envelope, "res"), vectors.answer.plaintext);
  assert.equal(await open(lock, envelope, "res"), null, "a request is not an answer");
  assert.equal(await open(lock, { ...envelope, key: "00000000" }, "req"), null, "another key id");
  assert.equal(await open(lock, { ...envelope, ct: `${envelope.ct.startsWith("A") ? "B" : "A"}${envelope.ct.slice(1)}` }, "req"), null);
  assert.equal(await open(lock, { ...envelope, mac: "not base64!" }, "req"), null);
  assert.equal(await open(await invitationLock(vectors.invitation.secret), envelope, "req"), null, "another lock");
});

test("a fresh seal opens, with a new iv each time", async () => {
  const lock = await deriveLock("ak_fresh");
  const one = await seal(lock, { home: "h", key: "k" }, "req", "hello");
  const two = await seal(lock, { home: "h", key: "k" }, "req", "hello");
  assert.notEqual(one.iv, two.iv);
  assert.equal(await open(lock, one, "req"), "hello");
});
