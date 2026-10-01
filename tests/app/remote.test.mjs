// The account connection (app/js/remote.js): its failures never look like the home's 401, and the
// home's refusals keep their codes.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import { invitationLock, open, seal } from "../../app/js/lock.js";

globalThis.window = globalThis;
globalThis.location = { hostname: "app.directorlink.io", origin: "https://app.directorlink.io" };
const stored = new Map();
globalThis.localStorage = {
  getItem: (key) => (stored.has(key) ? stored.get(key) : null),
  setItem: (key, value) => stored.set(key, String(value)),
  removeItem: (key) => stored.delete(key),
};

const { RemoteError, acceptInvitation, checkJoinRequest, invitationLink, joinCodeText, lanCall, parseInvitation, remoteCall, saveRemote } = await import("../../app/js/remote.js");

const HOME = "0123456789abcdef0123456789abcdef";
const INVITATION = "89abcdef";
const SECRET = "ab".repeat(32);

function answer(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

test("an ended account session is a RemoteError without a status, so the key is kept", async () => {
  saveRemote({ home: HOME, keyId: "0badc0de" });
  globalThis.fetch = async () => answer(401, { code: "NOT_SIGNED_IN", detail: "Sign in first" });
  const error = await remoteCall("ak_test", "/v1/lights").catch((failure) => failure);
  assert.ok(error instanceof RemoteError);
  assert.equal(error.code, "NOT_SIGNED_IN");
  assert.equal(error.status, undefined, "session code forgets the key on status 401 only");
  assert.equal(error.httpStatus, 401);
});

test("a refused invitation keeps the home's problem code", async () => {
  const lock = await invitationLock(SECRET);
  globalThis.fetch = async (url, init) => {
    assert.match(url, /\/v1\/join$/);
    const request = JSON.parse(await open(lock, JSON.parse(init.body).envelope, "req"));
    const reply = { id: request.id, ts: request.ts, status: 409, content_type: "application/problem+json", body: JSON.stringify({ code: "KEY_LIMIT_REACHED", detail: "Too many keys" }) };
    return answer(200, { envelope: await seal(lock, { home: HOME, key: INVITATION }, "res", JSON.stringify(reply)) });
  };
  const error = await acceptInvitation({ home: HOME, invitation: INVITATION, secret: SECRET }, "Test").catch((failure) => failure);
  assert.ok(error instanceof RemoteError);
  assert.equal(error.code, "KEY_LIMIT_REACHED");
  assert.equal(error.message, "Too many keys");
});

// On the home network a sealed read that got no answer is sealed again and sent once more, unless
// the key was forgotten meanwhile (session.js: it is no longer wanted).
test("a sealed read no longer wanted is not sent again", async () => {
  let wanted = true;
  const calls = [];
  globalThis.fetch = async (url, init) => {
    calls.push(`${init.method} ${new URL(url).pathname}`);
    wanted = false;
    throw new TypeError("Failed to fetch");
  };
  const target = { home: "lan", keyId: "0badc0de", offset: 0 };
  const error = await lanCall("192.168.1.10", "ak_test", target, "/v1/lights", { wanted: () => wanted }).catch((failure) => failure);
  assert.equal(error.code, "NOT_SENT");
  assert.deepEqual(calls, ["POST /v1/sealed"]);
});

test("invitation links carry the home, the invitation and its secret after #", () => {
  const link = invitationLink(HOME, { id: INVITATION, secret: SECRET });
  assert.equal(link, `https://app.directorlink.io/#/join/${HOME}.${INVITATION}.${SECRET}`);
  assert.deepEqual(parseInvitation(link.split("#/join/")[1]), { home: HOME, invitation: INVITATION, secret: SECRET });
  assert.equal(parseInvitation(`${HOME}.${INVITATION}`), null);
});

// An invitation for another email (ADR-041): the home's owner approves the account first.
test("accepting an invitation for another email asks the home's owner, and waits", async () => {
  let sent = null;
  globalThis.fetch = async (url, init) => {
    sent = JSON.parse(init.body);
    return answer(202, { status: "pending", code: "042917", requested_at: "2026-09-30T10:00:00.000Z", decided_at: null, expires_at: "2026-10-07T10:00:00.000Z" });
  };
  const result = await acceptInvitation({ home: HOME, invitation: INVITATION, secret: SECRET }, "Test");
  assert.equal(sent.ask_owner, true, "the app asks instead of stopping at EMAIL_MISMATCH");
  assert.equal(sent.invitation_id, INVITATION);
  assert.ok(sent.envelope?.mac, "sealed as always; the secret itself is never sent");
  assert.doesNotMatch(JSON.stringify(sent), new RegExp(SECRET));
  assert.deepEqual(result, { waiting: { status: "pending", code: "042917", requested_at: "2026-09-30T10:00:00.000Z", decided_at: null, expires_at: "2026-10-07T10:00:00.000Z" } });
  assert.equal(joinCodeText("042917"), "042 917");
  assert.equal(joinCodeText("12345"), "");
});

test("while it waits, the app reads the owner's answer from its request", async () => {
  const invitation = { home: HOME, invitation: INVITATION };
  const reply = (status, body) => {
    globalThis.fetch = async (url, init) => {
      assert.equal(new URL(url).pathname, `/v1/join/${HOME}/${INVITATION}`);
      assert.equal(init.method, "GET");
      return answer(status, body);
    };
  };
  for (const [status, outcome] of [
    ["pending", "wait"],
    ["approved", "finish"],
    ["refused", "refused"],
    ["expired", "expired"],
  ]) {
    reply(200, { status, code: "042917", expires_at: "2026-10-07T10:00:00.000Z" });
    const result = await checkJoinRequest(invitation);
    assert.equal(result.outcome, outcome, status);
    assert.equal(result.request.code, "042917");
  }
  reply(404, { code: "INVITATION_NOT_FOUND" });
  assert.equal((await checkJoinRequest(invitation)).outcome, "gone", "used by someone else, revoked, or expired long ago");
  reply(404, { code: "NOT_FOUND" });
  assert.equal((await checkJoinRequest(invitation)).outcome, "none", "withdrawn");
  globalThis.fetch = async () => {
    throw new TypeError("Failed to fetch");
  };
  assert.ok((await checkJoinRequest(invitation).catch((error) => error)) instanceof RemoteError, "offline: asked again later");
});

test("a refusal by the home's owner keeps its code", async () => {
  globalThis.fetch = async () => answer(403, { code: "REFUSED_BY_OWNER", detail: "The home's owner did not let this account join with this invitation" });
  const error = await acceptInvitation({ home: HOME, invitation: INVITATION, secret: SECRET }, "Test").catch((failure) => failure);
  assert.ok(error instanceof RemoteError);
  assert.equal(error.code, "REFUSED_BY_OWNER");
  assert.equal(error.httpStatus, 403);
});

// A backup through the account asks for a minute (js/backup.js): the account request waits that
// long, and 20 seconds for everything else.
test("a request through the account waits as long as it asks, 20 seconds at least", async () => {
  saveRemote({ home: HOME, keyId: "0badc0de" });
  const delays = [];
  const setTimer = window.setTimeout;
  window.setTimeout = (callback, ms) => {
    delays.push(ms);
    return setTimer(() => {}, 0);
  };
  globalThis.fetch = async () => answer(401, { code: "NOT_SIGNED_IN" });
  try {
    await remoteCall("ak_test", "/v1/backup", { timeoutMs: 60000 }).catch(() => {});
    await remoteCall("ak_test", "/v1/lights").catch(() => {});
  } finally {
    window.setTimeout = setTimer;
  }
  assert.deepEqual(delays, [60000, 20000]);
});
