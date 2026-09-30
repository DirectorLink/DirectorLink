// DirectorLink app: hash router, renderer and start-up. Screens live in js/views/.
//
// API calls made by the modules (see api/openapi.yaml): "/v1/system", "/v1/rooms", "/v1/devices",
// "/v1/lights", "/v1/thermostats", "/v1/fans", "/v1/blinds", "/v1/cameras", "/v1/relays", "/v1/scenes", "/v1/schedules",
// "/v1/weather", "/v1/calendar", "/v1/alarm" (read-only), "/v1/auth/pair" —
// device changes use method: "PATCH" and are confirmed by re-reading.

import { startAccount } from "./js/account.js";
import { alarmSignature, startAlarm } from "./js/alarm.js";
import { keepCalendar, loadCalendar } from "./js/calendar.js";
import { attachCameraImages, closeFullView, openFullView } from "./js/camera-feed.js";
import { ringNotice } from "./js/components.js";
import { h, iconButton } from "./js/dom.js";
import { notificationSupport, notificationsOn, ringingDoorbells } from "./js/doorbells.js";
import { currentLanguage, setLanguage, t } from "./js/i18n.js";
import { icon } from "./js/icons.js";
import { startPwa } from "./js/pwa.js";
import { joinView, storeInvitation } from "./js/views/join.js";
import { accessView, resetAccess } from "./js/views/access.js";
import { savedRemote } from "./js/remote.js";
import { connect, reachable, restoreSaved, whenConnected } from "./js/session.js";
import { saveProfilePrefs, syncProfile } from "./js/profile.js";
import { loadScenes } from "./js/scenes.js";
import { loadSchedules } from "./js/schedules.js";
import { state, subscribe, ui } from "./js/state.js";
import { applyTheme, palettePreference, setPalette, setTheme, themePreference, watchSystemTheme } from "./js/theme.js";
import { camerasView } from "./js/views/cameras.js";
import { climateView } from "./js/views/climate.js";
import { favoritesPicker, homeView } from "./js/views/home.js";
import { roomView } from "./js/views/room.js";
import { resetSceneEditor, sceneEditorView, scenesView } from "./js/views/scenes.js";
import { enterSchedules, keepWeatherFresh, resetScheduleEditor, scheduleEditorView, schedulesView } from "./js/views/schedules.js";
import { resetCalendarSettings, settingsView } from "./js/views/settings.js";
import { checkUpdates, updatesSignature } from "./js/views/updates.js";

const view = document.querySelector("#view");
const tabbar = document.querySelector("#tabbar");
const TABS = [
  { name: "home", href: "#/", icon: "home" },
  { name: "scenes", href: "#/scenes", icon: "scene" },
  { name: "cameras", href: "#/cameras", icon: "camera" },
  { name: "climate", href: "#/climate", icon: "climate" },
  { name: "settings", href: "#/settings", icon: "settings" },
];

// ---- routing -------------------------------------------------------------------------------

