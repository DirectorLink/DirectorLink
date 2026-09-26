// C4Bridge web app: hash router, renderer and start-up. Screens live in js/views/.
//
// API calls made by the modules (see api/openapi.yaml): "/v1/system", "/v1/rooms", "/v1/devices",
// "/v1/lights", "/v1/thermostats", "/v1/blinds", "/v1/cameras", "/v1/relays", "/v1/auth/requests",
// "/v1/auth/pair" — device changes use method: "PATCH" and are confirmed by re-reading.

import { attachCameraImages, closeFullView, openFullView } from "./js/camera-feed.js";
import { h, iconButton } from "./js/dom.js";
import { currentLanguage, setLanguage, t } from "./js/i18n.js";
import { icon } from "./js/icons.js";
import { startPwa } from "./js/pwa.js";
import { connect, restoreSaved } from "./js/session.js";
import { state, subscribe, ui } from "./js/state.js";
import { applyTheme, palettePreference, setPalette, setTheme, themePreference, watchSystemTheme } from "./js/theme.js";
import { camerasView } from "./js/views/cameras.js";
import { climateView } from "./js/views/climate.js";
import { favoritesPicker, homeView } from "./js/views/home.js";
import { roomView } from "./js/views/room.js";
import { settingsView } from "./js/views/settings.js";

const view = document.querySelector("#view");
const tabbar = document.querySelector("#tabbar");
const TABS = [
  { name: "home", href: "#/", icon: "home" },
  { name: "cameras", href: "#/cameras", icon: "camera" },
  { name: "climate", href: "#/climate", icon: "climate" },
  { name: "settings", href: "#/settings", icon: "settings" },
];

// ---- routing -------------------------------------------------------------------------------

function parseRoute() {
  const parts = (window.location.hash.replace(/^#/, "") || "/").split("/").filter(Boolean);
  if (parts[0] === "room" && /^\d+$/.test(parts[1] || "")) {
    return { name: "room", id: Number(parts[1]), tab: "home" };
  }
  if (["cameras", "climate", "settings"].includes(parts[0])) {
    return { name: parts[0], tab: parts[0] };
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
  window.history.replaceState({ c4bridgeInApp: true }, "");
  route = parseRoute();
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
    state.access?.expiresAt,
    state.loaded,
    state.system,
    state.rooms,
    state.lights,
    state.thermostats,
    state.blinds,
    state.cameras,
    state.relays,
    state.role,
    state.devices,
    state.sentBrightness,
    Object.fromEntries(Object.entries(state.errors).map(([key, value]) => [key, value.text])),
    state.online,
    state.canInstall,
    state.offlineCopy,
    ui.filter,
    ui.editFavorites,
    ui.relayStage,
    ui.tick,
    ui.roomMessages,
    ui.controllerMessage,
    ui.featuredCamera,
    route.name === "settings" ? state.lastUpdated?.getTime() : 0,
  ]);
}

function screen() {
  const actions = { openCamera, openFavoritesPicker, navigate };
  switch (route.name) {
    case "room":
      return roomView(route.id, actions);
    case "cameras":
      return camerasView(actions);
    case "climate":
      return climateView(actions);
    case "settings":
      return settingsView({
        navigate,
        onPalette: (palette) => {
          setPalette(palette);
          render(true);
        },
        onTheme: (theme) => {
          setTheme(theme);
          render(true);
        },
        onLanguage: async (language) => {
          await setLanguage(language);
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
  if (ui.dragging) return; // redrawn when the slider is let go
  const current = signature();
  if (!force && current === lastSignature) return;
  lastSignature = current;

  const saved = captureUi();
  view.replaceChildren(...[screen()].flat(Infinity).filter(Boolean));
  restoreUi(saved);
  attachCameraImages(view);
  updateTabbar();
  if (pickerDialog.open) {
    pickerBody.replaceChildren(...favoritesPicker());
  }
  document.title = route.name === "home" ? "C4Bridge" : `${view.querySelector(".page-title")?.textContent || ""} · C4Bridge`;
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

// Countdown while waiting for C4Bridge Access to be pressed.
window.setInterval(() => {
  if (state.status === "waiting" && state.access) {
    ui.tick += 1;
    render();
  }
}, 1000);

subscribe(() => render());
watchSystemTheme(() => render(true));
window.addEventListener("pointerup", () => window.setTimeout(() => render(), 0));

async function start() {
  applyTheme();
  await setLanguage();
  restoreSaved();
  applyLanguage();
  startPwa();
  // The host and API key are kept in this browser, so a reload reconnects without pairing again.
  if (state.host && state.apiKey) {
    connect();
  }
}

start();
