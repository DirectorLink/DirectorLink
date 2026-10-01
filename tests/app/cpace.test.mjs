// Pairing with CPace in the app and the console (app/js/cpace.js) against tests/vectors/cpace.json,
// which the driver checks too (driver/tests/test_cpace.lua), and against the driver itself: the
// same inputs give the same outputs in Lua (driver/tests/cpace_cli.lua) and here.
//   node --test tests/app/

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import test from "node:test";

import * as Cpace from "../../app/js/cpace.js";
import { cpaceLock, seal, toBase64 } from "../../app/js/lock.js";

const vectors = JSON.parse(readFileSync(new URL("../vectors/cpace.json", import.meta.url), "utf8"));
const bytes = (hex) => Uint8Array.from(hex.match(/../g) || [], (pair) => parseInt(pair, 16));
const hex = (data) => Array.from(data, (byte) => byte.toString(16).padStart(2, "0")).join("");

test("SHA-512 and HMAC-SHA512 match FIPS 180-4 and RFC 4231", async () => {
  for (const { message, digest } of vectors.sha512) assert.equal(hex(await Cpace.sha512(bytes(message))), digest);
  for (const { key, data, mac, case: number } of vectors.hmac_sha512) {
    assert.equal(hex(await Cpace.hmacSha512(bytes(key), bytes(data))), mac, `test case ${number}`);
  }
});

test("prepend_len and lv_cat match the draft", () => {
  for (const { data, out } of vectors.prepend_len) assert.equal(hex(Cpace.prependLen(bytes(data))), out);
  assert.equal(hex(Cpace.lvCat(...vectors.lv_cat.parts.map(bytes))), vectors.lv_cat.out);
});

test("the generator matches the draft", async () => {
  const g = vectors.generator;
  const [prs, ci, sid] = [bytes(g.prs), bytes(g.ci), bytes(g.sid)];
  assert.equal(hex(Cpace.generatorString(prs, ci, sid)), g.generator_string);
  assert.equal(hex((await Cpace.sha512(Cpace.generatorString(prs, ci, sid))).slice(0, 32)), g.hash);
  assert.equal(hex(Cpace.elligator2(bytes(g.hash))), g.g, "bit 255 is ignored");
  assert.equal(hex(Cpace.elligator2(bytes(g.u))), g.g);
  assert.equal(hex(await Cpace.generator(prs, ci, sid)), g.g);
});

test("Elligator 2 matches RFC 9380's curve25519 vectors", () => {
  for (const [index, { suite, u, x }] of vectors.elligator2.entries()) assert.equal(hex(Cpace.elligator2(bytes(u))), x, `${suite} #${index + 1}`);
});

for (const ladder of [false, true]) {
  const how = ladder ? "the BigInt ladder" : "WebCrypto";

  test(`an exchange matches the draft (${how})`, async () => {
    Cpace.useLadder(ladder);
    try {
      const e = vectors.exchange;
      const g = bytes(e.g);
      const a = await Cpace.newScalar(bytes(e.ya));
      const b = await Cpace.newScalar(bytes(e.yb));
      const [Ya, Yb] = [await a(g), await b(g)];
      assert.equal(hex(Ya), e.Ya);
      assert.equal(hex(Yb), e.Yb);
      assert.equal(hex(await a(Yb)), e.K);
      assert.equal(hex(await b(Ya)), e.K);
      assert.equal(hex(await Cpace.isk(bytes(e.sid), bytes(e.K), Ya, bytes(e.ada), Yb, bytes(e.adb))), e.isk_ir);
    } finally {
      Cpace.useLadder(false);
    }
  });

  test(`low-order points give the neutral element and stop the exchange (${how})`, async () => {
    Cpace.useLadder(ladder);
    try {
      const { scalar, points } = vectors.low_order;
      const s = await Cpace.newScalar(bytes(scalar));
      for (const [index, { u, q, aborts }] of points.entries()) {
        assert.equal(hex(Cpace.x25519Ladder(bytes(scalar), bytes(u))), q, `u${index} (ladder)`);
        const out = await s(bytes(u));
        assert.equal(out === null, aborts, `u${index} aborts`);
        if (!aborts) assert.equal(hex(out), q, `u${index}`);
      }
    } finally {
      Cpace.useLadder(false);
    }
  });
}

