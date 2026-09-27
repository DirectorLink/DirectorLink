// Keys tab (admin): list, change role, rename, revoke and create API keys (/v1/api-keys).

import { byId, copyWithFeedback, formatTime, h, setMessage } from "./dom.js";
import { ROLES, can, connect, handleUnauthorized, send, state } from "./session.js";

const locked = byId("keys-locked");
const panel = byId("keys-panel");
const message = byId("keys-message");
const tableBody = byId("keys-table-body");
const refreshButton = byId("keys-refresh");
const createForm = byId("key-create-form");
const createName = byId("key-create-name");
const createRole = byId("key-create-role");
const secretPanel = byId("key-secret");
const secretName = byId("key-secret-name");
const secretValue = byId("key-secret-value");
const secretCopy = byId("key-secret-copy");

let keys = [];
let loading = false;
let editing = null; // key id being renamed

function failureText(result) {
  if (result.data?.code === "LAST_ADMIN") {
    return "This is the only admin key, so it must stay admin. Make another key admin first.";
  }
  return result.data?.detail || `DirectorLink answered HTTP ${result.status}.`;
}

async function load() {
  if (loading) return;
  loading = true;
  refreshButton.disabled = true;
  try {
    const result = await send("/v1/api-keys");
    if (result.ok) {
      keys = result.data?.items || [];
      renderTable();
    } else if (result.status !== 401) {
      setMessage(message, failureText(result), "error");
    }
  } catch (error) {
    setMessage(message, error.message, "error");
  } finally {
    loading = false;
    refreshButton.disabled = false;
  }
}

function roleSelect(key) {
  const select = h(
    "select",
    { "aria-label": `Role of ${key.name}` },
    ROLES.map((role) => h("option", { value: role, selected: role === key.role }, role))
  );
  select.addEventListener("change", async () => {
    const role = select.value;
    if (key.current && role !== "admin" && !window.confirm(`Change this console's own key to ${role}? It will lose access to the log and key management.`)) {
      select.value = key.role;
      return;
    }
    select.disabled = true;
    const result = await send(`/v1/api-keys/${key.id}`, { method: "PATCH", body: { role } }).catch((error) => ({ error }));
    select.disabled = false;
    if (result.error) {
      select.value = key.role;
      setMessage(message, result.error.message, "error");
      return;
    }
    if (!result.ok) {
      select.value = key.role;
      if (result.status !== 401) setMessage(message, failureText(result), "error");
      return;
    }
    setMessage(message, `${key.name} is now ${role}.`, "success");
    if (key.current) {
      await connect();
      return;
    }
    await load();
  });
  return select;
}

function nameCell(key) {
  if (editing !== key.id) {
    return h(
      "td",
      { class: "key-name" },
      h("span", { dir: "auto" }, key.name),
      key.current ? h("span", { class: "badge badge-current" }, "this console") : null
    );
  }
  const input = h("input", { type: "text", value: key.name, maxlength: "64", "aria-label": `New name for ${key.name}` });
  const save = async (event) => {
    event.preventDefault();
    const name = input.value.trim();
    if (!name) {
      setMessage(message, "A key needs a name (1 to 64 characters).", "error");
      return;
    }
    const result = await send(`/v1/api-keys/${key.id}`, { method: "PATCH", body: { name } }).catch((error) => ({ error }));
    if (result.error || !result.ok) {
      if (result.status !== 401) setMessage(message, result.error ? result.error.message : failureText(result), "error");
      return;
    }
    editing = null;
    setMessage(message, `Renamed to ${name}.`, "success");
    if (key.current) state.key = { ...state.key, name };
    await load();
  };
  const form = h(
    "form",
    { class: "rename-form", onsubmit: save },
    input,
    h("button", { type: "submit", class: "button button-primary button-small" }, "Save"),
    h(
      "button",
      {
        type: "button",
        class: "button button-secondary button-small",
        onclick: () => {
          editing = null;
          renderTable();
        },
      },
      "Cancel"
    )
  );
  window.setTimeout(() => input.focus(), 0);
  return h("td", { class: "key-name" }, form);
}

async function revoke(key) {
  const question = key.current
    ? `Revoke ${key.name}? It is this console's own key: the console will be logged out.`
    : `Revoke ${key.name}? Apps using it stop working at once.`;
  if (!window.confirm(question)) return;
  const result = await send(`/v1/api-keys/${key.id}`, { method: "DELETE" }).catch((error) => ({ error }));
  if (result.error) {
    setMessage(message, result.error.message, "error");
    return;
  }
  if (!result.ok) {
    if (result.status !== 401) setMessage(message, failureText(result), "error");
    return;
  }
  if (key.current) {
    handleUnauthorized("This console's key was revoked. Connect again to keep using the console.");
    return;
  }
  setMessage(message, `${key.name} was revoked.`, "success");
  await load();
}

function renderTable() {
  if (!keys.length) {
    tableBody.replaceChildren(h("tr", {}, h("td", { colspan: "6", class: "help" }, "No keys.")));
    return;
  }
  tableBody.replaceChildren(
    ...keys.map((key) =>
      h(
        "tr",
        { class: key.current ? "is-current" : "" },
        nameCell(key),
        h("td", {}, h("code", {}, key.id)),
        h("td", {}, roleSelect(key)),
        h("td", { class: "nowrap" }, formatTime(key.created_at)),
        h("td", { class: "nowrap" }, key.last_used_at ? formatTime(key.last_used_at) : "not since the driver started"),
        h(
          "td",
          { class: "actions" },
          h(
            "button",
            {
              type: "button",
              class: "button button-secondary button-small",
              onclick: () => {
                editing = key.id;
                renderTable();
              },
            },
            "Rename"
          ),
          h("button", { type: "button", class: "button button-danger button-small", onclick: () => revoke(key) }, "Revoke")
        )
      )
    )
  );
}

createForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const name = createName.value.trim();
  if (!name) {
    setMessage(message, "Give the new key a name, e.g. the app or script that will use it.", "error");
    return;
  }
  const result = await send("/v1/api-keys", { method: "POST", body: { name, role: createRole.value } }).catch((error) => ({ error }));
  if (result.error) {
    setMessage(message, result.error.message, "error");
    return;
  }
  if (!result.ok) {
    if (result.status !== 401) setMessage(message, failureText(result), "error");
    return;
  }
  createName.value = "";
  secretName.textContent = `${result.data.name} (${result.data.role})`;
  secretValue.textContent = result.data.key;
  secretPanel.hidden = false;
  setMessage(message, "");
  secretPanel.scrollIntoView({ block: "nearest" });
  await load();
});

secretCopy.addEventListener("click", () => copyWithFeedback(secretCopy, secretValue.textContent));

function hideSecret() {
  secretValue.textContent = "";
  secretName.textContent = "";
  secretPanel.hidden = true;
}

byId("key-secret-dismiss").addEventListener("click", hideSecret);
refreshButton.addEventListener("click", () => {
  setMessage(message, "");
  load();
});

export function showKeys() {
  const allowed = Boolean(state.apiKey) && can("admin");
  locked.hidden = allowed;
  panel.hidden = !allowed;
  refreshButton.hidden = !allowed;
  for (const element of locked.querySelectorAll(".locked-role")) element.textContent = state.role || "not connected";
  if (allowed) load();
}

// Leaving the tab or changing key: the one-time secret is not kept on screen.
export function resetKeys() {
  hideSecret();
  keys = [];
  editing = null;
  tableBody.replaceChildren();
  setMessage(message, "");
}
