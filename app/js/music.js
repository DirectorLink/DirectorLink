// Music: the home's Sonos rooms (docs/SONOS.md, ADR-044), when an installer turned Sonos on in
// Composer (GET /v1/system: features.sonos). Each Sonos room shows in its Control4 room; Home
// lists what plays. Everyone sees what plays; members play, pause, skip, set the volume and start
// a Sonos favorite; admins pick the room of a Sonos room whose name matches none
// (views/music.js). Read every 5 s while Home or a room is open (the controller then reads those
// rooms' players every few seconds), else with each rooms refresh, once a minute.

import { t } from "./i18n.js";
import { api, errorText, handleUnauthorized, image, keyGeneration, keyInUse, noteForbidden, whenForgotten } from "./session.js";
import { can, clearError, notify, setError, state } from "./state.js";

export const MUSIC_POLL_MS = 5000;
// After a command: read again soon, once the player has moved on (a new track, a station).
const AFTER_COMMAND_MS = 1500;
// What the screen shows after a command, until a read agrees or this passes.
const PENDING_MS = 8000;
const ART_KEEP = 12;

let timer = null;
// What the app shows: { roomId } (a room, or null for Home), or null (another screen).
let watching = null;
// Music id -> { fields, until }: what a command changed, kept over reads that do not say it yet.
let pending = {};
// art_key -> { url } | { loading: true } | { failed: true }, the newest last.
const arts = new Map();
// Music id -> { stage: "loading" | "ready" | "error", items, text }.
let favorites = {};

export function musicAvailable() {
  return state.system?.features?.sonos === true;
}

// Every Sonos room known (none while Sonos is off).
export function musicRooms() {
  return state.music?.enabled ? state.music.items : [];
}

export function findMusic(id) {
  return musicRooms().find((item) => item.id === id) || null;
}

// The rooms of an item's group, as the API lists them, other than the item itself.
export function groupMates(item) {
  return (item.group?.rooms || []).filter((room) => room.id !== item.id);
}

export function isPlaying(item) {
  return item.state === "playing" || item.state === "transitioning";
}

function withPending(item, now) {
  const kept = pending[item.id];
  if (!kept) return item;
  if (now > kept.until || Object.entries(kept.fields).every(([field, value]) => item[field] === value)) {
    delete pending[item.id];
    return item;
  }
  return { ...item, ...kept.fields };
}

// `items` read for `roomId` (null: every room): they replace what was known of those rooms.
function useAnswer(answer, roomId, now) {
  const fresh = (Array.isArray(answer?.items) ? answer.items : []).map((item) => withPending(item, now));
  if (roomId == null || !state.music?.enabled) {
    state.music = { enabled: answer?.enabled === true, status: answer?.status || "off", items: fresh };
    return;
  }
  const ids = new Set(fresh.map((item) => item.id));
  const others = state.music.items.filter((item) => !ids.has(item.id) && item.room_id !== roomId);
  state.music = { enabled: answer?.enabled === true, status: answer?.status || state.music.status, items: [...others, ...fresh].sort(byName) };
}

function byName(a, b) {
  return String(a.name).localeCompare(String(b.name)) || String(a.id).localeCompare(String(b.id));
}

// GET /v1/music (in a room: ?room_id=). A driver before 1.5.0, or Sonos off, shows nothing; without
// an answer the last one stays.
export async function loadMusic(roomId = null, now = Date.now()) {
  if (!musicAvailable()) {
    if (state.music) {
      state.music = null;
      notify();
    }
    return;
  }
  const since = keyGeneration();
  try {
    const answer = await api(roomId == null ? "/v1/music" : `/v1/music?room_id=${roomId}`);
    if (since !== keyGeneration()) return;
    useAnswer(answer, roomId, now);
  } catch (error) {
    if (since !== keyGeneration()) return;
    if (error?.status === 401) {
      handleUnauthorized(error);
      return;
    }
    if (error?.status === 404 || error?.status === 405) state.music = null;
  }
  notify();
}

function poll() {
  timer = null;
  if (!keyInUse() || !musicAvailable() || !watching) return;
  const target = watching.roomId;
  const run = !document.hidden && state.status === "connected" ? loadMusic(target) : Promise.resolve();
  run.finally(() => {
    if (timer === null && watching && keyInUse()) timer = window.setTimeout(poll, MUSIC_POLL_MS);
  });
}

