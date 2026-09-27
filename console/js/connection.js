// Connection screen: controller address, and the three ways to get an API key.

import { byId, h, setMessage } from "./dom.js";
import {
  can,
  cancelAccess,
  connect,
  connectWithKey,
  forgetKey,
  notify,
  pairWithCode,
  requestAdminAccess,
  state,
  useHost,
} from "./session.js";

const hostForm = byId("host-form");
const hostInput = byId("host-input");
const message = byId("connect-message");
const currentPanel = byId("current-panel");
const currentFacts = byId("current-facts");
const requestButton = byId("request-button");
const accessNote = byId("access-note");
const waitingPanel = byId("waiting-panel");
const waitingCountdown = byId("waiting-countdown");
const pairForm = byId("pair-form");
const pairCode = byId("pair-code");
const keyForm = byId("key-form");
const keyInput = byId("key-input");

let countdownTimer = null;

function remaining(expiresAt) {
  const seconds = Math.max(0, Math.round((Date.parse(expiresAt) - Date.now()) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function renderCountdown() {
  const expiresAt = state.access?.expiresAt;
  waitingCountdown.textContent = expiresAt
    ? `${remaining(expiresAt)} left. Press DirectorLink Access in the Control4 app.`
    : "Sending the request…";
}

async function afterConnect(ok) {
  if (ok) {
    keyInput.value = "";
    pairCode.value = "";
    // Back to the tab the console was on.
    const last = window.localStorage.getItem("directorlink.console.tab");
    window.location.hash = `#/${last && last !== "connect" ? last : "api"}`;
  }
}

export function renderConnection() {
  if (document.activeElement !== hostInput && !hostInput.dataset.dirty) {
    hostInput.value = state.host;
  }
  if (state.notice) {
    setMessage(message, state.notice.text, state.notice.kind);
  } else if (state.status === "unreachable") {
    setMessage(message, "The controller cannot be reached right now.", "error");
  } else {
    setMessage(message, "");
  }

  const waiting = state.status === "waiting";
  waitingPanel.hidden = !waiting;
  requestButton.hidden = waiting;
  const busy = waiting || state.status === "connecting";
  for (const button of document.querySelectorAll("#view-connect button")) {
    if (button.id !== "cancel-button") button.disabled = busy;
  }
  window.clearInterval(countdownTimer);
  if (waiting) {
    renderCountdown();
    countdownTimer = window.setInterval(renderCountdown, 1000);
  }

  if (state.apiKey && state.role && !can("admin")) {
    accessNote.hidden = false;
    accessNote.textContent = `This console's key is ${state.role}. An approved admin key replaces it here; the ${state.role} key keeps working until you revoke it.`;
  } else {
    accessNote.hidden = true;
  }

  currentPanel.hidden = !state.apiKey;
  if (state.apiKey) {
    const rows = [
      ["Status", state.status === "connected" ? "Connected" : state.status === "unreachable" ? "Can't reach the controller" : "Connecting…"],
      ["Name", state.key?.name || "—"],
      ["Key ID", state.key?.id || "—"],
      ["Role", state.role || "—"],
    ];
    currentFacts.replaceChildren(...rows.map(([label, value]) => h("div", { class: "fact" }, h("dt", {}, label), h("dd", {}, value))));
  }
}

hostInput.addEventListener("input", () => {
  hostInput.dataset.dirty = "1";
});

hostForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  delete hostInput.dataset.dirty;
  try {
    const previous = state.host;
    const host = useHost(hostInput.value);
    state.notice =
      host !== previous && previous
        ? { kind: "info", text: `Saved ${host}. A key belongs to one controller, so get a key for this one.` }
        : { kind: "success", text: `Saved ${host}.` };
    if (state.apiKey) {
      await afterConnect(await connect());
    }
  } catch (error) {
    state.notice = { kind: "error", text: error.message };
  }
  notify();
});

requestButton.addEventListener("click", async () => {
  delete hostInput.dataset.dirty;
  await afterConnect(await requestAdminAccess(hostInput.value));
});

byId("cancel-button").addEventListener("click", () => cancelAccess());

pairForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  delete hostInput.dataset.dirty;
  const code = pairCode.value;
  pairCode.value = "";
  await afterConnect(await pairWithCode(hostInput.value, code));
});

keyForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  delete hostInput.dataset.dirty;
  await afterConnect(await connectWithKey(hostInput.value, keyInput.value));
});

byId("reconnect-button").addEventListener("click", async () => {
  state.notice = null;
  await afterConnect(await connect());
});

byId("forget-button").addEventListener("click", async () => {
  if (!window.confirm("Revoke this console's API key on the controller and remove it from this browser?")) return;
  await forgetKey();
});
