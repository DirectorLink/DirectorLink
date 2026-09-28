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

// Favorites whose device still exists, resolved to { entry, kind, device }.
export function favoriteDevices() {
  return favorites()
    .map((entry) => {
      const [kind, id] = entry.split(":");
      const device = findDevice(kind, id);
      return device ? { entry, kind, device } : null;
    })
    .filter(Boolean);
}