function restart(delay = 0) {
  window.clearTimeout(timer);
  timer = null;
  if (watching && musicAvailable() && keyInUse()) timer = window.setTimeout(poll, delay);
}

// app.js, on every screen change: Home and a room are followed every 5 s, other screens not.
export function musicRouteChanged(route) {
  const next = route?.name === "home" ? { roomId: null } : route?.name === "room" ? { roomId: Number(route.id) } : null;
  const same = (next && watching && next.roomId === watching.roomId) || (!next && !watching);
  watching = next;
  if (!same) restart(0);
}

// app.js: after connecting and with each rooms refresh (once a minute): every Sonos room once, for
// Home's rooms and the scene editor, and the screen shown followed.
export async function startMusic(route) {
  watching = route?.name === "home" ? { roomId: null } : route?.name === "room" ? { roomId: Number(route.id) } : null;
  if (!watching || watching.roomId != null) await loadMusic(null);
  if (timer === null) restart(0);
}

whenForgotten(() => {
  window.clearTimeout(timer);
  timer = null;
  watching = null;
  pending = {};
  favorites = {};
  for (const art of arts.values()) if (art.url) URL.revokeObjectURL(art.url);
  arts.clear();
  state.music = null;
});

// ---- commands ------------------------------------------------------------------------------

export function musicKey(item) {
  return `music:${item.id}`;
}

// The words for what a player or the controller answered.
export function musicErrorText(error) {
  const code = error?.code;
  if (code === "SONOS_OFF") return t("music.errors.off");
  if (code === "PLAYER_UNREACHABLE") return t("music.errors.unreachable");
  if (code === "ACTION_NOT_POSSIBLE") return t("music.errors.notPossible");
  if (code === "FAVORITE_NOT_PLAYABLE") return t("music.errors.notPlayable");
  if (code === "PLAYER_BUSY") return t("music.errors.busy");
  return errorText(error) || t("errors.commandFailed");
}

function replaceItem(item) {
  if (!state.music?.enabled) return;
  state.music = { ...state.music, items: state.music.items.map((other) => (other.id === item.id ? withPending(item, Date.now()) : other)) };
}

// The rooms of a group show its state: a command on one changes them all on screen.
function showForGroup(item, fields) {
  if (!state.music?.enabled) return;
  const until = Date.now() + PENDING_MS;
  state.music = {
    ...state.music,
    items: state.music.items.map((other) => {
      if (other.group?.id !== item.group?.id) return other;
      pending[other.id] = { fields, until };
      return { ...other, ...fields };
    }),
  };
}

function forget(item, fields) {
  for (const other of musicRooms()) {
    if (other.group?.id === item.group?.id || other.id === item.id) {
      const kept = pending[other.id];
      if (kept && Object.keys(fields).every((field) => field in kept.fields)) delete pending[other.id];
    }
  }
}

async function send(item, path, options, fields, { group = true } = {}) {
  if (!can("member")) return false;
  const key = musicKey(item);
  const before = findMusic(item.id) || item;
  clearError(key);
  if (fields) {
    if (group) showForGroup(item, fields);
    else {
      pending[item.id] = { fields, until: Date.now() + PENDING_MS };
      replaceItem({ ...before, ...fields });
    }
  }
  notify();
  const since = keyGeneration();
  try {
    const answer = await api(path, { ...options, timeoutMs: 15000 });
    if (since !== keyGeneration()) return false;
    if (answer?.id === item.id) replaceItem(answer);
    restart(AFTER_COMMAND_MS);
    return true;
  } catch (error) {
    if (since !== keyGeneration()) return false;
    if (error?.status === 401) {
      handleUnauthorized(error);
      return false;
    }
    noteForbidden(error);
    if (fields) {
      forget(item, fields);
      if (state.music?.enabled) {
        const restore = Object.fromEntries(Object.keys(fields).map((field) => [field, before[field]]));
        state.music = {
          ...state.music,
          items: state.music.items.map((other) => (other.id === item.id || (group && other.group?.id === item.group?.id) ? { ...other, ...restore } : other)),
        };
      }
    }
    setError(key, musicErrorText(error));
    return false;
  } finally {
    notify();
  }
}

