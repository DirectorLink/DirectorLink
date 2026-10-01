// Settings → Controller → DirectorLink settings (admins; ADR-043, js/driver-settings.js): the
// settings the app may change, each with a line saying what it does; those set in Composer only,
// with their value; the statuses Composer shows, and the schedules and scenes as Composer's Print
// Schedules and Scenes prints them. Nothing is shown with a DirectorLink before 1.4.0.

import {
  changeSetting,
  closePrintout,
  driverSettings,
  findSetting,
  keepDriverSettings,
  loadDriverSettings,
  openPrintout,
  printoutGroups,
  refreshProject,
} from "../driver-settings.js";
import { h } from "../dom.js";
import { formatDateTime, t } from "../i18n.js";
import { icon } from "../icons.js";
import { can, state } from "../state.js";

const COMPOSER_ONLY = ["door_control", "relay_hold", "alarm_status", "remote_access"];
const STATUSES = ["status", "version", "api_status", "pairing_status", "api_keys", "remote_status", "schedule_status", "last_automation", "calendar_status", "inventory"];
const LEVELS = ["debug", "info", "warn", "error"];

function valueText(setting) {
  const key = `driverSettings.values.${setting.value}`;
  const text = t(key);
  return text === key ? String(setting.composer_value ?? setting.value) : text;
}

// A setting that is on or off, as a switch. `onValue` and `offValue` are the API's values.
function switchRow(current, setting, name, onValue, offValue) {
  if (!setting?.changeable) return null;
  const on = setting.value === onValue;
  const id = `driver-setting-${setting.key}`;
  return h(
    "div",
    { class: "toggle-row driver-setting" },
    h(
      "span",
      { class: "toggle-text" },
      h("span", { class: "toggle-title", id }, t(`driverSettings.${name}.label`)),
      h("span", { class: "field-help" }, t(`driverSettings.${name}.help`))
    ),
    h(
      "button",
      {
        type: "button",
        role: "switch",
        class: "switch",
        "aria-checked": String(on),
        "aria-labelledby": id,
        disabled: Boolean(current.busy),
        dataset: { key: id },
        onclick: () => changeSetting(setting.key, on ? offValue : onValue),
      },
      h("span", { class: "switch-thumb" })
    )
  );
}

function levelRow(current, setting) {
  if (!setting?.changeable) return null;
  const id = "driver-setting-log_level";
  return h(
    "div",
    { class: "field driver-setting" },
    h("label", { class: "field-label", for: id }, t("driverSettings.logLevel.label")),
    h(
      "select",
      {
        id,
        disabled: Boolean(current.busy),
        dataset: { key: id },
        onchange: (event) => changeSetting("log_level", event.target.value),
      },
      LEVELS.map((level) => h("option", { value: level, selected: setting.value === level }, t(`driverSettings.logLevel.levels.${level}`)))
    ),
    h("p", { class: "field-help" }, t("driverSettings.logLevel.help"))
  );
}

function refreshRow(current) {
  return h(
    "div",
    { class: "driver-setting driver-refresh" },
    h("p", { class: "field-help" }, t("driverSettings.refresh.help")),
    h(
      "div",
      { class: "button-row" },
      h(
        "button",
        { type: "button", class: "button button-secondary", disabled: Boolean(current.busy), dataset: { key: "driver-refresh" }, onclick: () => refreshProject() },
        icon("refresh"),
        current.busy === "refresh" ? t("driverSettings.refresh.working") : t("driverSettings.refresh.button")
      )
    )
  );
}

// Set in Composer only: the value, and where it is set (Composer's own name for it).
function composerRows(document) {
  const rows = COMPOSER_ONLY.map((key) => findSetting(document, key)).filter(Boolean);
  if (!rows.length) return null;
  return h(
    "div",
    { class: "driver-composer", dataset: { key: "driver-composer" } },
    h("h4", { class: "backup-heading" }, t("driverSettings.composerTitle")),
    h(
      "dl",
      { class: "facts" },
      rows.map((setting) =>
        h(
          "div",
          { class: "fact", dataset: { key: `driver-composer:${setting.key}` } },
          h("dt", {}, t(`driverSettings.names.${setting.key}`)),
          h("dd", {}, h("span", { class: "driver-value" }, valueText(setting)), h("span", { class: "driver-where" }, t("driverSettings.setInComposer", { property: setting.property })))
        )
      )
    ),
    h("p", { class: "field-help" }, t("driverSettings.actionsComposer"))
  );
}

