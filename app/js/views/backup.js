// Settings → Controller → Backup (admins; ADR-042, docs/BACKUP.md): download everything
// DirectorLink keeps as a file locked with a password, and restore from one. The file is opened
// here, the controller checks it without changing anything, and only once the admin has seen what
// it holds and confirmed is everything replaced.

import { BackupFileError, FILE_EXTENSION, MIN_PASSWORD, checkBackup, decryptBackup, makeBackup, passwordStrength, readHeader, restoreBackup } from "../backup.js";
import { h, name } from "../dom.js";
import { formatDateTime, t } from "../i18n.js";
import { icon } from "../icons.js";
import { saveRemote, savedRemote } from "../remote.js";
import { connect, errorText, whenForgotten } from "../session.js";
import { can, notify, state, ui } from "../state.js";

// What is typed and chosen: the passwords, the file and the opened backup stay in this module,
// never in storage or in `ui` (the redraw signature), and go when the panel closes.
let secrets = {};

function forgetSecrets() {
  secrets = { password: "", confirm: "", open: "", file: null, document: null, upload: null };
}
forgetSecrets();
// This device's key forgotten (Forget, Pair again, a revoked key): nothing of a backup stays.
whenForgotten(() => {
  forgetSecrets();
  ui.backup = { stage: null };
});

// ui.backup: { stage: null | "download" | "restore" | "preview" | "done", busy, message, fileName,
// header, preview, result, relinked }.
function panel() {
  ui.backup ??= { stage: null };
  return ui.backup;
}

function show(stage, extra = {}) {
  ui.backup = { stage, ...extra };
  notify();
}

function close(message = null) {
  forgetSecrets();
  show(null, message ? { message } : {});
}

function say(kind, text) {
  panel().message = { kind, text };
  notify();
}

export function backupError(error) {
  if (error instanceof BackupFileError) {
    return t({ WRONG_PASSWORD: "backup.errors.wrongPassword", NEWER_FILE: "backup.errors.newerFile" }[error.code] || "backup.errors.notABackup");
  }
  const key = {
    BACKUP_TOO_NEW: "backup.errors.tooNew",
    BACKUP_INVALID: "backup.errors.invalid",
    PROJECT_NOT_READY: "backup.errors.notReady",
    RESTORE_FAILED: "backup.errors.failed",
    BACKUP_TOO_LARGE: "backup.errors.tooLarge",
    SEALED_REQUEST_REQUIRED: "backup.errors.sealed",
  }[error?.code];
  return key ? t(key) : errorText(error);
}

function field(id, label, ...content) {
  return h("div", { class: "field" }, h("label", { class: "field-label", for: id }, label), ...content);
}

function passwordInput(id, value, autocomplete, onInput) {
  return h("input", {
    id,
    type: "password",
    autocomplete,
    autocapitalize: "off",
    spellcheck: "false",
    minlength: String(MIN_PASSWORD),
    value,
    dataset: { key: id },
    oninput: (event) => onInput(event.target.value),
  });
}

function buttons(...children) {
  return h("div", { class: "button-row" }, ...children);
}

function cancelButton() {
  return h("button", { type: "button", class: "button button-quiet", dataset: { key: "backup-cancel" }, disabled: Boolean(panel().busy), onclick: () => close() }, t("backup.cancel"));
}

// ---- Download ----------------------------------------------------------------------------------

function strengthText(password) {
  return password ? `${t("backup.downloadForm.strengthLabel")}: ${t(`backup.downloadForm.strength.${passwordStrength(password)}`)}` : "";
}

// Saves the file through the browser's download.
function saveFile(text, fileName) {
  const url = URL.createObjectURL(new Blob([text], { type: "application/octet-stream" }));
  const link = h("a", { href: url, download: fileName, hidden: true });
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 60000);
}

