// A read that gets no answer is sent once more; writes never are (app/api-client.js).
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import { apiRequest } from "../../app/api-client.js";

globalThis.window = globalThis;

// fetch that fails (as a lost connection does) the first `failures` times, then answers 200.
function fakeFetch(failures) {
  const calls = [];
  globalThis.fetch = async (_url, init) => {
    calls.push(init.method);
    if (calls.length <= failures) throw new TypeError("Failed to fetch");
    return new Response(JSON.stringify({ items: [] }), { status: 200, headers: { "Content-Type": "application/json" } });
  };
  return calls;
}

test("a read that gets no answer is sent once more", async () => {
  const calls = fakeFetch(1);
  const result = await apiRequest("192.168.1.10", "/v1/lights", { apiKey: "ak_test" });
  assert.equal(result.status, 200);
  assert.deepEqual(result.data, { items: [] });
  assert.deepEqual(calls, ["GET", "GET"]);
});

test("a read that fails twice gives up", async () => {
  const calls = fakeFetch(2);
  await assert.rejects(apiRequest("192.168.1.10", "/v1/lights", { apiKey: "ak_test" }), TypeError);
  assert.equal(calls.length, 2);
});

test("writes are never repeated", async () => {
  for (const method of ["POST", "PATCH", "DELETE"]) {
    const calls = fakeFetch(1);
    await assert.rejects(apiRequest("192.168.1.10", "/v1/doorbells/542/open", { method, apiKey: "ak_test" }), TypeError);
    assert.deepEqual(calls, [method], method);
  }
});

// session.js: once the key is forgotten, a read that was on its way is not sent again, and a request
// not sent yet is not sent at all.
test("a read no longer wanted is not sent again", async () => {
  let wanted = true;
  const calls = [];
  globalThis.fetch = async (_url, init) => {
    calls.push(init.method);
    wanted = false;
    throw new TypeError("Failed to fetch");
  };
  const error = await apiRequest("192.168.1.10", "/v1/lights", { apiKey: "ak_test", wanted: () => wanted }).catch((failure) => failure);
  assert.equal(error.code, "NOT_SENT");
  assert.deepEqual(calls, ["GET"]);
  for (const method of ["GET", "DELETE"]) {
    const none = fakeFetch(0);
    const refused = await apiRequest("192.168.1.10", "/v1/api-keys/current", { method, apiKey: "ak_test", wanted: () => false }).catch((failure) => failure);
    assert.equal(refused.code, "NOT_SENT", method);
    assert.deepEqual(none, [], method);
  }
});

test("an HTTP error is an answer: it is not sent again", async () => {
  const calls = [];
  globalThis.fetch = async (_url, init) => {
    calls.push(init.method);
    return new Response("{}", { status: 503, headers: { "Content-Type": "application/json" } });
  };
  const result = await apiRequest("192.168.1.10", "/v1/lights", { apiKey: "ak_test" });
  assert.equal(result.status, 503);
  assert.equal(calls.length, 1);
});