// play, pause, next or previous, on the room's group.
export function musicCommand(item, action) {
  const fields = action === "play" ? { state: "playing" } : action === "pause" ? { state: "paused" } : null;
  return send(item, `/v1/music/${encodeURIComponent(item.id)}/${action}`, { method: "POST" }, fields);
}

// { volume } or { muted }: this room's own speaker.
export function setMusicLevels(item, change) {
  return send(item, `/v1/music/${encodeURIComponent(item.id)}`, { method: "PATCH", body: change }, change, { group: false });
}

// ---- favorites -----------------------------------------------------------------------------

export function musicFavorites(item) {
  return favorites[item.id] || null;
}

export async function loadFavorites(item) {
  const current = favorites[item.id];
  if (current?.stage === "loading") return;
  favorites = { ...favorites, [item.id]: { stage: "loading", items: current?.items || [] } };
  notify();
  const since = keyGeneration();
  try {
    const answer = await api(`/v1/music/${encodeURIComponent(item.id)}/favorites`, { timeoutMs: 15000 });
    if (since !== keyGeneration()) return;
    favorites = { ...favorites, [item.id]: { stage: "ready", items: Array.isArray(answer?.items) ? answer.items : [] } };
  } catch (error) {
    if (since !== keyGeneration()) return;
    if (error?.status === 401) {
      handleUnauthorized(error);
      return;
    }
    favorites = { ...favorites, [item.id]: { stage: "error", items: [], text: musicErrorText(error) } };
  }
  notify();
}

export function playFavorite(item, favorite) {
  if (!favorite.playable) return Promise.resolve(false);
  return send(item, `/v1/music/${encodeURIComponent(item.id)}/favorites/${encodeURIComponent(favorite.id)}/play`, { method: "POST" }, { state: "playing" });
}

// ---- the room of a Sonos room (admins) -----------------------------------------------------

// PUT /v1/music/{id}/room: a room's id, or null for the room of the same name.
export async function placeMusicRoom(item, roomId) {
  if (!can("admin")) return false;
  const key = `${musicKey(item)}:room`;
  clearError(key);
  const since = keyGeneration();
  try {
    const answer = await api(`/v1/music/${encodeURIComponent(item.id)}/room`, { method: "PUT", body: { room_id: roomId } });
    if (since !== keyGeneration()) return false;
    if (answer?.id === item.id) replaceItem(answer);
    return true;
  } catch (error) {
    if (since !== keyGeneration()) return false;
    if (error?.status === 401) {
      handleUnauthorized(error);
      return false;
    }
    noteForbidden(error);
    setError(key, musicErrorText(error));
    return false;
  } finally {
    notify();
  }
}

// ---- album art -----------------------------------------------------------------------------

// The picture of what an item plays, as an object URL, or null: then it is fetched (through the
// controller: the page is HTTPS, the player plain HTTP), once per picture.
export function musicArt(item) {
  const playing = item?.now_playing;
  const href = playing?.art_href;
  const artKey = playing?.art_key;
  if (!href || !artKey) return null;
  const known = arts.get(artKey);
  if (known) return known.url || null;
  arts.set(artKey, { loading: true });
  const since = keyGeneration();
  image(href)
    .then((blob) => {
      if (since !== keyGeneration()) return;
      arts.set(artKey, { url: URL.createObjectURL(blob) });
      while (arts.size > ART_KEEP) {
        const [oldest, value] = arts.entries().next().value;
        if (value.url) URL.revokeObjectURL(value.url);
        arts.delete(oldest);
      }
      notify();
    })
    .catch((error) => {
      if (since !== keyGeneration()) return;
      if (error?.status === 401) {
        handleUnauthorized(error);
        return;
      }
      // Asked again with the next picture, not over and over.
      arts.set(artKey, { failed: true });
    });
  return null;
}

// For the renderer's signature (app.js): what is shown, the pictures loaded, the favorites.
export function musicSignature() {
  if (!musicAvailable() || !state.music) return null;
  return [state.music, [...arts.keys()].filter((key) => arts.get(key).url), favorites];
}
