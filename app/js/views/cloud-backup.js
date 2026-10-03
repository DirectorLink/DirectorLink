// Settings → Controller → Backup → Automatic backups to your account (admins; ADR-048,
// docs/BACKUP.md). An admin sets a backup password once; the controller then sends a backup to the
// account every night, sealed so that only that password opens it. The backups in the account are
// listed here (date and size), and one is restored by typing its password: it is opened in this
// browser and goes to the same check and Replace everything as a file (views/backup.js). Shown
// when GET /v1/system says the controller has them (features.automatic_backup, 1.6.0).

import { BackupFileError, MIN_PASSWORD, passwordStrength } from "../backup.js";
import { automaticStatus, backUpNow, openAccountBackup, setBackupPassword, turnOffAutomatic } from "../cloud-backup.js";
import { h } from "../dom.js";
import { formatDateTime, formatNumber, t } from "../i18n.js";
import { icon } from "../icons.js";
import { deleteHomeBackups, listAccountHomes, listHomeBackups, savedRemote } from "../remote.js";
import { errorText, whenForgotten } from "../session.js";
import { notify, state, ui } from "../state.js";

// While a backup is being made the controller is asked how it went this often, this many times.
const POLL_MS = 3000;
const POLL_TIMES = 60;
// What the section shows is read again when it is drawn this long after (not while a form is open).
const FRESH_MS = 60000;

// The passwords stay in this module, never in storage or in `ui`, and go when the form closes.
let secrets = {};
function forgetSecrets() {
  secrets = { password: "", confirm: "", open: "" };
}
forgetSecrets();
let polling = null;
whenForgotten(() => {
  forgetSecrets();
  polling = null;
  ui.autoBackup = null;
});

// ui.autoBackup: { loaded, loading, at, status (GET /v1/backup/automatic), account ({ lists } or
// { error }), stage: null | "password" | "restore", restore ({ homeId, item }), busy, message }.
function section() {
  ui.autoBackup ??= { stage: null };
  return ui.autoBackup;
}

function say(kind, text) {
  section().message = { kind, text };
  notify();
}

// Why a backup was not made, or Back up now refused.
function reasonText(code) {
  const key = {
    REMOTE_ACCESS_OFF: "remoteOff",
    REMOTE_OFFLINE: "offline",
    HOME_NOT_LINKED: "notLinked",
    NOT_CLAIMED: "notLinked",
    LOCK_UNAVAILABLE: "noLock",
    BACKUP_TOO_LARGE: "tooLarge",
    BACKUP_RUNNING: "running",
    PROJECT_NOT_READY: "notReady",
  }[code];
  return key ? t(`backup.automatic.reasons.${key}`) : t("backup.automatic.reasons.other", { code: code || "?" });
}

const errorOf = (error) => (error?.code && error?.status ? reasonText(error.code) : errorText(error));

export function sizeText(bytes) {
  if (!Number.isFinite(bytes)) return "";
  if (bytes < 1000000) return t("backup.automatic.kilobytes", { size: formatNumber(Math.max(1, Math.round(bytes / 1000))) });
  return t("backup.automatic.megabytes", { size: formatNumber(Math.round(bytes / 100000) / 10) });
}

// The home's backups in the account: the account's homes (this device's link first), each one the
// account may see.
async function accountBackups() {
  let ids;
  try {
    ids = ((await listAccountHomes())?.items || []).map((item) => item.home_id);
  } catch (error) {
    return { error };
  }
  const linked = savedRemote()?.home;
  if (linked) ids = [linked, ...ids.filter((id) => id !== linked)];
  const lists = await Promise.all(
    ids.map((homeId) =>
      listHomeBackups(homeId).then(
        (answer) => ({ homeId, items: Array.isArray(answer?.items) ? answer.items : [] }),
        // Not an admin there, or an account service before 1.6.0.
        (error) => (["ADMINS_ONLY", "NOT_A_MEMBER", "OWNER_ONLY", "NOT_FOUND"].includes(error?.code) ? null : { homeId, error })
      )
    )
  );
  return { lists: lists.filter(Boolean) };
}

let loading = null;
// What the section shows: the controller's settings and the account's backups.
export function loadAutomatic() {
  loading ??= (async () => {
    const current = section();
    current.loading = true;
    try {
      const [status, account] = await Promise.all([
        automaticStatus().catch((error) => ({ error })),
        state.account.status === "signed-in" ? accountBackups() : Promise.resolve(null),
      ]);
      Object.assign(section(), { loading: false, loaded: true, at: Date.now(), status, account });
    } finally {
      loading = null;
      notify();
    }
  })();
  return loading;
}