async function download(event) {
  event.preventDefault();
  const current = panel();
  if (current.busy) return;
  if (secrets.password.length < MIN_PASSWORD) return say("error", t("backup.downloadForm.tooShort", { count: MIN_PASSWORD }));
  if (secrets.password !== secrets.confirm) return say("error", t("backup.downloadForm.mismatch"));
  current.busy = true;
  current.message = { kind: "info", text: t("backup.downloadForm.working") };
  notify();
  try {
    const { text, fileName } = await makeBackup(secrets.password);
    saveFile(text, fileName);
    close({ kind: "success", text: t("backup.downloadForm.saved", { name: fileName }) });
  } catch (error) {
    current.busy = false;
    if (ui.backup === current) say("error", backupError(error));
  }
}

function downloadForm(current) {
  const strength = h("p", { class: "field-help", id: "backup-strength", "aria-live": "polite" }, strengthText(secrets.password));
  return h(
    "form",
    { class: "backup-form", onsubmit: download, novalidate: true },
    h("p", { class: "notice notice-info" }, t("backup.downloadForm.warning")),
    field(
      "backup-password",
      t("backup.downloadForm.password"),
      passwordInput("backup-password", secrets.password, "new-password", (value) => {
        secrets.password = value;
        strength.textContent = strengthText(value);
      }),
      h("p", { class: "field-help" }, t("backup.downloadForm.hint", { count: MIN_PASSWORD })),
      strength
    ),
    field(
      "backup-confirm",
      t("backup.downloadForm.confirm"),
      passwordInput("backup-confirm", secrets.confirm, "new-password", (value) => {
        secrets.confirm = value;
      })
    ),
    buttons(
      h("button", { type: "submit", class: "button button-primary", dataset: { key: "backup-download-submit" }, disabled: Boolean(current.busy) }, icon("download"), t("backup.downloadForm.submit")),
      cancelButton()
    )
  );
}

// ---- Restore: the file and its password ----------------------------------------------------------

async function chooseFile(event) {
  const chosen = event.target.files?.[0];
  const current = panel();
  secrets.file = null;
  current.header = null;
  current.fileName = null;
  current.message = null;
  if (chosen) {
    try {
      const text = await chosen.text();
      const header = readHeader(text);
      secrets.file = text;
      current.fileName = chosen.name;
      current.header = { home: header.home ?? null, created_at: header.created_at ?? null };
    } catch (error) {
      current.message = { kind: "error", text: backupError(error) };
    }
  }
  notify();
}

async function open(event) {
  event.preventDefault();
  const current = panel();
  if (current.busy) return;
  if (!secrets.file) return say("error", t("backup.restoreForm.chooseFile"));
  if (!secrets.open) return say("error", t("backup.restoreForm.typePassword"));
  current.busy = true;
  current.message = { kind: "info", text: t("backup.restoreForm.opening") };
  notify();
  try {
    const { document } = await decryptBackup(secrets.file, secrets.open);
    say("info", t("backup.restoreForm.checking"));
    const { upload, preview } = await checkBackup(document);
    secrets.document = document;
    secrets.upload = upload;
    secrets.file = null;
    secrets.open = "";
    show("preview", { preview, fileName: current.fileName });
  } catch (error) {
    current.busy = false;
    if (ui.backup === current) say("error", backupError(error));
  }
}

function madeText(home, createdAt) {
  const date = createdAt && Number.isFinite(Date.parse(createdAt)) ? formatDateTime(new Date(createdAt)) : "—";
  return { home: home || t("backup.unnamedHome"), date };
}

function restoreForm(current) {
  const said = current.header ? madeText(current.header.home, current.header.created_at) : null;
  return h(
    "form",
    { class: "backup-form", onsubmit: open, novalidate: true },
    h("p", { class: "field-help" }, t("backup.restoreForm.intro")),
    field(
      "backup-file",
      t("backup.restoreForm.file"),
      h("input", { id: "backup-file", type: "file", accept: `${FILE_EXTENSION},application/octet-stream,application/json`, dataset: { key: "backup-file" }, onchange: chooseFile }),
      said
        ? h("p", { class: "field-help", dataset: { key: "backup-file-says" } }, name(current.fileName || ""), " · ", t("backup.restoreForm.fileSays", said))
        : null
    ),
    field(
      "backup-open-password",
      t("backup.restoreForm.password"),
      passwordInput("backup-open-password", secrets.open, "current-password", (value) => {
        secrets.open = value;
      })
    ),
    buttons(
      h("button", { type: "submit", class: "button button-primary", dataset: { key: "backup-open-submit" }, disabled: Boolean(current.busy) }, t("backup.restoreForm.submit")),
      cancelButton()
    )
  );
}

