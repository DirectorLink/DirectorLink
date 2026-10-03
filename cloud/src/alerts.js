// Alerts on admins' devices (ADR-047, docs/ACCOUNTS.md): Web Push notifications (web-push.js) for
// two things only, each carrying its kind, the home id and a time, never a name:
// - offline: the home has been away from the relay for OFFLINE_ALERT_MINUTES (10), once per absence.
//   Away is no driver connection, or a stale one, away since the driver was last heard on it: a
//   connection can die without the relay noticing. Stale is the relay's own rule (home-relay.js
//   stale(), 1.6.0: nothing heard for 2.5 of the driver's ping intervals, 25 s at 10 s pings); where
//   the relay has none, nothing heard for ALERT_SILENCE_SECONDS (60). A drop of seconds never alerts.
// - schedule_failed: the controller says a scheduled scene failed ({"type":"alert"}, docs/RELAY.md),
//   at most SCHEDULE_ALERTS_PER_HOUR (3) an hour.
// They go to the browsers that the home's admins subscribed: the subscriptions of accounts that hold
// an admin key at the home, as far as the cloud knows. The controller lists its admin key ids with
// its key ids ("keys"); the cloud knows which account uses which key (member_keys).
//
//   GET    /v1/homes/{home_id}/alerts   { public_key }: the VAPID key the app subscribes with (members)
//   POST   /v1/homes/{home_id}/alerts   { endpoint, keys: { p256dh, auth } }: this browser gets the
//                                       home's alerts (accounts with an admin key there)
//   DELETE /v1/homes/{home_id}/alerts   { endpoint }: it no longer does
//
// The home's Durable Object (home-relay.js) runs the rest with HomeAlerts. It sets alarms only
// while an admin's browser is subscribed: at a disconnect (OFFLINE_ALERT_MINUTES later) and, while
// the driver is connected, every OFFLINE_ALERT_MINUTES to see that its pings are still answered.
// Its storage:
//   alerts_home      the home id (an alarm has no request to name it)
//   alerts_admins    the admin key ids of the controller's last "keys"; none: it never said (before 1.6.0)
//   alerts_on        true while an admin's browser is subscribed
//   away_since       when the driver went away (milliseconds): its disconnect, or, when the relay
//                    restarted under the connection (a deploy records no disconnect), when an alarm
//                    first found it gone
//   offline_alerted  the offline alert of this absence went (milliseconds)
//   schedule_alerts  the times of the schedule alerts of the last hour

import { json, problem, readText } from "./http.js";
import { validKeyList } from "./member-keys.js";
import { sendPush, subscriptionKeys, validEndpoint, vapidProblem } from "./web-push.js";

const HOUR_MS = 3600 * 1000;
const DEFAULT_OFFLINE_MINUTES = 10;
const DEFAULT_SILENCE_SECONDS = 60;
const SCHEDULE_ALERTS_PER_HOUR = 3;
// How long a push service keeps an alert for a device that is off.
const ALERT_TTL_SECONDS = 12 * 3600;
// Browsers one account may have subscribed for one home: a new one beyond it replaces the oldest.
const MAX_PER_MEMBER = 10;
const MAX_BODY_BYTES = 4096;
const KINDS = new Set(["offline", "schedule_failed"]);

function iso(ms = Date.now()) {
  return new Date(ms).toISOString();
}

function log(event, fields) {
  console.log(JSON.stringify({ event, ...fields }));
}

function offlineMs(env) {
  const value = Number(env.OFFLINE_ALERT_MINUTES);
  return Math.round((Number.isFinite(value) && value > 0 ? value : DEFAULT_OFFLINE_MINUTES) * 60000);
}

function silenceMs(env) {
  const value = Number(env.ALERT_SILENCE_SECONDS);
  return Math.round((Number.isFinite(value) && value > 0 ? value : DEFAULT_SILENCE_SECONDS) * 1000);
}

// Whether the driver has gone quiet on its socket `ws` (see the top of this file).
function quiet(relay, ws, now) {
  if (typeof relay.stale === "function") {
    return relay.stale(ws);
  }
  return now - relay.lastSeen(ws) > silenceMs(relay.env);
}

// The push service a subscription is with, for the logs: an endpoint itself is never logged.
function serviceOf(endpoint) {
  try {
    return new URL(endpoint).hostname;
  } catch {
    return null;
  }
}

// Whether `userId` holds one of the home's admin keys.
async function isAdmin(env, homeId, userId, admins) {
  const row = await env.DB.prepare("SELECT 1 AS found FROM member_keys WHERE home_id = ?1 AND user_id = ?2 AND key_id IN (SELECT value FROM json_each(?3)) LIMIT 1")
    .bind(homeId, userId, JSON.stringify(admins))
    .first();
  return Boolean(row);
}