// The whole pairing of driver/tests/test_cpace_pairing.lua, one request at a time, the controller
// played by the Lua code: the app's answers must be the ones the driver expects.
function lua(args, input) {
  const commands = [process.env.LUA || "lua5.1", "lua"];
  for (const command of commands) {
    const run = spawnSync(command, ["driver/tests/cpace_cli.lua", ...args], { input, encoding: "utf8", cwd: new URL("../..", import.meta.url) });
    if (!run.error) {
      if (run.status !== 0) throw new Error(run.stderr || `lua exited with ${run.status}`);
      return JSON.parse(run.stdout);
    }
  }
  return null;
}

test("the app and the driver compute the same exchange (Lua against JS, random inputs)", async (t) => {
  const random = (length) => crypto.getRandomValues(new Uint8Array(length));
  const cases = [];
  for (let index = 0; index < 4; index += 1) {
    const code = String(Math.floor(Math.random() * 1e8)).padStart(8, "0");
    const name = ["Chrome on Windows", "DirectorLink Console", "אייפון של דנה", undefined][index];
    const expiresIn = index === 1 ? 86400 : undefined;
    cases.push({ code, name, expiresIn, sid: random(32), ya: random(32), yb: random(32) });
  }
  const input = cases.map((c) => ({
    code: c.code,
    name: c.name ?? null,
    expires_in: c.expiresIn ?? null,
    sid: hex(c.sid),
    ya: hex(c.ya),
    yb: hex(c.yb),
  }));
  const answers = lua(["exchange"], JSON.stringify(input));
  if (!answers) {
    t.skip("lua5.1 is not installed (set LUA to its path)");
    return;
  }
  for (const [index, c] of cases.entries()) {
    const expected = answers[index];
    const ci = Cpace.channel(c.name, c.expiresIn);
    assert.equal(hex(ci), expected.ci, `CI #${index}`);
    const g = await Cpace.generator(Cpace.utf8(c.code), ci, c.sid);
    assert.equal(hex(g), expected.g, `generator #${index}`);
    const a = await Cpace.newScalar(c.ya);
    const b = await Cpace.newScalar(c.yb);
    const [Ya, Yb] = [await a(g), await b(g)];
    assert.equal(hex(Ya), expected.Ya);
    assert.equal(hex(Yb), expected.Yb);
    const key = await Cpace.isk(c.sid, await b(Ya), Ya, new Uint8Array(0), Yb, new Uint8Array(0));
    assert.equal(hex(key), expected.isk);
    const confirmKey = await Cpace.macKey(c.sid, key);
    assert.equal(hex(await Cpace.tag(confirmKey, Ya, new Uint8Array(0))), expected.Ta);
    assert.equal(hex(await Cpace.tag(confirmKey, Yb, new Uint8Array(0))), expected.Tb);
    assert.equal((await cpaceLock(key)).lockHex, expected.lock_key);
  }
});

// A controller in this test (JS), to check the steps and the checks of pairWithCpace.
async function controller({ code, nonce = new Uint8Array(16).fill(7), ya = new Uint8Array(32).fill(3), tamper = {} } = {}) {
  const seen = [];
  const a = await Cpace.newScalar(ya);
  let context;
  const send = async (body) => {
    seen.push(structuredClone(body));
    if (!body.cpace.session) {
      const sid = Cpace.concat(Uint8Array.from(atob(body.cpace.nonce), (c) => c.charCodeAt(0)), nonce);
      const g = await Cpace.generator(Cpace.utf8(code), Cpace.channel(body.name, body.expires_in), sid);
      context = { sid, Ya: tamper.share || (await a(g)) };
      return { cpace: { session: "s1", nonce: toBase64(nonce), share: toBase64(context.Ya) } };
    }
    const Yb = Uint8Array.from(atob(body.cpace.share), (c) => c.charCodeAt(0));
    const key = await Cpace.isk(context.sid, await a(Yb), context.Ya, new Uint8Array(0), Yb, new Uint8Array(0));
    const confirmKey = await Cpace.macKey(context.sid, key);
    const theirs = toBase64(await Cpace.tag(confirmKey, Yb, new Uint8Array(0)));
    if (theirs !== body.cpace.confirm && !tamper.acceptAny) {
      const error = new Error("wrong code");
      error.code = "PAIRING_CODE_INVALID";
      throw error;
    }
    const created = { id: "4fde46cc", name: body.name, role: "admin", key: "ak_new" };
    const sealed = await seal(await cpaceLock(key), { home: "pair", key: "pair" }, "res", JSON.stringify(created));
    return { cpace: { confirm: tamper.confirm || toBase64(await Cpace.tag(confirmKey, context.Ya, new Uint8Array(0))) }, sealed };
  };
  return { send, seen };
}