// Asks the controller until the backup it is making is done, then reads the list again.
function watchBackup() {
  const token = {};
  polling = token;
  let times = 0;
  const next = () =>
    window.setTimeout(async () => {
      if (polling !== token) return;
      times += 1;
      let status = null;
      try {
        status = await automaticStatus();
      } catch {
        status = null;
      }
      if (polling !== token) return;
      if (status?.running && times < POLL_TIMES) {
        next();
        return;
      }
      polling = null;
      section().busy = false;
      if (status?.last?.ok) say("success", t("backup.automatic.uploaded"));
      else if (status?.last) say("error", t("backup.automatic.notMade", { reason: reasonText(status.last.code) }));
      await loadAutomatic();
    }, POLL_MS);
  next();
}

async function runNow(afterSet = false) {
  const current = section();
  current.busy = true;
  if (!afterSet) current.message = { kind: "info", text: t("backup.automatic.working") };
  notify();
  try {
    await backUpNow();
    if (afterSet) say("success", t("backup.automatic.setAndRunning"));
    else say("info", t("backup.automatic.working"));
    watchBackup();
  } catch (error) {
    current.busy = false;
    // Remote Access off is said under the status already.
    if (afterSet) say("success", error?.code === "REMOTE_ACCESS_OFF" ? t("backup.automatic.set") : `${t("backup.automatic.set")} ${t("backup.automatic.notNow", { reason: errorOf(error) })}`);
    else say("error", errorOf(error));
    await loadAutomatic();
  }
}

// ---- The backup password ------------------------------------------------------------------------

function field(id, label, ...content) {
  return h("div", { class: "field" }, h("label", { class: "field-label", for: id }, label), ...content);
}

// The typed value is set as the input's value, never as its value attribute.
function passwordInput(id, value, autocomplete, onInput) {
  const input = h("input", {
    id,
    type: "password",
    autocomplete,
    autocapitalize: "off",
    spellcheck: "false",
    minlength: String(MIN_PASSWORD),
    dataset: { key: id },
    oninput: (event) => onInput(event.target.value),
  });
  input.value = value;
  return input;
}

const strengthText = (password) =>
  password ? `${t("backup.downloadForm.strengthLabel")}: ${t(`backup.downloadForm.strength.${passwordStrength(password)}`)}` : "";

function close(message = null) {
  forgetSecrets();
  const current = section();
  current.stage = null;
  current.restore = null;
  current.busy = false;
  current.message = message;
  notify();
}

async function savePassword(event) {
  event.preventDefault();
  const current = section();
  if (current.busy) return;
  if (secrets.password.length < MIN_PASSWORD) return say("error", t("backup.downloadForm.tooShort", { count: MIN_PASSWORD }));
  if (secrets.password !== secrets.confirm) return say("error", t("backup.downloadForm.mismatch"));
  current.busy = true;
  current.message = { kind: "info", text: t("backup.automatic.making") };
  notify();
  try {
    current.status = await setBackupPassword(secrets.password);
  } catch (error) {
    current.busy = false;
    say("error", errorOf(error));
    return;
  }
  close();
  // The first backup with this password, now.
  await runNow(true);
}

function passwordForm(current) {
  const changing = current.status?.enabled === true;
  const strength = h("p", { class: "field-help", id: "auto-backup-strength", "aria-live": "polite", dataset: { key: "auto-backup-strength" } }, strengthText(secrets.password));
  return h(
    "form",
    { class: "backup-form", onsubmit: savePassword, novalidate: true },
    h("p", { class: "notice notice-info" }, t("backup.automatic.warning")),
    changing ? h("p", { class: "field-help", dataset: { key: "auto-backup-older" } }, t("backup.automatic.changeNote")) : null,
    field(
      "auto-backup-password",
      t(changing ? "backup.automatic.newPassword" : "backup.automatic.password"),
      passwordInput("auto-backup-password", secrets.password, "new-password", (value) => {
        secrets.password = value;
        strength.textContent = strengthText(value);
      }),
      h("p", { class: "field-help" }, t("backup.downloadForm.hint", { count: MIN_PASSWORD })),
      strength
    ),
    field(
      "auto-backup-confirm",
      t("backup.downloadForm.confirm"),
      passwordInput("auto-backup-confirm", secrets.confirm, "new-password", (value) => {
        secrets.confirm = value;
      })
    ),
    h(
      "div",
      { class: "button-row" },
      h("button", { type: "submit", class: "button button-primary", dataset: { key: "auto-backup-save" }, disabled: Boolean(current.busy) }, t(changing ? "backup.automatic.change" : "backup.automatic.turnOn")),
      h("button", { type: "button", class: "button button-quiet", dataset: { key: "auto-backup-cancel" }, disabled: Boolean(current.busy), onclick: () => close() }, t("backup.cancel"))
    )
  );
}

