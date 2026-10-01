// A controller for the pairing tests: POST /v1/auth/pair as DirectorLink 1.3.0 answers it (CPace,
// ADR-039, with app/js/cpace.js playing the controller's part), or as 1.2.0 did (the code itself;
// unknown fields refused). `lock: false`: a 1.3.0 controller whose lock failed its self-test (no
// CPace, no sealed answer). Every request body is kept in `requests`, and the host it went to in
// `hosts`.

import * as Cpace from "../../app/js/cpace.js";
import { cpaceLock, fromBase64, seal, toBase64 } from "../../app/js/lock.js";

const EMPTY = new Uint8Array(0);

export function fakeController({ code = "12345678", version = "1.3.0", lock = true, now = () => Date.now() } = {}) {
  const requests = [];
  const hosts = [];
  const sessions = new Map();
  const issued = new Map(); // key -> its view
  const expired = new Set();
  let keys = 0;

  const created = (name, expiresIn) => {
    keys += 1;
    const record = {
      id: `0000000${keys}`,
      name: name ?? "Paired client",
      role: "admin",
      created_at: new Date(now()).toISOString(),
      last_used_at: null,
      current: false,
      profile_id: null,
      expires_at: expiresIn ? new Date(now() + expiresIn * 1000).toISOString() : null,
      key: `ak_${String(keys).padStart(48, "0")}`,
    };
    const { key, ...view } = record;
    issued.set(key, view);
    return record;
  };
  const invalidField = (field) => [400, { status: 400, code: "INVALID_FIELD", detail: `Unknown field: ${field}`, errors: [{ field, message: `Unknown field: ${field}` }] }];

  async function pair(body) {
    const known = version === "1.3.0" ? ["pairing_code", "name", "exchange", "expires_in", "cpace"] : ["pairing_code", "name", "exchange"];
    const unknown = Object.keys(body).find((field) => !known.includes(field));
    if (unknown) return invalidField(unknown);
    if (!lock && body.cpace) {
      return [503, { status: 503, code: "LOCK_UNAVAILABLE", detail: "This controller cannot seal the answer (the lock self-test failed; see the log); pair with pairing_code" }];
    }
    if (!lock && body.exchange) return invalidField("exchange");
    if (body.cpace && !body.cpace.session) {
      const scalar = await Cpace.newScalar();
      const nonce = crypto.getRandomValues(new Uint8Array(16));
      const sid = Cpace.concat(fromBase64(body.cpace.nonce), nonce);
      const share = await scalar(await Cpace.generator(Cpace.utf8(code), Cpace.channel(body.name, body.expires_in), sid));
      const id = `s${sessions.size + 1}`;
      sessions.set(id, { scalar, sid, share, name: body.name, expiresIn: body.expires_in });
      return [200, { cpace: { session: id, nonce: toBase64(nonce), share: toBase64(share) } }];
    }
    if (body.cpace) {
      const session = sessions.get(body.cpace.session);
      sessions.delete(body.cpace.session);
      if (!session) return [409, { status: 409, code: "PAIRING_SESSION_EXPIRED" }];
      const theirs = fromBase64(body.cpace.share);
      const key = await Cpace.isk(session.sid, await session.scalar(theirs), session.share, EMPTY, theirs, EMPTY);
      const confirmKey = await Cpace.macKey(session.sid, key);
      if (toBase64(await Cpace.tag(confirmKey, theirs, EMPTY)) !== body.cpace.confirm) {
        return [403, { status: 403, code: "PAIRING_CODE_INVALID", attempts_remaining: 4 }];
      }
      const sealed = await seal(await cpaceLock(key), { home: "pair", key: "pair" }, "res", JSON.stringify(created(session.name, session.expiresIn)));
      return [201, { cpace: { confirm: toBase64(await Cpace.tag(confirmKey, session.share, EMPTY)) }, sealed }];
    }
    if (String(body.pairing_code).replace(/\D/g, "") !== code) return [403, { status: 403, code: "PAIRING_CODE_INVALID", attempts_remaining: 4 }];
    return [201, created(body.name, body.expires_in)];
  }

  // A fetch for the controller at `host` (http://host:41999).
  async function fetch(url, init = {}) {
    const { hostname, pathname } = new URL(url);
    const method = init.method || "GET";
    let status = 404;
    let answer = { status: 404, code: "NOT_FOUND" };
    if (method === "POST" && pathname === "/v1/auth/pair") {
      const body = JSON.parse(init.body);
      requests.push(body);
      hosts.push(hostname);
      [status, answer] = await pair(body);
    } else if (pathname === "/v1/api-keys/current") {
      // The console sends its key openly (Bearer); an expired one is refused and removed (ADR-040).
      const key = String(init.headers?.Authorization || "").replace(/^Bearer /, "");
      if (expired.has(key)) {
        issued.delete(key);
        expired.delete(key);
        [status, answer] = [401, { status: 401, code: "KEY_EXPIRED", detail: "This API key expired and was removed." }];
      } else if (issued.has(key)) {
        [status, answer] = [200, { ...issued.get(key), current: true }];
      } else {
        [status, answer] = [401, { status: 401, code: "UNAUTHORIZED" }];
      }
    } else if (pathname === "/v1/system") {
      [status, answer] = [200, { bridge: { version } }];
    } else if (pathname === "/v1/openapi.json") {
      [status, answer] = [200, { openapi: "3.1.0", paths: {} }];
    }
    return new Response(JSON.stringify(answer), { status, headers: { "Content-Type": "application/json" } });
  }

  // The keys given out so far pass their expiry.
  const expireKeys = () => {
    for (const key of issued.keys()) expired.add(key);
  };
  // ...and something else looked at the keys first, which removed them: then they are just unknown.
  const removeKeys = () => issued.clear();

  return { fetch, requests, hosts, expireKeys, removeKeys };
}