// ---- What the backup holds, and restoring it -------------------------------------------------------

function kindText(kind) {
  const key = `backup.kinds.${kind}`;
  const text = t(key);
  return text === key ? String(kind) : text;
}

function whereText(use) {
  if (use.section === "scenes") return t("backup.where.scene", { name: use.name || "" });
  if (use.section === "profiles") return t("backup.where.profile", { name: use.name || "" });
  return t(`backup.where.${use.section === "room_order" ? "roomOrder" : "roomNames"}`);
}

function referenceLine(item, extra) {
  const place = item.room ? ` (${item.room})` : "";
  return h("li", { dir: "auto" }, `${kindText(item.kind)} `, name(`${item.name || `#${item.id}`}${place}`), extra ? ` — ${extra}` : "");
}

// What the preview and the result both say: counts, notes, references, Composer.
function summary(preview, { result = false } = {}) {
  const counts = preview.counts || {};
  const keys = preview.keys || {};
  const remote = preview.remote || {};
  const references = preview.references || {};
  const leftOut = preview.left_out || {};
  const notes = [
    t(keys.yours === "added" ? "backup.preview.yoursAdded" : "backup.preview.yoursInBackup"),
    t("backup.preview.othersPair"),
    keys.conflict ? t("backup.preview.conflict") : null,
    keys.expired ? t("backup.preview.expired", { count: keys.expired }) : null,
    keys.over_limit ? t("backup.preview.overLimit", { count: keys.limit }) : null,
    remote.action === "restore" ? t(remote.remote_access ? "backup.preview.remoteRestore" : "backup.preview.remoteOff") : t("backup.preview.remoteSame"),
    t("backup.preview.schedulesFresh"),
    t("backup.preview.invitations"),
    leftOut.steps ? t("backup.preview.leftOutSteps", { count: leftOut.steps }) : null,
    leftOut.schedules ? t("backup.preview.leftOutSchedules", { count: leftOut.schedules }) : null,
    leftOut.scenes || leftOut.profiles ? t("backup.preview.leftOutOther", { count: (leftOut.scenes || 0) + (leftOut.profiles || 0) }) : null,
  ].filter(Boolean);
  const rows = [
    ["scenes", counts.scenes],
    ["schedules", counts.schedules],
    ["keys", counts.keys],
    ["profiles", counts.profiles],
    ["roomNames", counts.room_names],
    ["roomOrder", counts.room_order],
  ];
  const unmatched = references.unmatched || [];
  const byName = references.by_name || [];
  const composer = preview.composer || [];
  return [
    h(
      "dl",
      { class: "facts", dataset: { key: result ? "backup-result-counts" : "backup-preview-counts" } },
      rows.map(([key, value]) => h("div", { class: "fact" }, h("dt", {}, t(`backup.preview.${key}`)), h("dd", {}, String(value ?? 0))))
    ),
    h("ul", { class: "backup-notes" }, notes.map((note) => h("li", {}, note))),
    byName.length
      ? h("div", { class: "backup-references" }, h("h4", { class: "backup-heading" }, t("backup.preview.byName")), h("ul", {}, byName.map((item) => referenceLine(item))))
      : null,
    unmatched.length
      ? h(
          "div",
          { class: "backup-references", dataset: { key: "backup-unmatched" } },
          h("h4", { class: "backup-heading" }, t("backup.preview.unmatched")),
          h(
            "ul",
            {},
            unmatched.map((item) => referenceLine(item, (item.used_in || []).map(whereText).join(", "))),
            references.unmatched_count > unmatched.length ? h("li", {}, t("backup.preview.more", { count: references.unmatched_count - unmatched.length })) : null
          )
        )
      : null,
    composer.length
      ? h(
          "div",
          { class: "backup-composer", dataset: { key: "backup-composer" } },
          h("h4", { class: "backup-heading" }, t("backup.preview.composerTitle")),
          h("p", { class: "field-help" }, t("backup.preview.composerHelp")),
          h(
            "dl",
            { class: "facts" },
            composer.map((item) =>
              h(
                "div",
                { class: "fact" },
                h("dt", { dir: "ltr" }, item.name),
                h("dd", { dir: "auto" }, `${t("backup.preview.composerBackup")}: ${item.backup ?? "—"} · ${t("backup.preview.composerNow")}: ${item.current ?? "—"}`)
              )
            )
          )
        )
      : null,
  ];
}

async function replaceEverything() {
  const current = panel();
  if (current.busy || !secrets.document) return;
  if (!window.confirm(t("backup.preview.confirm"))) return;
  current.busy = true;
  current.message = { kind: "info", text: t("backup.preview.restoring") };
  notify();
  try {
    const answer = await restoreBackup(secrets.document, secrets.upload);
    const result = answer?.restore || current.preview;
    // The home is now the backup's (remote access, ADR-042): a device linked to the one before
    // goes through the account to this one from now on.
    const linked = savedRemote();
    const relinked = Boolean(result?.remote?.action === "restore" && linked && linked.home !== result.remote.home_id);
    if (relinked) saveRemote({ home: result.remote.home_id, keyId: linked.keyId });
    forgetSecrets();
    show("done", { result, relinked, restoredAt: answer?.restored_at || null });
    // Scenes, schedules, profiles and room names are the backup's now.
    connect();
  } catch (error) {
    current.busy = false;
    if (ui.backup === current) say("error", backupError(error));
  }
}

function previewPanel(current) {
  const preview = current.preview || {};
  const made = madeText(preview.backup?.home, preview.backup?.created_at);
  return h(
    "div",
    { class: "backup-preview", dataset: { key: "backup-preview" } },
    h("h4", { class: "backup-heading" }, t("backup.preview.title")),
    h("p", {}, t("backup.preview.made", { ...made, version: preview.backup?.driver_version || "—" })),
    ...summary(preview),
    h("p", { class: "notice notice-error" }, t("backup.preview.warning")),
    buttons(
      h(
        "button",
        { type: "button", class: "button button-danger", dataset: { key: "backup-replace" }, disabled: Boolean(current.busy), onclick: replaceEverything },
        t("backup.preview.replace")
      ),
      cancelButton()
    )
  );
}

function donePanel(current) {
  const result = current.result || {};
  const made = madeText(result.backup?.home, result.backup?.created_at);
  return h(
    "div",
    { class: "backup-preview", dataset: { key: "backup-done" } },
    h("p", { class: "notice notice-success", role: "status" }, t("backup.done.text", made)),
    current.relinked ? h("p", { class: "field-help" }, t("backup.done.relinked")) : null,
    ...summary(result, { result: true }),
    buttons(h("button", { type: "button", class: "button button-secondary", dataset: { key: "backup-done-ok" }, onclick: () => close() }, t("backup.done.ok")))
  );
}

// The panel in the Controller card: for admins, once connected.
export function backupPanel() {
  if (!state.loaded || !can("admin")) return null;
  const current = panel();
  const content = {
    download: downloadForm,
    restore: restoreForm,
    preview: previewPanel,
    done: donePanel,
  }[current.stage];
  return h(
    "div",
    { class: "backup", id: "settings-backup" },
    h("h3", { class: "settings-subtitle" }, t("backup.title")),
    current.stage ? null : h("p", { class: "field-help" }, t("backup.intro")),
    current.message
      ? h("p", { class: `notice notice-${current.message.kind}`, role: current.message.kind === "error" ? "alert" : "status", dataset: { key: "backup-message" } }, current.message.text)
      : null,
    content
      ? content(current)
      : buttons(
          h("button", { type: "button", class: "button button-secondary", dataset: { key: "backup-download" }, onclick: () => (forgetSecrets(), show("download")) }, icon("download"), t("backup.download")),
          h("button", { type: "button", class: "button button-secondary", dataset: { key: "backup-restore" }, onclick: () => (forgetSecrets(), show("restore")) }, icon("refresh"), t("backup.restore"))
        )
  );
}