async function turnOff() {
  const current = section();
  if (current.busy || !window.confirm(t("backup.automatic.turnOffConfirm"))) return;
  current.busy = true;
  notify();
  try {
    await turnOffAutomatic();
    polling = null;
    current.busy = false;
    say("success", t("backup.automatic.turnedOff"));
  } catch (error) {
    current.busy = false;
    say("error", errorOf(error));
  }
  await loadAutomatic();
}

async function deleteAll(homeId) {
  const current = section();
  if (current.busy || !window.confirm(t("backup.automatic.deleteConfirm"))) return;
  current.busy = true;
  notify();
  try {
    await deleteHomeBackups(homeId);
    current.busy = false;
    say("success", t("backup.automatic.deleted"));
  } catch (error) {
    current.busy = false;
    say("error", errorText(error));
  }
  await loadAutomatic();
}

// ---- Restoring one ----------------------------------------------------------------------------------

function wrongPassword(error) {
  if (error instanceof BackupFileError) {
    return t({ WRONG_PASSWORD: "backup.automatic.wrongPassword", NEWER_FILE: "backup.errors.newerFile" }[error.code] || "backup.errors.notABackup");
  }
  return null;
}

function restoreForm(current, { check, errorOf: checkError }) {
  const { homeId, item } = current.restore;
  const older = isOlderKey(item);
  async function openIt(event) {
    event.preventDefault();
    if (current.busy) return;
    if (!secrets.open) return say("error", t("backup.restoreForm.typePassword"));
    current.busy = true;
    current.message = { kind: "info", text: t("backup.automatic.opening") };
    notify();
    try {
      const document = await openAccountBackup(homeId, item.id, secrets.open);
      say("info", t("backup.restoreForm.checking"));
      await check(document);
      close();
    } catch (error) {
      current.busy = false;
      if (ui.autoBackup === current) say("error", wrongPassword(error) || checkError(error));
    }
  }
  return h(
    "form",
    { class: "backup-form", onsubmit: openIt, novalidate: true, dataset: { key: "auto-backup-restore-form" } },
    h("p", { class: "field-help" }, t("backup.automatic.restoreIntro", { date: formatDateTime(new Date(item.created_at)) })),
    older ? h("p", { class: "notice notice-info" }, t("backup.automatic.olderPassword")) : null,
    field(
      "auto-backup-open",
      t("backup.automatic.password"),
      passwordInput("auto-backup-open", secrets.open, "current-password", (value) => {
        secrets.open = value;
      })
    ),
    h(
      "div",
      { class: "button-row" },
      h("button", { type: "submit", class: "button button-primary", dataset: { key: "auto-backup-open-submit" }, disabled: Boolean(current.busy) }, t("backup.restoreForm.submit")),
      h("button", { type: "button", class: "button button-quiet", dataset: { key: "auto-backup-cancel" }, disabled: Boolean(current.busy), onclick: () => close() }, t("backup.cancel"))
    )
  );
}

// Made with another backup password than the one set now.
function isOlderKey(item) {
  const key = section().status?.key;
  return Boolean(key?.key_id && item.key_id !== key.key_id);
}

// ---- The section ------------------------------------------------------------------------------------

function backupList(list, many) {
  const current = section();
  return h(
    "div",
    { class: "backup-references", dataset: { key: `auto-backup-list-${list.homeId}` } },
    h("h4", { class: "backup-heading" }, many ? t("backup.automatic.listOf", { home: list.homeId.slice(0, 8) }) : t("backup.automatic.list")),
    list.error
      ? h("p", { class: "notice notice-error" }, errorText(list.error))
      : list.items.length
        ? h(
            "ul",
            { class: "auto-backup-items" },
            list.items.map((item) =>
              h(
                "li",
                { dataset: { key: `auto-backup-item-${item.id}` } },
                h("span", {}, formatDateTime(new Date(item.created_at)), " · ", sizeText(item.size), isOlderKey(item) ? ` · ${t("backup.automatic.earlier")}` : ""),
                " ",
                h(
                  "button",
                  {
                    type: "button",
                    class: "button button-quiet",
                    dataset: { key: `auto-backup-restore-${item.id}` },
                    disabled: Boolean(current.busy),
                    onclick: () => {
                      forgetSecrets();
                      Object.assign(section(), { stage: "restore", restore: { homeId: list.homeId, item }, message: null });
                      notify();
                    },
                  },
                  t("backup.automatic.restore")
                )
              )
            )
          )
        : h("p", { class: "field-help" }, t("backup.automatic.none")),
    !list.error && list.items.length
      ? h(
          "div",
          { class: "button-row" },
          h("button", { type: "button", class: "button button-quiet", dataset: { key: `auto-backup-delete-${list.homeId}` }, disabled: Boolean(current.busy), onclick: () => deleteAll(list.homeId) }, t("backup.automatic.delete"))
        )
      : null
  );
}