function parseRoute() {
  const parts = (window.location.hash.replace(/^#/, "") || "/").split("/").filter(Boolean);
  // An invitation link: keep its secret for this tab and take it out of the address at once.
  if (parts[0] === "join") {
    if (parts[1]) {
      storeInvitation(parts[1]);
      window.history.replaceState(window.history.state, "", `${window.location.pathname}${window.location.search}#/join`);
    }
    return { name: "join", tab: "settings" };
  }
  if (parts[0] === "room" && /^\d+$/.test(parts[1] || "")) {
    return { name: "room", id: Number(parts[1]), tab: "home" };
  }
  if (parts[0] === "scene" && /^(new|[0-9a-f]{8})$/.test(parts[1] || "")) {
    return { name: "scene", id: parts[1], adding: parts[2] === "add", tab: "scenes" };
  }
  if (parts[0] === "schedule" && /^(new|[0-9a-f]{8})$/.test(parts[1] || "")) {
    return { name: "schedule", id: parts[1], tab: "scenes" };
  }
  if (parts[0] === "schedules") {
    return { name: "schedules", tab: "scenes" };
  }
  if (["scenes", "cameras", "climate", "settings"].includes(parts[0])) {
    return { name: parts[0], tab: parts[0] };
  }
  if (parts[0] === "access") {
    return { name: "access", tab: "settings" };
  }
  return { name: "home", tab: "home" };
}

let route = parseRoute();

export function navigate(hash) {
  if (window.location.hash === hash || (hash === "#/" && !window.location.hash)) {
    render(true);
  } else {
    window.location.hash = hash;
  }
}

window.addEventListener("hashchange", () => {
  // Entries reached inside the app: the Back button can use history.back().
  window.history.replaceState({ directorlinkInApp: true }, "");
  const previous = route;
  route = parseRoute();
  ui.cameFrom = previous.name;
  // People and devices loads fresh each time it is opened; a scene opens as it was saved.
  if (route.name === "access" && previous.name !== "access") resetAccess();
  if (route.name === "scene" && (previous.name !== "scene" || previous.id !== route.id)) resetSceneEditor();
  if (route.name === "schedule" && (previous.name !== "schedule" || previous.id !== route.id)) resetScheduleEditor();
  if (route.name === "settings" && previous.name !== "settings") resetCalendarSettings();
  // The weather is read while Schedules is open.
  if ((route.name === "schedules" || route.name === "schedule") && previous.name !== "schedules" && previous.name !== "schedule") enterSchedules();
  // The Hebrew date on Home (Schedules reads the calendar too).
  if (route.name === "home" && previous.name !== "home") loadCalendar();
  closeFullView();
  render(true);
  window.scrollTo(0, 0);
  // Move focus to the new screen's heading for keyboard and screen-reader users.
  view.querySelector(".page-title")?.focus({ preventScroll: true });
});

// ---- dialogs -------------------------------------------------------------------------------

const cameraDialog = h("dialog", { id: "camera-dialog", class: "dialog camera-dialog", "aria-labelledby": "camera-dialog-title" });
const pickerDialog = h("dialog", { id: "favorites-dialog", class: "dialog picker-dialog", "aria-labelledby": "favorites-dialog-title" });
let cameraParts = null;
let pickerBody = null;

function buildDialogs() {
  const title = h("h2", { id: "camera-dialog-title", class: "dialog-title", dir: "auto" });
  const image = h("img", { id: "camera-dialog-image", alt: "" });
  const status = h("p", { id: "camera-dialog-status", class: "dialog-status", role: "status" });
  cameraParts = { titleElement: title, image, status };
  cameraDialog.replaceChildren(
    h("div", { class: "dialog-head" }, title, iconButton("close", t("common.close"), { onclick: closeFullView })),
    h(
      "div",
      { class: "cam cam-full", dataset: { state: "loading" } },
      image,
      h("span", { class: "cam-placeholder cam-loading", "aria-hidden": "true" }),
      h("span", { class: "cam-placeholder cam-none" }, icon("noPicture"), h("span", {}, t("cameras.noPicture"))),
      h("span", { class: "cam-placeholder cam-busy" }, icon("refresh"), h("span", {}, t("cameras.busy")))
    ),
    status
  );

  pickerBody = h("div", { class: "picker" });
  pickerDialog.replaceChildren(
    h(
      "div",
      { class: "dialog-head" },
      h("h2", { id: "favorites-dialog-title", class: "dialog-title" }, t("favorites.pickerTitle")),
      iconButton("close", t("common.close"), { onclick: () => pickerDialog.close() })
    ),
    h("p", { class: "field-help" }, t("favorites.pickerHelp")),
    pickerBody,
    h("div", { class: "dialog-foot" }, h("button", { type: "button", class: "button button-primary button-wide", onclick: () => pickerDialog.close() }, t("common.done")))
  );
}

cameraDialog.addEventListener("close", closeFullView);
// A tap on the backdrop closes a dialog.
for (const dialog of [cameraDialog, pickerDialog]) {
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) dialog.close();
  });
}
pickerDialog.addEventListener("close", () => render(true));
document.body.append(cameraDialog, pickerDialog);

function openCamera(camera) {
  openFullView(cameraDialog, camera, cameraParts);
}

function openFavoritesPicker() {
  pickerBody.replaceChildren(...favoritesPicker());
  pickerDialog.showModal();
}

