// Logs tab (admin): follows GET /v1/logs every 2 s, with filters, search, download and the
// recording level (GET/PATCH /v1/logs/settings).

import { byId, downloadText, h, prettyJson } from "./dom.js";
import { can, send, state } from "./session.js";

const POLL_MS = 2000;
const MAX_ENTRIES = 2000;

const locked = byId("logs-locked");
const panel = byId("logs-panel");
const pauseButton = byId("log-pause");
const levelSelect = byId("log-level");
const categoryInput = byId("log-category");
const chipBox = byId("log-category-chips");
const searchInput = byId("log-search");
const recordSelect = byId("log-record-level");
const statusLine = byId("log-status");
const list = byId("log-list");

let entries = [];
let lastSeq = 0;
let paused = false;
let active = false;
let timer = null;
let polling = false;
let generation = 0;
let recordingLevel = null;
const categories = new Set();
let statusText = "";
let statusKind = "";

function setStatus(text, kind = "") {
  statusText = text;
  statusKind = kind;
  const shown = entries.length ? `${entries.length} entr${entries.length === 1 ? "y" : "ies"} loaded` : "No entries yet";
  statusLine.textContent = [text, shown].filter(Boolean).join(" · ");
  statusLine.className = `log-status${kind ? ` log-status-${kind}` : ""}`;
}

function matchesSearch(entry, query) {
  if (!query) return true;
  const text = `${entry.time} ${entry.level} ${entry.category} ${entry.message} ${entry.data ? JSON.stringify(entry.data) : ""}`;
  return text.toLowerCase().includes(query);
}

function entryRow(entry) {
  const hasData = entry.data && typeof entry.data === "object" && Object.keys(entry.data).length > 0;
  const row = h("div", { class: `log-entry log-${entry.level}`, dataset: { seq: String(entry.seq) } });
  const line = h(
    hasData ? "button" : "div",
    { class: "log-line", type: hasData ? "button" : null, "aria-expanded": hasData ? "false" : null },
    h("span", { class: "log-time" }, String(entry.time || "").replace("T", " ").replace("Z", "")),
    h("span", { class: "log-level" }, entry.level),
    h("span", { class: "log-category" }, entry.category),
    h("span", { class: "log-message" }, entry.message, hasData ? h("span", { class: "log-data-hint" }, ` ${compactData(entry.data)}`) : null)
  );
  row.append(line);
  if (hasData) {
    line.addEventListener("click", () => {
      const open = line.getAttribute("aria-expanded") === "true";
      line.setAttribute("aria-expanded", String(!open));
      const existing = row.querySelector(".log-data");
      if (open) existing?.remove();
      else row.append(h("pre", { class: "code log-data" }, prettyJson(entry.data)));
    });
  }
  return row;
}

function compactData(data) {
  const text = JSON.stringify(data);
  return text.length > 140 ? `${text.slice(0, 139)}…` : text;
}

function renderChips() {
  const current = categoryInput.value.trim();
  chipBox.replaceChildren(
    ...[...categories].sort().map((category) =>
      h(
        "button",
        {
          type: "button",
          class: `chip${category === current ? " is-active" : ""}`,
          "aria-pressed": String(category === current),
          onclick: () => {
            categoryInput.value = category === current ? "" : category;
            applyServerFilters();
          },
        },
        category
      )
    )
  );
  chipBox.hidden = categories.size === 0;
}

function nearBottom() {
  return list.scrollTop + list.clientHeight >= list.scrollHeight - 48;
}

function appendEntries(items) {
  const stick = nearBottom();
  const query = searchInput.value.trim().toLowerCase();
  const fragment = document.createDocumentFragment();
  let newCategory = false;
  for (const entry of items) {
    entries.push(entry);
    if (entry.category && !categories.has(entry.category)) {
      categories.add(entry.category);
      newCategory = true;
    }
    if (matchesSearch(entry, query)) fragment.append(entryRow(entry));
  }
  list.append(fragment);
  if (entries.length > MAX_ENTRIES) entries = entries.slice(-MAX_ENTRIES);
  while (list.childElementCount > MAX_ENTRIES) list.firstElementChild.remove();
  if (newCategory) renderChips();
  if (stick) list.scrollTop = list.scrollHeight;
}

function rerenderList() {
  const query = searchInput.value.trim().toLowerCase();
  const rows = entries.filter((entry) => matchesSearch(entry, query)).slice(-MAX_ENTRIES).map(entryRow);
  list.replaceChildren(...rows);
  list.scrollTop = list.scrollHeight;
  setStatus(statusText, statusKind);
}

