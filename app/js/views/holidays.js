// Schedules → Holidays (#/schedules/holidays; admins; DirectorLink 1.14.0, ADR-090): the home's own
// holidays, days a schedule may skip or run only on (its "On your holidays"): public holidays,
// school breaks, a trip. One day or several, once or every year; whole days in the home's time zone.
// The controller keeps one list (GET and PUT /v1/holidays); each change here saves the whole list at
// once, with its version, so that two devices never overwrite each other unseen.

import { emptyState, skeletonCards } from "../components.js";
import { h, iconButton } from "../dom.js";
import { currentLanguage, t } from "../i18n.js";
import { icon } from "../icons.js";
import { loadHolidays, membersHaveNoSchedules, schedulePlanning } from "../schedules.js";
import { api, errorText, noteForbidden } from "../session.js";
import { notify, state, ui } from "../state.js";
import { isLoading, notReadyState, offlineBanner, pageHeader, staleBanner } from "./common.js";
import { toggle } from "./schedules.js";

const MAX_ITEMS = 100;
const MAX_NAME = 60;
const MESSAGE_MS = 6000;

// What is typed into the new holiday's fields: kept here, not in `ui`, so that typing never
// redraws the screen (app.js); the screen is drawn again from it after a change.
const typed = { name: "", from: "", to: "" };

export function resetHolidays() {
  typed.name = "";
  typed.from = "";
  typed.to = "";
  ui.holidays = { yearly: false, busy: false, message: null };
}

function current() {
  if (!ui.holidays) resetHolidays();
  return ui.holidays;
}

function flash(text, kind) {
  const stamp = Date.now();
  current().message = { kind, text, stamp };
  window.setTimeout(() => {
    if (ui.holidays?.message?.stamp === stamp) {
      ui.holidays.message = null;
      notify();
    }
  }, MESSAGE_MS);
}

// "25 Dec 2026", from the controller's local date (read as such: noon UTC, shown in UTC).
function dateText(date, withYear = true) {
  const moment = new Date(`${date}T12:00:00Z`);
  if (Number.isNaN(moment.getTime())) return date;
  const options = withYear ? { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" } : { day: "numeric", month: "short", timeZone: "UTC" };
  return new Intl.DateTimeFormat(currentLanguage(), options).format(moment);
}

// "25 Dec 2026", "20 Dec 2026 – 3 Jan 2027", "Every year: 22 Apr", "Every year: 24 Dec – 2 Jan".
export function holidayDates(item) {
  const yearly = item.yearly === true;
  const from = dateText(item.from, !yearly);
  const range = item.to && item.to !== item.from ? t("holidays.range", { from, to: dateText(item.to, !yearly) }) : from;
  return yearly ? t("holidays.everyYear", { dates: range }) : range;
}

// Saves `items` as the whole list. Returns true once the controller has it.
async function save(items, done) {
  const view = current();
  view.busy = true;
  view.message = null;
  notify();
  try {
    state.holidays = await api("/v1/holidays", { method: "PUT", body: { items, version: state.holidays?.version ?? 0 } });
    view.busy = false;
    flash(done, "success");
    notify();
    return true;
  } catch (error) {
    noteForbidden(error);
    view.busy = false;
    if (error?.code === "VERSION_CONFLICT") {
      flash(t("holidays.conflict"), "error");
      await loadHolidays();
    } else {
      flash(errorText(error), "error");
    }
    notify();
    return false;
  }
}

function listed(items) {
  return items.map((item) => ({ name: item.name, from: item.from, to: item.to || item.from, yearly: item.yearly === true }));
}

function refuse(text) {
  flash(text, "error");
  notify();
}

async function add() {
  const view = current();
  const name = typed.name.trim();
  const from = typed.from;
  const to = typed.to || typed.from;
  const items = listed(state.holidays?.items || []);
  if (!name) return refuse(t("holidays.needName"));
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from)) return refuse(t("holidays.needDate"));
  if (to < from) return refuse(t("holidays.order"));
  if (items.length >= MAX_ITEMS) return refuse(t("holidays.limit"));
  items.push({ name, from, to, yearly: view.yearly === true });
  if (await save(items, t("holidays.added", { name: `⁨${name}⁩` }))) {
    typed.name = "";
    typed.from = "";
    typed.to = "";
    view.yearly = false;
    notify();
  }
}

