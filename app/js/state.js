// App state shared by every screen. Views read it and call notify() after changing it;
// the renderer redraws the current screen on the next animation frame.

export const state = {
  host: "",
  apiKey: "",
  // setup (no key) · connecting · waiting (access request) · connected · unreachable
  status: "setup",
  notice: null, // { kind: "error" | "info" | "success", text } shown on the connect screen
  access: null, // waiting access request: { id, host, expiresAt }
  loaded: false,
  system: null,
  rooms: [],
  devices: [],
  lights: [],
  thermostats: [],
  blinds: [],
  cameras: [],
  relays: [], // doors and gates; [] on drivers without /v1/relays
  // This key's role (GET /v1/api-keys/current): viewer < member < doors < admin.
  // Drivers without roles answer 404 there; their keys can do everything, so "admin".
  role: null,
  lastUpdated: null,
  // Per device ("light:22"): short inline error after a failed command.
  errors: {},
  // Per device: a command is in flight, so polls must not overwrite the optimistic state.
  pending: {},
  // Brightness last sent to lights that do not report their level.
  sentBrightness: {},
  online: navigator.onLine,
  canInstall: false,
  offlineCopy: "checking",
};

// UI-only state (not from the controller).
export const ui = {
  filter: null, // home summary filter: "lights" | "climate" | "blinds"
  editFavorites: false,
  roomDrafts: {}, // settings: room names being edited, "roomId:lang" -> text
  roomMessages: {}, // settings: per-room save result
  drafts: {}, // form fields being typed: key -> text
  relayStage: {}, // door/gate Open button: relayId -> "confirm" | "sending" | "sent"
  featuredCamera: null, // Cameras tab: id of the large picture
  dragging: false, // a slider thumb is held: redraws wait
  tick: 0, // bumped by timers that need a redraw (countdowns)
};

const listeners = new Set();
let scheduled = false;

export function subscribe(listener) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function notify() {
  if (scheduled) {
    return;
  }
  scheduled = true;
  requestAnimationFrame(() => {
    scheduled = false;
    for (const listener of listeners) {
      listener();
    }
  });
}

export const KINDS = {
  light: { list: "lights", path: "/v1/lights" },
  thermostat: { list: "thermostats", path: "/v1/thermostats" },
  blind: { list: "blinds", path: "/v1/blinds" },
  camera: { list: "cameras", path: "/v1/cameras" },
  relay: { list: "relays", path: "/v1/relays" },
};

// Roles, lowest first. can("member") is true for member, doors and admin keys.
export const ROLES = ["viewer", "member", "doors", "admin"];

export function can(role) {
  const mine = ROLES.indexOf(state.role || "admin");
  // An unknown (newer) role gets the safe, read-only interface; the controller decides anyway.
  return mine >= 0 && mine >= ROLES.indexOf(role);
}

export function deviceKey(kind, id) {
  return `${kind}:${id}`;
}

export function findDevice(kind, id) {
  const list = state[KINDS[kind]?.list] || [];
  return list.find((item) => item.id === Number(id)) || null;
}

export function replaceDevice(kind, device) {
  const listName = KINDS[kind].list;
  state[listName] = state[listName].map((item) => (item.id === device.id ? device : item));
}

export function setError(key, text) {
  const stamp = Date.now();
  state.errors = { ...state.errors, [key]: { text, stamp } };
  notify();
  window.setTimeout(() => {
    if (state.errors[key]?.stamp === stamp) {
      const { [key]: _removed, ...rest } = state.errors;
      state.errors = rest;
      notify();
    }
  }, 8000);
}

export function clearError(key) {
  if (state.errors[key]) {
    const { [key]: _removed, ...rest } = state.errors;
    state.errors = rest;
  }
}