// The statuses as Composer shows them (English: DirectorLink writes them for the installer).
function statusRows(document) {
  const status = document.status || {};
  const rows = STATUSES.filter((key) => typeof status[key] === "string" && status[key] !== "");
  if (!rows.length) return null;
  return h(
    "div",
    { class: "driver-status", dataset: { key: "driver-status" } },
    h("h4", { class: "backup-heading" }, t("driverSettings.statusTitle")),
    h("p", { class: "field-help" }, t("driverSettings.statusHelp")),
    h(
      "dl",
      { class: "facts" },
      rows.map((key) => h("div", { class: "fact", dataset: { key: `driver-status:${key}` } }, h("dt", {}, t(`driverSettings.status.${key}`)), h("dd", { lang: "en", dir: "auto" }, status[key])))
    )
  );
}

// "[on] Sun-Thu 06:45 -> Good morning · only if not raining · next today 06:45": the first part,
// then the rest in smaller type.
function printoutItem(item) {
  const [head, ...rest] = item.text.split(" · ");
  return h(
    "li",
    {},
    h("span", { class: "printout-head" }, head),
    rest.length ? h("span", { class: "printout-more" }, rest.join(" · ")) : null,
    item.steps.length ? h("ul", { class: "printout-steps" }, item.steps.map((step) => h("li", {}, step))) : null
  );
}

function printoutPanel(current) {
  const printout = current.printout;
  let content;
  if (printout.loading) {
    content = h("p", { class: "field-help", role: "status" }, t("common.loading"));
  } else if (printout.error) {
    content = h("p", { class: "notice notice-error", role: "alert" }, printout.error);
  } else {
    content = h(
      "div",
      { class: "printout", lang: "en", dir: "ltr", dataset: { key: "driver-printout-text" } },
      printoutGroups(printout.lines).map((group) =>
        h("section", { class: "printout-group" }, h("p", { class: "printout-title" }, group.title), group.items.length ? h("ul", { class: "printout-items" }, group.items.map(printoutItem)) : null)
      )
    );
  }
  const printedAt = printout.printedAt && Number.isFinite(Date.parse(printout.printedAt)) ? formatDateTime(new Date(printout.printedAt)) : null;
  return h(
    "div",
    { class: "driver-printout", dataset: { key: "driver-printout" } },
    h("h4", { class: "backup-heading" }, t("driverSettings.printout.title")),
    h("p", { class: "field-help" }, t("driverSettings.printout.help"), printedAt ? ` ${t("driverSettings.printout.printedAt", { time: printedAt })}` : ""),
    content,
    h(
      "div",
      { class: "button-row" },
      h("button", { type: "button", class: "button button-quiet", dataset: { key: "driver-printout-close" }, onclick: closePrintout }, t("driverSettings.printout.close"))
    )
  );
}

function shell(...content) {
  return h("div", { class: "driver-settings", id: "settings-driver" }, h("h3", { class: "settings-subtitle" }, t("driverSettings.title")), ...content);
}

// The panel in the Controller card: for admins, once connected, with a DirectorLink that has it.
export function driverSettingsPanel() {
  if (!state.loaded || !can("admin")) return null;
  const current = driverSettings();
  keepDriverSettings();
  if (current.unsupported) return null;
  const document = current.document;
  if (!document) {
    // Nothing until the first answer: an older DirectorLink shows no section at all.
    if (!current.error) return null;
    return shell(
      h("p", { class: "notice notice-error", role: "alert", dataset: { key: "driver-settings-error" } }, current.error),
      h("div", { class: "button-row" }, h("button", { type: "button", class: "button button-secondary", dataset: { key: "driver-settings-retry" }, onclick: () => loadDriverSettings() }, icon("refresh"), t("common.retry")))
    );
  }
  const message = current.message;
  return shell(
    h("p", { class: "field-help" }, t("driverSettings.intro")),
    switchRow(current, findSetting(document, "jewish_calendar"), "jewishCalendar", "on", "off"),
    switchRow(current, findSetting(document, "schedules"), "schedules", "on", "paused"),
    levelRow(current, findSetting(document, "log_level")),
    refreshRow(current),
    message
      ? h("p", { class: `notice notice-${message.kind}`, role: message.kind === "error" ? "alert" : "status", dataset: { key: "driver-settings-message" } }, message.text)
      : null,
    composerRows(document),
    statusRows(document),
    current.printout
      ? printoutPanel(current)
      : h(
          "div",
          { class: "button-row" },
          h("button", { type: "button", class: "button button-secondary", dataset: { key: "driver-printout-open" }, onclick: () => openPrintout() }, icon("clock"), t("driverSettings.printout.open"))
        )
  );
}