// The subscriptions of accounts that hold an admin key at the home.
async function recipients(env, homeId, admins) {
  if (!Array.isArray(admins) || admins.length === 0) {
    return [];
  }
  const { results } = await env.DB.prepare(
    "SELECT endpoint, p256dh, auth FROM push_subscriptions WHERE home_id = ?1 AND user_id IN " +
      "(SELECT user_id FROM member_keys WHERE home_id = ?1 AND key_id IN (SELECT value FROM json_each(?2)))"
  )
    .bind(homeId, JSON.stringify(admins))
    .all();
  return results;
}

// --- The Worker's routes (homes.js) --------------------------------------------------------------

async function body(request) {
  try {
    const text = await readText(request, MAX_BODY_BYTES);
    const value = text === null ? null : JSON.parse(text);
    return value && typeof value === "object" && !Array.isArray(value) ? value : null;
  } catch {
    return null;
  }
}

// An operation of the home's object (HomeAlerts.request).
export async function homeObject(env, homeId, message) {
  const stub = env.HOME_RELAY.get(env.HOME_RELAY.idFromName(homeId));
  const response = await stub.fetch("https://home-relay/alerts", {
    method: "POST",
    headers: { "X-DirectorLink-Home": homeId, "content-type": "application/json" },
    body: JSON.stringify(message),
  });
  return response.json();
}

const REFUSALS = {
  ADMIN_ONLY: [403, "Only the home's admins get its alerts"],
  NOT_A_MEMBER: [403, "This account does not belong to that home"],
  ROLES_UNKNOWN: [409, "The controller has not said who its admins are: alerts need DirectorLink 1.6.0 or later on it, with Remote Access on"],
};

// The routes above, for a signed-in account (homes.js checked the session and the origin).
export async function handleHomeAlerts(request, env, user, homeId) {
  const member = await env.DB.prepare("SELECT 1 AS found FROM members WHERE home_id = ? AND user_id = ?").bind(homeId, user.id).first();
  if (!member) {
    return problem(403, "NOT_A_MEMBER", "This account does not belong to that home");
  }
  if (request.method === "DELETE") {
    const input = await body(request);
    if (typeof input?.endpoint !== "string" || input.endpoint.length > 2048) {
      return problem(400, "INVALID_SUBSCRIPTION", "Send { endpoint } of the browser's push subscription");
    }
    const { meta } = await env.DB.prepare("DELETE FROM push_subscriptions WHERE home_id = ? AND user_id = ? AND endpoint = ?").bind(homeId, user.id, input.endpoint).run();
    await homeObject(env, homeId, { op: "changed" });
    log("alerts_unsubscribed", { home: homeId, user: user.id, service: serviceOf(input.endpoint), removed: meta.changes ?? 0 });
    return new Response(null, { status: 204 });
  }
  const unusable = await vapidProblem(env);
  if (unusable) {
    log("alerts_not_configured", { why: unusable });
    return problem(503, "ALERTS_NOT_CONFIGURED", "Alerts are not set up on this server yet");
  }
  if (request.method === "GET") {
    return json({ public_key: env.VAPID_PUBLIC_KEY });
  }
  const input = await body(request);
  const keys = input && validEndpoint(env, input.endpoint) ? await subscriptionKeys(input.keys) : null;
  if (!keys) {
    return problem(400, "INVALID_SUBSCRIPTION", "Send the browser's push subscription: { endpoint, keys: { p256dh, auth } }, from a known push service");
  }
  const answer = await homeObject(env, homeId, { op: "subscribe", user: user.id, endpoint: input.endpoint, ...keys });
  if (!answer?.ok) {
    const [status, detail] = REFUSALS[answer?.code] ?? [500, "The alerts could not be switched on; try again"];
    return problem(status, REFUSALS[answer?.code] ? answer.code : "INTERNAL_ERROR", detail);
  }
  return json({ alerts: true }, 201);
}

// --- In the home's Durable Object ----------------------------------------------------------------

export class HomeAlerts {
  // `relay`: the HomeRelay object (its storage, env, driver socket and when it was last heard).
  constructor(relay) {
    this.relay = relay;
  }

  get storage() {
    return this.relay.ctx.storage;
  }

  get env() {
    return this.relay.env;
  }

