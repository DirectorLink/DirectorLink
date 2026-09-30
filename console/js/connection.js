// Connection screen: controller address, and the two ways to get an API key: the pairing code
// from Composer (always admin) or a pasted key.

import { formatPairingCode } from "../api-client.js";
import { byId, h, setMessage } from "./dom.js";
import { can, connect, connectWithKey, forgetKey, notify, pairWithCode, state, timeLeft, useHost } from "./session.js";

const hostForm = byId("host-form");
const hostInput = byId("host-input");
const message = byId("connect-message");
const currentPanel = byId("current-panel");
const currentFacts = byId("current-facts");
const pairForm = byId("pair-form");
const pairCode = byId("pair-code");
const pairNote = byId("pair-note");
const pairUnprotected = byId("pair-unprotected");
const keyForm = byId("key-form");
const keyInput = byId("key-input");

async function afterConnect(ok) {
  if (ok) {
    keyInput.value = "";
    pairCode.value = "";
    // Back to the tab the console was on.
    let last = null;
    try {
      last = window.localStorage.getItem("directorlink.console.tab");
    } catch {
      last = null;
    }
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

  const busy = state.status === "connecting";
  for (const button of document.querySelectorAll("#view-connect button")) button.disabled = busy;

  if (state.apiKey && state.role && !can("admin")) {
    pairNote.hidden = false;
    pairNote.textContent = `This console's key is ${state.role}. Pairing replaces it here with an admin key; the ${state.role} key keeps working until you revoke it.`;
  } else {
    pairNote.hidden = true;
  }
  // DirectorLink before 1.3.0 would get the code unprotected (ADR-039): nothing was sent yet.
  pairUnprotected.hidden = !state.pairingUnprotected;

  currentPanel.hidden = !state.apiKey;
  if (state.apiKey) {
    const rows = [
      ["Status", state.status === "connected" ? "Connected" : state.status === "unreachable" ? "Can't reach the controller" : "Connecting…"],
      ["Name", state.key?.name || "—"],
      ["Key ID", state.key?.id || "—"],
      ["Role", state.role || "—"],
      ["Expires", state.key ? timeLeft(state.key.expires_at) : "—"],
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
        ? { kind: "info", text: `Saved ${host}. A key belongs to one controller: pair with a code from this controller's Composer project.` }
        : { kind: "success", text: `Saved ${host}.` };
    if (state.apiKey) {
      await afterConnect(await connect());
    }
  } catch (error) {
    state.notice = { kind: "error", text: error.message };
  }
  notify();
});

// Shows the code as "1234 5678" while it is typed or pasted, keeping the caret after the same digit.
pairCode.addEventListener("input", () => {
  const caretDigits = pairCode.value.slice(0, pairCode.selectionStart ?? pairCode.value.length).replace(/\D/g, "").length;
  const formatted = formatPairingCode(pairCode.value);
  if (formatted !== pairCode.value) {
    pairCode.value = formatted;
    const caret = Math.min(formatted.length, caretDigits > 4 ? caretDigits + 1 : caretDigits);
    pairCode.setSelectionRange(caret, caret);
  }
});

pairForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  delete hostInput.dataset.dirty;
  // A wrong code stays in the field so a typo can be fixed.
  await afterConnect(await pairWithCode(hostInput.value, pairCode.value));
});

byId("pair-anyway-button").addEventListener("click", async () => {
  delete hostInput.dataset.dirty;
  await afterConnect(await pairWithCode(hostInput.value, pairCode.value, { anyway: true }));
});

byId("pair-cancel-button").addEventListener("click", () => {
  state.pairingUnprotected = false;
  notify();
});

// The time left on the key, kept up to date while it is shown.
window.setInterval(() => {
  if (!currentPanel.hidden && state.key?.expires_at) renderConnection();
}, 30000);

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