// ---- rendering -----------------------------------------------------------------------------

let lastSignature = "";

// Everything a screen shows. Unchanged data means no redraw, so polling every 10 s does not
// disturb focus, screen readers or text being typed.
function signature() {
  return JSON.stringify([
    route,
    currentLanguage(),
    palettePreference(),
    themePreference(),
    state.status,
    state.notice,
    state.loaded,
    state.system,
    // A newer DirectorLink release, and the one dismissed on Home (kept in localStorage).
    updatesSignature(),
    state.rooms,
    state.lights,
    state.thermostats,
    state.fans,
    state.blinds,
    state.cameras,
    state.relays,
    state.doorbells,
    // The alarm (read-only), and the seconds an entry or exit delay has left.
    alarmSignature(),
    // Rings stop being recent, and "3 minutes ago" moves on, without new data.
    ringingDoorbells().map((doorbell) => doorbell.id),
    state.doorbells.length ? Math.floor(Date.now() / 60000) : 0,
    state.role,
    state.account,
    // Remote access (remote.js): the connection in use, the controller's answer, and whether this
    // device is linked (kept in localStorage, so it is read here).
    state.transport,
    state.remoteInfo,
    savedRemote(),
    state.devices,
    state.sentBrightness,
    Object.fromEntries(Object.entries(state.errors).map(([key, value]) => [key, value.text])),
    state.online,
    state.canInstall,
    state.offlineCopy,
    ui.filter,
    ui.find,
    ui.editFavorites,
    ui.relayStage,
    ui.doorbellStage,
    ui.tick,
    ui.roomMessages,
    ui.controllerMessage,
    ui.featuredCamera,
    ui.homeBusy,
    ui.homeMessage,
    ui.homeInvitation,
    ui.inviteForm,
    ui.joinBusy,
    ui.joinMessage,
    state.profile,
    ui.roomOrderMessage,
    state.scenes,
    state.scenesUnsupported,
    ui.sceneRuns,
    ui.scenesMessage,
    state.schedules,
    state.schedulesPaused,
    state.schedulesUnsupported,
    state.weather,
    state.calendar,
    ui.schedulesMessage,
    // Times being typed are left out: the editor does not rebuild a time field while it is used.
    route.name === "schedule" ? { ...ui.scheduleEditor, at: undefined, from: undefined, to: undefined } : 0,
    // "Ran today", "next: tomorrow" move on with the day.
    route.name === "schedules" ? Math.floor(Date.now() / 60000) : 0,
    // The scene's name is typed into a field: it is left out, so typing is never redrawn.
    route.name === "scene" ? { ...ui.sceneEditor, name: undefined } : 0,
    route.name === "access" ? ui.access : 0,
    route.name === "settings" ? ui.calendarSettings : 0,
    route.name === "settings" ? state.lastUpdated?.getTime() : 0,
    route.name === "settings" ? [notificationSupport(), notificationsOn()] : 0,
  ]);
}

function screen() {
  const actions = { openCamera, openFavoritesPicker, navigate };
  switch (route.name) {
    case "room":
      return roomView(route.id, actions);
    case "scenes":
      return scenesView(actions);
    case "schedules":
      return schedulesView(actions);
    case "schedule":
      return scheduleEditorView(route.id, actions);
    case "scene":
      return sceneEditorView(route.id, route.adding, actions);
    case "cameras":
      return camerasView(actions);
    case "climate":
      return climateView(actions);
    case "join":
      return joinView(actions);
    case "access":
      return accessView(actions);
    case "settings":
      return settingsView({
        navigate,
        onPalette: (palette) => {
          setPalette(palette);
          saveProfilePrefs({ palette });
          render(true);
        },
        onTheme: (theme) => {
          setTheme(theme);
          saveProfilePrefs({ theme });
          render(true);
        },
        onLanguage: async (language) => {
          await setLanguage(language);
          saveProfilePrefs({ language });
          applyLanguage();
        },
      });
    default:
      return homeView(actions);
  }
}