async function remove(index) {
  const items = listed(state.holidays?.items || []);
  const [gone] = items.splice(index, 1);
  if (!gone || !window.confirm(t("holidays.deleteConfirm", { name: gone.name }))) return;
  await save(items, t("holidays.deleted", { name: `⁨${gone.name}⁩` }));
}

function holidayRow(item, index, busy) {
  return h(
    "li",
    { class: "card holiday-row" },
    h("span", { class: "scene-icon", "aria-hidden": "true" }, icon("holiday")),
    h("span", { class: "scene-text" }, h("span", { class: "scene-name" }, item.name), h("span", { class: "scene-summary" }, holidayDates(item))),
    iconButton("close", t("holidays.delete", { name: item.name }), { class: "icon-button", disabled: busy, dataset: { key: `holiday-delete:${index}` }, onclick: () => remove(index) })
  );
}

function dateField(key, label, value, onInput, help) {
  return h(
    "label",
    { class: "field" },
    h("span", { class: "field-label" }, label),
    h("input", { type: "date", class: "time-input", value, dataset: { key }, oninput: (event) => onInput(event.target.value) }),
    help ? h("span", { class: "field-help" }, help) : null
  );
}

function addCard(view, full) {
  return h(
    "section",
    { class: "card scene-section holiday-add" },
    h("h2", { class: "add-title" }, t("holidays.addTitle")),
    h(
      "label",
      { class: "field" },
      h("span", { class: "field-label" }, t("holidays.name")),
      h("input", {
        type: "text",
        maxlength: String(MAX_NAME),
        value: typed.name,
        dir: "auto",
        autocomplete: "off",
        placeholder: t("holidays.namePlaceholder"),
        dataset: { key: "holiday-name" },
        oninput: (event) => {
          typed.name = event.target.value;
        },
      })
    ),
    dateField("holiday-from", t("holidays.from"), typed.from, (value) => { typed.from = value; }),
    dateField("holiday-to", t("holidays.to"), typed.to, (value) => { typed.to = value; }, t("holidays.toHelp")),
    toggle(t("holidays.yearly"), view.yearly === true, "holiday-yearly", (on) => {
      view.yearly = on;
      notify();
    }),
    h(
      "div",
      { class: "scene-actions" },
      h("button", { type: "button", class: "button button-primary", disabled: view.busy || full, dataset: { key: "holiday-add" }, onclick: add }, icon("plus"), view.busy ? t("common.saving") : t("holidays.add"))
    ),
    full ? h("p", { class: "notice notice-info" }, t("holidays.limit")) : null
  );
}

export function holidaysView() {
  const header = pageHeader({ title: t("holidays.title"), back: "#/schedules" });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (membersHaveNoSchedules()) return [header, emptyState("holiday", t("holidays.title"), t("schedules.adminsOnly"))];
  if (state.system && !schedulePlanning()) return [header, emptyState("holiday", t("holidays.title"), t("schedules.week.updateDriver"))];
  const holidays = state.holidays;
  if (!holidays) {
    if (state.holidaysError && !isLoading()) {
      return [
        header,
        emptyState(
          "wifiOff",
          t("holidays.loadFailed"),
          state.holidaysError,
          h("button", { type: "button", class: "button button-primary", dataset: { key: "holidays-retry" }, onclick: () => loadHolidays() }, icon("refresh"), t("common.retry"))
        ),
      ];
    }
    return [header, h("div", { class: "scene-list", "aria-busy": "true" }, skeletonCards(2)), h("p", { class: "visually-hidden", role: "status" }, t("common.loading"))];
  }
  const view = current();
  const items = Array.isArray(holidays.items) ? holidays.items : [];
  const message = view.message;
  return [
    header,
    offlineBanner(),
    staleBanner(),
    message ? h("p", { class: `notice notice-${message.kind}`, role: message.kind === "error" ? "alert" : "status" }, message.text) : null,
    h("p", { class: "muted-note scene-intro" }, t("holidays.help")),
    items.length
      ? h("ul", { class: "scene-list holiday-list" }, items.map((item, index) => holidayRow(item, index, view.busy)))
      : emptyState("holiday", t("holidays.emptyTitle"), t("holidays.emptyText")),
    addCard(view, items.length >= MAX_ITEMS),
  ];
}