test("pairWithCpace never sends the code, and opens the sealed key", async () => {
  const { send, seen } = await controller({ code: "12345678" });
  const created = await Cpace.pairWithCpace(send, { code: "12345678", name: "Chrome on Windows" });
  assert.equal(created.key, "ak_new");
  assert.equal(seen.length, 2);
  for (const body of seen) assert.ok(!JSON.stringify(body).includes("12345678") && !("pairing_code" in body), "the code is never in a request");
  assert.deepEqual(Object.keys(seen[0]).sort(), ["cpace", "name"]);
  assert.deepEqual(Object.keys(seen[1].cpace).sort(), ["confirm", "session", "share"]);
});

test("a wrong code fails at the controller; a controller that does not know the code is caught", async () => {
  const wrong = await controller({ code: "12345678" });
  await assert.rejects(Cpace.pairWithCpace(wrong.send, { code: "87654321", name: "x" }), { code: "PAIRING_CODE_INVALID" });

  // Someone in between, who does not know the code, answers as if it were right: caught.
  const impostor = await controller({ code: "00000000", tamper: { acceptAny: true } });
  await assert.rejects(Cpace.pairWithCpace(impostor.send, { code: "12345678", name: "x" }), { code: "PAIRING_NOT_CONFIRMED" });
  const garbled = await controller({ code: "12345678", tamper: { confirm: toBase64(new Uint8Array(64)) } });
  await assert.rejects(Cpace.pairWithCpace(garbled.send, { code: "12345678", name: "x" }), { code: "PAIRING_NOT_CONFIRMED" });

  // A share of low order from the "controller" stops the exchange before anything is sent back.
  const low = await controller({ code: "12345678", tamper: { share: new Uint8Array(32) } });
  await assert.rejects(Cpace.pairWithCpace(low.send, { code: "12345678", name: "x" }), { code: "PAIRING_NOT_CONFIRMED" });
  assert.equal(low.seen.length, 1);
});

test("a controller before 1.3.0 is told apart, and nothing about the code was sent", async () => {
  for (const field of ["cpace", "expires_in"]) {
    const bodies = [];
    const old = async (body) => {
      bodies.push(body);
      const error = new Error(`Unknown field: ${field}`);
      Object.assign(error, { code: "INVALID_FIELD", status: 400, problem: { code: "INVALID_FIELD", errors: [{ field }] } });
      throw error;
    };
    await assert.rejects(Cpace.pairWithCpace(old, { code: "12345678", name: "Console", expiresIn: 86400 }), { code: "CPACE_UNSUPPORTED" });
    assert.equal(bodies.length, 1);
    assert.ok(!JSON.stringify(bodies).includes("12345678"));
  }
  // Any other refusal is passed on as it is.
  const busy = async () => {
    throw Object.assign(new Error("locked"), { code: "PAIRING_RATE_LIMITED" });
  };
  await assert.rejects(Cpace.pairWithCpace(busy, { code: "12345678" }), { code: "PAIRING_RATE_LIMITED" });
});

test("expires_in is sent, and bound into the exchange", async () => {
  const { send, seen } = await controller({ code: "12345678" });
  await Cpace.pairWithCpace(send, { code: "12345678", name: "DirectorLink Console", expiresIn: 86400 });
  assert.equal(seen[0].expires_in, 86400);
  assert.notEqual(hex(Cpace.channel("DirectorLink Console", 86400)), hex(Cpace.channel("DirectorLink Console")));
});