  // The Worker's operations: { op: "subscribe", user, endpoint, p256dh, auth } after it checked
  // the account's membership and the subscription, { op: "changed" } after a subscription went, or
  // { op: "admins" } for the admin key ids the controller last announced (backups.js asks).
  async request(input, homeId) {
    if (input?.op === "subscribe") {
      return this.subscribe(input, homeId);
    }
    if (input?.op === "admins") {
      const admins = await this.storage.get("alerts_admins");
      return { ok: true, admins: Array.isArray(admins) ? admins : null };
    }
    if (input?.op === "changed") {
      await this.watch(homeId);
      return { ok: true };
    }
    return { ok: false, code: "INVALID_REQUEST" };
  }

  async subscribe(input, homeId) {
    const admins = await this.storage.get("alerts_admins");
    if (!Array.isArray(admins)) {
      return { ok: false, code: "ROLES_UNKNOWN" };
    }
    if (!(await isAdmin(this.env, homeId, input.user, admins))) {
      log("alerts_refused", { home: homeId, user: input.user, why: "not an admin" });
      return { ok: false, code: "ADMIN_ONLY" };
    }
    const DB = this.env.DB;
    try {
      await DB.batch([
        DB.prepare(
          "INSERT INTO push_subscriptions (home_id, endpoint, user_id, p256dh, auth, created_at) VALUES (?, ?, ?, ?, ?, ?) " +
            "ON CONFLICT (home_id, endpoint) DO UPDATE SET p256dh = excluded.p256dh, auth = excluded.auth, " +
            "created_at = CASE WHEN push_subscriptions.user_id = excluded.user_id THEN push_subscriptions.created_at ELSE excluded.created_at END, user_id = excluded.user_id"
        ).bind(homeId, input.endpoint, input.user, input.p256dh, input.auth, iso()),
        DB.prepare(
          "DELETE FROM push_subscriptions WHERE home_id = ?1 AND user_id = ?2 AND endpoint NOT IN " +
            "(SELECT endpoint FROM push_subscriptions WHERE home_id = ?1 AND user_id = ?2 ORDER BY created_at DESC, endpoint LIMIT ?3)"
        ).bind(homeId, input.user, MAX_PER_MEMBER),
      ]);
    } catch (error) {
      // The account left the home since the Worker looked (the subscription's foreign key).
      log("alerts_subscribe_failed", { home: homeId, user: input.user, error: String(error?.message ?? error) });
      return { ok: false, code: /FOREIGN KEY/i.test(String(error?.message)) ? "NOT_A_MEMBER" : "INTERNAL" };
    }
    log("alerts_subscribed", { home: homeId, user: input.user, service: serviceOf(input.endpoint) });
    await this.watch(homeId);
    return { ok: true };
  }

  // Whether an admin's browser is subscribed; the object sets alarms only then. Returns it.
  async watch(homeId) {
    const stored = await this.storage.get(["alerts_home", "alerts_admins", "alerts_on"]);
    const home = homeId ?? stored.get("alerts_home");
    if (homeId && stored.get("alerts_home") !== homeId) {
      await this.storage.put("alerts_home", homeId);
    }
    const on = Boolean(home) && (await recipients(this.env, home, stored.get("alerts_admins"))).length > 0;
    if (stored.get("alerts_on") !== on) {
      await this.storage.put("alerts_on", on);
    }
    if (!on) {
      await this.storage.deleteAlarm();
    } else if ((await this.storage.getAlarm()) === null) {
      // The first look decides: the driver may be away already.
      await this.storage.setAlarm(Date.now() + 1000);
    }
    return on;
  }

  // The controller's admin key ids, with its key ids (a "keys" message); `admins` is undefined
  // from drivers before 1.6.0, which do not say.
  async keys(homeId, ids, admins) {
    const list = validKeyList(admins) ? [...new Set(admins)].filter((id) => ids.includes(id)).sort() : null;
    const stored = await this.storage.get(["alerts_admins", "alerts_on"]);
    if (JSON.stringify(stored.get("alerts_admins") ?? null) !== JSON.stringify(list)) {
      await (list ? this.storage.put("alerts_admins", list) : this.storage.delete("alerts_admins"));
    }
    // Admins may have changed: only homes with a subscription ask D1.
    if (stored.get("alerts_on") !== undefined) {
      await this.watch(homeId);
    }
  }

  // The driver connected: its absence, if any, is over.
  async connected(homeId) {
    const stored = await this.storage.get(["alerts_on", "away_since", "offline_alerted"]);
    if (stored.get("away_since") !== undefined || stored.get("offline_alerted") !== undefined) {
      await this.storage.delete(["away_since", "offline_alerted"]);
    }
    if (stored.get("alerts_on") === true) {
      await this.storage.setAlarm(Date.now() + offlineMs(this.env));
    }
  }

  // The driver disconnected (and no other connection of it is open) at `at`.
  async disconnected(at) {
    await this.storage.put("away_since", at);
    if ((await this.storage.get("alerts_on")) === true) {
      await this.storage.setAlarm(at + offlineMs(this.env));
    }
  }

