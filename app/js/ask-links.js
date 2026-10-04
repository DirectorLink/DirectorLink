// Ask before opening (ADR-058, docs/SCENES.md): a private link, bound to one door or gate and to the
// person who made it, for the phone's own automations (iPhone Shortcuts when arriving home, Siri,
// Android apps). Its run opens nothing: the controller asks that person's devices, by an alert sealed
// to each (ADR-050), whether to open the door. Tapping the alert opens #/open/<door>/<request>/<until>
// (sw.js), whose Open is an ordinary pulse with this device's own key and the request's id
// (POST /v1/relays/{id}/pulse {"request"}), checked as any opening, while the request lasts, once.
// Someone who may open the door makes the link (views/ask-links.js); the controller shows its secret
// once, and this module keeps it only in memory, until its screen is left. Shown when GET /v1/system
// says the controller has them (features.ask_links, 1.8.0).

import { t } from "./i18n.js";
import { linkAddress, linkUrl } from "./scene-links.js";
import { api, errorText, noteForbidden, whenForgotten } from "./session.js";
import { can, notify, state, ui } from "./state.js";

// The list is read again when it is shown this long after it was read.
const FRESH_MS = 60000;

export const askLinksSupported = () => state.system?.features?.ask_links === true;

// The same address and link as a scene link's (cloud/src/scene-links.js runs both).
export const askAddress = linkAddress;
export const askUrl = linkUrl;

// ui.askLinks: { loaded, loading, at, error, items, remoteAccess, homeLinked, doorControl, busy (a
// relay or link id), message ({ at, kind, text }), copied, showing (the doors whose new secret is on
// screen: the screen is drawn again when it goes) }. The secrets just made are in `made` (relay id
// -> the link), never in `ui`.
let made = {};
whenForgotten(() => {
  made = {};
  ui.askLinks = null;
  ui.openRequest = null;
});

export function askState() {
  ui.askLinks ??= { loaded: false, loading: false, at: 0, error: null, items: [], remoteAccess: true, homeLinked: true, doorControl: true, busy: null, message: null, copied: null, showing: [] };
  return ui.askLinks;
}

// The links this person made (an admin: everyone's), read when shown and not read within FRESH_MS.
export function ensureAskLinks() {
  const links = askState();
  if (askLinksSupported() && can("doors") && !links.loading && (!links.loaded || Date.now() - links.at > FRESH_MS)) loadAskLinks();
  return links;
}

export async function loadAskLinks() {
  const links = askState();
  links.loading = true;
  try {
    const answer = await api("/v1/ask-links");
    Object.assign(links, {
      loaded: true,
      error: null,
      items: Array.isArray(answer?.items) ? answer.items : [],
      remoteAccess: answer?.remote_access !== false,
      homeLinked: answer?.home_linked !== false,
      doorControl: answer?.door_control !== false,
    });
  } catch (error) {
    noteForbidden(error);
    Object.assign(links, { loaded: true, error: errorText(error) });
  } finally {
    links.loading = false;
    links.at = Date.now();
    notify();
  }
}

// This device's link for a door (one per door and device).
export function askLinkOf(relayId) {
  return askState().items.find((item) => item.relay_id === Number(relayId) && item.this_device) || null;
}

export function madeAskLink(relayId) {
  return made[relayId] || null;
}

// Forgets the secrets shown (the screen is left, or Done).
export function forgetAskMade(relayId) {
  if (relayId !== undefined) delete made[relayId];
  else made = {};
  askState().showing = Object.keys(made).map(Number);
}

function say(at, kind, text) {
  askState().message = text ? { at, kind, text } : null;
}

const CODES = { REMOTE_ACCESS_OFF: "remoteOff", HOME_NOT_LINKED: "notLinked", DOOR_CONTROL_DISABLED: "doorsOff", ASK_LINK_LIMIT_REACHED: "limit", FORBIDDEN: "forbidden" };

function failureText(error) {
  return CODES[error?.code] ? t(`askLinks.errors.${CODES[error.code]}`) : errorText(error);
}

// Makes this device's link for the door (replacing the one it had); its secret is kept for this
// screen.
export async function makeAskLink(relayId, label) {
  const links = askState();
  links.busy = relayId;
  say(relayId, null, null);
  notify();
  try {
    const body = { relay_id: Number(relayId) };
    if (label && label.trim()) body.label = label.trim().slice(0, 64);
    const link = await api("/v1/ask-links", { method: "POST", body });
    made[relayId] = link;
    links.showing = Object.keys(made).map(Number);
    await loadAskLinks();
    return link;
  } catch (error) {
    noteForbidden(error);
    say(relayId, "error", failureText(error));
    return null;
  } finally {
    links.busy = null;
    notify();
  }
}

// Removes a link (`at`: where the message shows: the door's screen, or the list).
export async function removeAskLink(linkId, at = linkId) {
  const links = askState();
  links.busy = linkId;
  say(at, null, null);
  notify();
  try {
    await api(`/v1/ask-links/${linkId}`, { method: "DELETE" });
  } catch (error) {
    // Removed already (on another device): the same outcome.
    if (error?.status !== 404) {
      noteForbidden(error);
      say(at, "error", failureText(error));
      links.busy = null;
      notify();
      return false;
    }
  }
  say(at, "success", t("askLinks.removed"));
  links.busy = null;
  await loadAskLinks();
  return true;
}

// ---- answering a request (#/open/<door>/<request>/<until>) ----------------------------------------

// ui.openRequest: { request, stage: "ask" | "opening" | "opened" | "expired" | "answered" | "error",
// text } for the request on screen.
export function openRequestState(requestId) {
  if (ui.openRequest?.request !== requestId) ui.openRequest = { request: requestId, stage: "ask", text: null };
  return ui.openRequest;
}

// Whether the request may still be answered, by this device's clock: the service worker set `until`
// when the alert came, from how long the controller said it lasts. The controller decides anyway.
export function requestOver(until, now = Date.now()) {
  return !Number.isFinite(until) || now >= until;
}

// Open: the door's pulse with this device's own key and the request's id. Nothing else opens it.
export async function answerRequest(relayId, requestId) {
  const request = openRequestState(requestId);
  if (request.stage === "opening" || request.stage === "opened") return request;
  request.stage = "opening";
  request.text = null;
  notify();
  try {
    await api(`/v1/relays/${Number(relayId)}/pulse`, { method: "POST", body: { request: requestId } });
    request.stage = "opened";
  } catch (error) {
    noteForbidden(error);
    if (error?.code === "OPEN_REQUEST_EXPIRED") request.stage = "expired";
    else if (error?.code === "OPEN_REQUEST_ANSWERED") request.stage = "answered";
    else {
      request.stage = "error";
      request.text = error?.code === "DOOR_CONTROL_DISABLED" ? t("errors.doorsDisabled") : errorText(error);
    }
  }
  notify();
  return request;
}