function statusLines(status) {
  const lines = [];
  if (status.enabled) {
    lines.push(h("p", { class: "field-help", dataset: { key: "auto-backup-on" } }, t("backup.automatic.on", { time: status.time || "—" })));
  } else {
    lines.push(h("p", { class: "field-help", dataset: { key: "auto-backup-off" } }, t("backup.automatic.off")));
  }
  const last = status.last;
  if (status.enabled && status.running) {
    lines.push(h("p", { class: "field-help", role: "status" }, t("backup.automatic.working")));
  } else if (status.enabled && last) {
    const date = formatDateTime(new Date(last.at));
    lines.push(
      last.ok
        ? h("p", { class: "field-help", dataset: { key: "auto-backup-last" } }, t("backup.automatic.last", { date, size: sizeText(last.size) }))
        : h("p", { class: "notice notice-error", dataset: { key: "auto-backup-last" } }, t("backup.automatic.lastFailed", { date, reason: reasonText(last.code) }))
    );
  }
  if (status.enabled && status.remote && !status.remote.enabled) {
    lines.push(h("p", { class: "notice notice-info" }, t("backup.automatic.reasons.remoteOff")));
  }
  return lines;
}

// The section inside Settings → Controller → Backup. `check(document)`: the backup's check and
// preview (views/backup.js); `errorOf(error)`: what to say when that fails.
export function automaticSection(options) {
  if (state.system?.features?.automatic_backup !== true) return null;
  const current = section();
  const content = [h("h3", { class: "settings-subtitle", id: "auto-backup-title" }, t("backup.automatic.title"))];
  if (state.account.status !== "signed-in") {
    content.push(h("p", { class: "field-help", dataset: { key: "auto-backup-sign-in" } }, t("backup.automatic.signIn")));
    return h("div", { class: "auto-backup", dataset: { key: "auto-backup" } }, ...content);
  }
  if (!current.loading && (!current.loaded || (!current.stage && !current.busy && Date.now() - (current.at || 0) > FRESH_MS))) loadAutomatic();
  if (current.message) {
    content.push(
      h("p", { class: `notice notice-${current.message.kind}`, role: current.message.kind === "error" ? "alert" : "status", dataset: { key: "auto-backup-message" } }, current.message.text)
    );
  }
  if (!current.loaded) {
    content.push(h("p", { class: "field-help", role: "status" }, t("common.loading")));
    return h("div", { class: "auto-backup", dataset: { key: "auto-backup" } }, ...content);
  }
  const status = current.status || {};
  if (current.stage === "password") {
    content.push(passwordForm(current));
  } else if (current.stage === "restore" && current.restore) {
    content.push(restoreForm(current, options));
  } else {
    if (status.error) {
      content.push(h("p", { class: "notice notice-error" }, errorText(status.error)));
    } else {
      content.push(...statusLines(status));
      const open = () => {
        forgetSecrets();
        Object.assign(section(), { stage: "password", message: null });
        notify();
      };
      content.push(
        h(
          "div",
          { class: "button-row" },
          status.enabled
            ? [
                h("button", { type: "button", class: "button button-secondary", dataset: { key: "auto-backup-now" }, disabled: Boolean(current.busy || status.running), onclick: () => runNow() }, icon("archive"), t("backup.automatic.now")),
                h("button", { type: "button", class: "button button-quiet", dataset: { key: "auto-backup-change" }, disabled: Boolean(current.busy), onclick: open }, t("backup.automatic.changeButton")),
                h("button", { type: "button", class: "button button-quiet", dataset: { key: "auto-backup-off-button" }, disabled: Boolean(current.busy), onclick: turnOff }, t("backup.automatic.turnOff")),
              ]
            : h("button", { type: "button", class: "button button-secondary", dataset: { key: "auto-backup-set" }, disabled: Boolean(current.busy), onclick: open }, t("backup.automatic.setButton"))
        )
      );
    }
    const account = current.account;
    if (account?.error) {
      content.push(h("p", { class: "notice notice-error" }, errorText(account.error)));
    } else if (account?.lists) {
      const shown = account.lists.filter((list) => list.items.length || list.error || list.homeId === savedRemote()?.home);
      for (const list of shown.length ? shown : account.lists.slice(0, 1)) content.push(backupList(list, shown.length > 1));
      if (!account.lists.length) content.push(h("p", { class: "field-help" }, t("backup.automatic.none")));
    }
  }
  return h("div", { class: "auto-backup", dataset: { key: "auto-backup" } }, ...content);
}