  async alarm() {
    const stored = await this.storage.get(["alerts_on", "alerts_home", "away_since"]);
    const homeId = stored.get("alerts_home");
    if (stored.get("alerts_on") !== true || !homeId) {
      return;
    }
    const now = Date.now();
    const limit = offlineMs(this.env);
    const ws = this.relay.driverSocket();
    if (ws) {
      const seen = this.relay.lastSeen(ws);
      if (!quiet(this.relay, ws, now)) {
        // Connected, and its pings are answered: look again later. Back without reconnecting
        // after an alert, it may be alerted about again.
        if ((await this.storage.get("offline_alerted")) !== undefined) {
          await this.storage.delete("offline_alerted");
        }
        await this.storage.setAlarm(now + limit);
        return;
      }
      // Connected, but silent: away since it was last heard. The socket may come back to life,
      // so after an alert it is looked at again.
      if (!(await this.whenAway(homeId, seen, now, limit))) {
        await this.storage.setAlarm(now + limit);
      }
      return;
    }
    let since = stored.get("away_since");
    if (!Number.isFinite(since)) {
      // No disconnect was seen: the relay restarted under the connection (a deploy ends the socket
      // without webSocketClose). When it ended is not known; the driver normally connects again
      // within seconds, so the 10 minutes count from now.
      since = now;
      await this.storage.put("away_since", since);
    }
    // No alarm after an alert: the next connection starts watching again.
    await this.whenAway(homeId, since, now, limit);
  }

  // The driver is away since `since`: the offline alert once it has been `limit`, once per absence;
  // until then, an alarm for that moment (and true).
  async whenAway(homeId, since, now, limit) {
    if (now - since < limit) {
      await this.storage.setAlarm(since + limit);
      return true;
    }
    if ((await this.storage.get("offline_alerted")) === undefined) {
      await this.storage.put("offline_alerted", now);
      await this.send(homeId, "offline", since);
    }
    return false;
  }

  // {"type":"alert"} from the controller: { kind: "schedule_failed", at }.
  async fromHome(data, homeId) {
    if (data?.kind !== "schedule_failed") {
      log("alert_ignored", { home: homeId, kind: typeof data?.kind === "string" ? data.kind.slice(0, 40) : null });
      return;
    }
    if ((await this.storage.get("alerts_on")) !== true) {
      return; // no admin's browser is subscribed
    }
    const now = Date.now();
    const at = Date.parse(data.at);
    const when = Number.isFinite(at) && Math.abs(at - now) <= 24 * HOUR_MS ? at : now;
    const recent = ((await this.storage.get("schedule_alerts")) ?? []).filter((time) => now - time < HOUR_MS);
    if (recent.length >= SCHEDULE_ALERTS_PER_HOUR) {
      log("alert_limited", { home: homeId, kind: data.kind, at: iso(when) });
      return;
    }
    recent.push(now);
    await this.storage.put("schedule_alerts", recent);
    await this.send(homeId, "schedule_failed", when);
  }

  // Sends one alert to the admins' browsers; forgets those the push service no longer knows.
  async send(homeId, kind, at) {
    if (!KINDS.has(kind)) {
      return 0;
    }
    const list = await recipients(this.env, homeId, await this.storage.get("alerts_admins"));
    if (list.length === 0) {
      log("alert_not_sent", { home: homeId, kind, why: "no admin's browser is subscribed" });
      await this.watch(homeId);
      return 0;
    }
    const message = { kind, home: homeId, at: iso(at) };
    let statuses;
    try {
      statuses = await Promise.all(list.map((subscription) => sendPush(this.env, subscription, message, { ttl: ALERT_TTL_SECONDS })));
    } catch (error) {
      log("alert_failed", { home: homeId, kind, error: String(error?.message ?? error) });
      return 0;
    }
    const gone = list.filter((_, index) => statuses[index] === 404 || statuses[index] === 410);
    if (gone.length > 0) {
      const DB = this.env.DB;
      await DB.batch(gone.map((subscription) => DB.prepare("DELETE FROM push_subscriptions WHERE home_id = ? AND endpoint = ?").bind(homeId, subscription.endpoint)));
      await this.watch(homeId);
    }
    const delivered = statuses.filter((status) => status >= 200 && status < 300).length;
    log("alert_sent", {
      home: homeId,
      kind,
      at: message.at,
      devices: list.length,
      delivered,
      gone: gone.length,
      failed: statuses.filter((status) => !(status >= 200 && status < 300) && status !== 404 && status !== 410),
    });
    return delivered;
  }
}
