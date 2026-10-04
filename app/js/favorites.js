// Favorite devices, in the order shown on Home. Kept in the person's profile on the controller
// (profile.js), so all their devices share them; this browser keeps a copy, per controller, which
// is all there is with drivers before 0.12.0.
// Entries are "kind:id", e.g. "light:22", "thermostat:30", "blind:50", "camera:60".

import { saveProfilePrefs } from "./profile.js";
import { findDevice, state } from "./state.js";

const PREFIX = "directorlink.favorites.";

function storageKey() {
  return PREFIX + (state.host || "default");
}

export function favorites() {
  const shared = state.profile?.prefs?.favorites;
  if (Array.isArray(shared)) {
    return shared.filter((entry) => typeof entry === "string");
  }
  try {
    const value = JSON.parse(localStorage.getItem(storageKey()) || "[]");
    return Array.isArray(value) ? value.filter((entry) => typeof entry === "string") : [];
  } catch {
    return [];
  }
}

function save(list) {
  try {
    localStorage.setItem(storageKey(), JSON.stringify(list));
  } catch {
    // Storage full or blocked: favorites last for this visit only.
  }
  saveProfilePrefs({ favorites: list });
}

export function isFavorite(kind, id) {
  return favorites().includes(`${kind}:${id}`);
}

export function toggleFavorite(kind, id) {
  const entry = `${kind}:${id}`;
  const list = favorites();
  save(list.includes(entry) ? list.filter((item) => item !== entry) : [...list, entry]);
}

export function moveFavorite(entry, offset) {
  // Swap with the neighbour that is on screen (entries for removed devices are skipped).
  const shown = favoriteDevices().map((item) => item.entry);
  const neighbour = shown[shown.indexOf(entry) + offset];
  const list = favorites();
  const index = list.indexOf(entry);
  const target = list.indexOf(neighbour);
  if (index < 0 || !neighbour || target < 0) {
    return;
  }
  [list[index], list[target]] = [list[target], list[index]];
  save(list);
}

// Favorites of devices removed in Composer (1.8.0, ADR-059): the controller says which, as its last
// project read that worked found them (GET /v1/profile `gone_favorites`), and drops them by itself
// some days later. Never guessed from this app's own lists, which leave out what a person may not
// see, or are a moment old. [{ entry, kind, name }] in the favorites' order; name null when the
// controller did not know it.
export function goneFavorites() {
  const gone = state.profile?.gone_favorites;
  if (!Array.isArray(gone)) return [];
  const names = new Map(gone.filter((item) => typeof item?.entry === "string").map((item) => [item.entry, typeof item.name === "string" && item.name ? item.name : null]));
  return favorites()
    .filter((entry) => names.has(entry))
    .map((entry) => ({ entry, kind: entry.split(":")[0], name: names.get(entry) }));
}

// Remove, on a gone favorite's tile.
export function removeFavorite(entry) {
  save(favorites().filter((item) => item !== entry));
}

// Favorites whose device still exists, resolved to { entry, kind, device }. One the controller says
// is gone is left out even while this app's list still has its device (it is a moment old): its
// pictures and state would not come.
export function favoriteDevices() {
  const gone = new Set(goneFavorites().map((item) => item.entry));
  return favorites()
    .map((entry) => {
      const [kind, id] = entry.split(":");
      const device = gone.has(entry) ? null : findDevice(kind, id);
      return device ? { entry, kind, device } : null;
    })
    .filter(Boolean);
}