// Keeps focus, the caret and open <details> across a redraw (elements carry data-key).
function captureUi() {
  const active = document.activeElement;
  const key = view.contains(active) ? active?.dataset?.key : null;
  let selection = null;
  if (key && typeof active.selectionStart === "number") {
    try {
      selection = [active.selectionStart, active.selectionEnd];
    } catch {
      selection = null;
    }
  }
  const open = new Set([...view.querySelectorAll("details[data-key]")].filter((item) => item.open).map((item) => item.dataset.key));
  return { key, selection, open };
}

function restoreUi({ key, selection, open }) {
  for (const details of view.querySelectorAll("details[data-key]")) {
    if (open.has(details.dataset.key)) details.open = true;
  }
  if (!key) return;
  const target = [...view.querySelectorAll("[data-key]")].find((item) => item.dataset.key === key);
  if (target && !target.disabled) {
    target.focus({ preventScroll: true });
    if (selection && typeof target.setSelectionRange === "function") {
      try {
        target.setSelectionRange(selection[0], selection[1]);
      } catch {
        // Not a text field.
      }
    }
  }
}

function render(force = false) {
  if (ui.dragging || ui.reordering) return; // redrawn when the slider or the room is let go
  const current = signature();
  if (!force && current === lastSignature) return;
  lastSignature = current;

  const saved = captureUi();
  const content = [screen()].flat(Infinity).filter(Boolean);
  // Away from Home, a ring still shows: one line under the header that leads to the banner.
  if (route.name !== "home" && state.apiKey) {
    const notice = ringNotice(ringingDoorbells());
    if (notice) content.splice(1, 0, notice);
  }
  view.replaceChildren(...content);
  restoreUi(saved);
  attachCameraImages(view);
  updateTabbar();
  if (pickerDialog.open) {
    pickerBody.replaceChildren(...favoritesPicker());
  }
  document.title = route.name === "home" ? "DirectorLink" : `${view.querySelector(".page-title")?.textContent || ""} · DirectorLink`;
}

function updateTabbar() {
  for (const link of tabbar.querySelectorAll("a[data-tab]")) {
    if (link.dataset.tab === route.tab) link.setAttribute("aria-current", "page");
    else link.removeAttribute("aria-current");
  }
}

function buildTabbar() {
  tabbar.setAttribute("aria-label", t("nav.label"));
  tabbar.replaceChildren(
    h("span", { class: "rail-brand", "aria-hidden": "true" }, h("img", { src: "/icons/icon.svg", alt: "", width: "36", height: "36" })),
    ...TABS.map((tab) =>
      h("a", { href: tab.href, class: "tab", dataset: { tab: tab.name } }, icon(tab.icon), h("span", { class: "tab-label" }, t(`nav.${tab.name}`)))
    )
  );
  updateTabbar();
}

function applyLanguage() {
  document.querySelector(".skip-link").textContent = t("nav.skip");
  buildTabbar();
  buildDialogs();
  render(true);
}

// ---- start ---------------------------------------------------------------------------------

subscribe(() => render());
// The person's profile: language, theme and palette from their other devices apply here too.
whenConnected(() => syncProfile(applyLanguage));
// The home's scenes, for the Scenes tab and the ones shown on Home.
whenConnected(loadScenes);
whenConnected(loadSchedules);
// Members and admins: the alarm, read-only, when the installer turned it on; then every 10 s.
whenConnected(startAlarm);
// The Jewish calendar, while it is on in Composer: read now, then every 10 minutes (js/calendar.js).
whenConnected(keepCalendar);
// Admins: whether a newer DirectorLink is out (GitHub, at most every 12 hours; js/updates.js).
whenConnected(checkUpdates);
// Opened on Schedules (a reload): the weather once connected.
whenConnected(() => {
  if (route.name === "schedules" || route.name === "schedule") keepWeatherFresh();
});
watchSystemTheme(() => render(true));
window.addEventListener("pointerup", () => window.setTimeout(() => render(), 0));

async function start() {
  applyTheme();
  await setLanguage();
  restoreSaved();
  applyLanguage();
  startPwa();
  startAccount();
  // The host and API key are kept in this browser, so a reload reconnects without pairing again.
  if (reachable()) {
    connect();
  }
}

start();
