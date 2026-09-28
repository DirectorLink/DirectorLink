// This person's profile (docs/PREFERENCES.md): language, theme, palette, favorites and the rooms
// they hide, kept on the controller and shared by all their devices. This browser keeps its own
// copy (localStorage) as well, so the app opens in the right language before it reaches the
// controller, and works as before with drivers that have no profiles (before 0.12.0).

import { api } from "./session.js";
import { languagePreference, setLanguage } from "./i18n.js";
import { palettePreference, setPalette, setTheme, themePreference } from "./theme.js";
import { notify, state } from "./state.js";

const SAVE_DELAY_MS = 600;
let pending = {};
let saveTimer = null;

// Favorites this browser kept before profiles (favorites.js), for the first sync.
function localFavorites() {
  try {
    const value = JSON.parse(localStorage.getItem(`directorlink.favorites.${state.host || "default"}`) || "[]");
    return Array.isArray(value) ? value.filter((entry) => typeof entry === "string" && /^[a-z]+:\d+$/.test(entry)) : [];
  } catch {
    return [];
  }
}

async function flush() {
  saveTimer = null;
  const changes = pending;
  pending = {};
  if (!state.profile || !Object.keys(changes).length) return;
  try {
    const answer = await api("/v1/profile", { method: "PATCH", body: { prefs: changes } });
    if (answer && typeof answer === "object") {
      // Changes made while this one was on its way stay on top.
      state.profile = { ...answer, prefs: { ...answer.prefs, ...pending } };
    }
  } catch {
    // Not saved on the controller now (no answer, or an older driver): sent again with the next change.
    pending = { ...changes, ...pending };
  }
  notify();
}

// Saves `changes` (e.g. { language: "he" }) in the profile, a moment later and several together.
// Without a profile (older driver) nothing is sent: the browser's own copy is all there is.
export function saveProfilePrefs(changes) {
  if (!state.profile) return;
  state.profile = { ...state.profile, prefs: { ...state.profile.prefs, ...changes } };
  pending = { ...pending, ...changes };
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(flush, SAVE_DELAY_MS);
  notify();
}

async function applyPrefs(prefs, onLanguage) {
  if (prefs.theme && prefs.theme !== themePreference()) setTheme(prefs.theme);
  if (prefs.palette && prefs.palette !== palettePreference()) setPalette(prefs.palette);
  if (prefs.language && prefs.language !== languagePreference()) {
    await setLanguage(prefs.language);
    onLanguage?.();
  }
}

// After connecting, and every minute: the profile from the controller, whose language, theme and
// palette then apply on this device too. A new profile first takes what this browser had.
export async function syncProfile(onLanguage) {
  if (saveTimer || Object.keys(pending).length) return;
  let profile;
  try {
    profile = await api("/v1/profile");
  } catch (error) {
    if (error?.status === 404 || error?.status === 405) {
      state.profile = null;
    }
    return;
  }
  if (!profile || typeof profile !== "object") return;
  if (profile.version === 0) {
    const prefs = { language: languagePreference(), theme: themePreference(), palette: palettePreference(), favorites: localFavorites() };
    try {
      profile = await api("/v1/profile", { method: "PATCH", body: { prefs, version: 0 } });
    } catch (error) {
      // Another device of this person was first: its choices win.
      if (error?.code === "VERSION_CONFLICT") profile = (await api("/v1/profile").catch(() => null)) || profile;
    }
  }
  state.profile = profile;
  await applyPrefs(profile.prefs || {}, onLanguage);
  notify();
}

// Rooms this person hides from their lists.
export function hiddenRooms() {
  return new Set((state.profile?.prefs?.hidden_rooms || []).map(Number));
}

export function setRoomHidden(roomId, hidden) {
  const current = hiddenRooms();
  if (hidden) current.add(Number(roomId));
  else current.delete(Number(roomId));
  saveProfilePrefs({ hidden_rooms: [...current] });
}