async function poll() {
  timer = null;
  if (!active || paused || polling || !state.apiKey || !can("admin")) return;
  if (document.hidden) {
    schedule();
    return;
  }
  polling = true;
  const run = generation;
  const params = new URLSearchParams({ after: String(lastSeq), limit: "200" });
  if (levelSelect.value) params.set("level", levelSelect.value);
  if (categoryInput.value.trim()) params.set("category", categoryInput.value.trim());
  try {
    const result = await send(`/v1/logs?${params}`);
    if (run !== generation) return;
    if (!result.ok) {
      setStatus(result.data?.detail || `DirectorLink answered HTTP ${result.status}.`, "error");
    } else if ((result.data.last_seq ?? 0) < lastSeq) {
      // The driver restarted and numbers entries from 1 again.
      lastSeq = 0;
      setStatus("The bridge restarted; reading its new log", "warn");
    } else {
      // Never show an entry twice, even if two polls overlap.
      appendEntries((result.data.items || []).filter((entry) => entry.seq > lastSeq));
      lastSeq = Math.max(lastSeq, result.data.last_seq ?? 0);
      if (result.data.level && result.data.level !== recordingLevel) {
        recordingLevel = result.data.level;
        recordSelect.value = recordingLevel;
      }
      setStatus(`Following · recording level ${result.data.level || "?"}`);
    }
  } catch (error) {
    if (run === generation) setStatus(`${error.message} Still trying.`, "error");
  } finally {
    polling = false;
    if (run === generation) schedule();
  }
}

function schedule() {
  window.clearTimeout(timer);
  if (active && !paused) timer = window.setTimeout(poll, POLL_MS);
}

// Level and category filters are applied by the bridge: reload the matching history.
function applyServerFilters() {
  generation += 1;
  polling = false;
  entries = [];
  lastSeq = 0;
  list.replaceChildren();
  renderChips();
  setStatus(paused ? "Paused" : "Loading…");
  window.clearTimeout(timer);
  if (active && !paused) poll();
}

async function loadRecordingLevel() {
  try {
    const result = await send("/v1/logs/settings");
    if (result.ok && result.data?.level) {
      recordingLevel = result.data.level;
      recordSelect.value = recordingLevel;
    }
  } catch {
    // Shown by the next poll.
  }
}

recordSelect.addEventListener("change", async () => {
  const level = recordSelect.value;
  recordSelect.disabled = true;
  try {
    const result = await send("/v1/logs/settings", { method: "PATCH", body: { level } });
    if (result.ok) {
      recordingLevel = result.data?.level || level;
      setStatus(`Recording level set to ${recordingLevel}${recordingLevel === "debug" ? " — remember to set it back to info" : ""}`, recordingLevel === "debug" ? "warn" : "");
    } else {
      recordSelect.value = recordingLevel || "info";
      setStatus(result.data?.detail || `Could not change the level (HTTP ${result.status}).`, "error");
    }
  } catch (error) {
    recordSelect.value = recordingLevel || "info";
    setStatus(error.message, "error");
  } finally {
    recordSelect.disabled = false;
  }
});

pauseButton.addEventListener("click", () => {
  paused = !paused;
  pauseButton.textContent = paused ? "Resume" : "Pause";
  pauseButton.setAttribute("aria-pressed", String(paused));
  if (paused) {
    window.clearTimeout(timer);
    setStatus("Paused");
  } else {
    setStatus("Following…");
    poll();
  }
});

levelSelect.addEventListener("change", applyServerFilters);
categoryInput.addEventListener("change", applyServerFilters);
categoryInput.addEventListener("keydown", (event) => {
  if (event.key === "Enter") {
    event.preventDefault();
    applyServerFilters();
  }
});
searchInput.addEventListener("input", rerenderList);

byId("log-clear").addEventListener("click", () => {
  // Keeps following from the current position; only the view is emptied.
  entries = [];
  list.replaceChildren();
  setStatus(paused ? "Paused" : "Following");
});

byId("log-download").addEventListener("click", () => {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..*$/, "").replace("T", "-");
  downloadText(`directorlink-log-${stamp}.jsonl`, entries.map((entry) => JSON.stringify(entry)).join("\n") + (entries.length ? "\n" : ""), "application/x-ndjson");
});

document.addEventListener("visibilitychange", () => {
  if (!document.hidden && active && !paused && !timer && !polling) poll();
});

export function showLogs() {
  const allowed = Boolean(state.apiKey) && can("admin");
  locked.hidden = allowed;
  panel.hidden = !allowed;
  for (const element of locked.querySelectorAll(".locked-role")) element.textContent = state.role || "not connected";
  if (!allowed) {
    hideLogs();
    return;
  }
  if (!active) {
    active = true;
    loadRecordingLevel();
    if (!paused) poll();
    else setStatus("Paused");
  }
}

export function hideLogs() {
  active = false;
  window.clearTimeout(timer);
  timer = null;
}

// A different key or controller: start from scratch.
export function resetLogs() {
  hideLogs();
  generation += 1;
  entries = [];
  lastSeq = 0;
  categories.clear();
  list.replaceChildren();
  renderChips();
  statusLine.textContent = "";
}
