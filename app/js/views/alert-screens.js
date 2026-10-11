// Settings → Alerts → On TVs (1.13.0, ADR-086): the home's screens of DirectorLink's notification
// agreement (docs/NOTIFY_DRIVERS.md), which show its alerts as pop-ups. Each with its room and what
// it shows, then the language the pop-ups are in (the one the home's owner sees in the app: their
// choice, or with Auto what their app shows). Read only: the installer adds a
// screen and chooses what it shows in Composer, in the screen's own driver. For admins, with a
// controller that has them (`features.alert_screens`); nothing when the home has none, for members
// (a screen shows the home's alerts whatever a member may see), or before connecting.
//
// GET /v1/alerts/screens (admins): { items: [{ id, name, room_id, room, kinds }], language }; read
// when the page is drawn, and again when it is drawn a minute later.

import { h } from "../dom.js";
import { LANGUAGES, t } from "../i18n.js";
import { icon } from "../icons.js";
import { roomName } from "../model.js";
import { api, keyGeneration, keyInUse, whenForgotten } from "../session.js";
import { can, notify, state, ui } from "../state.js";

// The agreement's kinds, in its order.
export const SCREEN_KINDS = ["doorbell", "camera", "door", "alarm", "other"];
// What the card shows is read again when it is drawn this long after.
const FRESH_MS = 60000;

let loading = null;
whenForgotten(() => {
  loading = null;
  ui.alertScreens = null;
});

// ui.alertScreens: { list (GET /v1/alerts/screens), at, failed }.
function section() {
  ui.alertScreens ??= {};
  return ui.alertScreens;
}

export function screensSupported() {
  return state.system?.features?.alert_screens === true;
}

export function loadScreens() {
  // Nothing is asked while the key is being forgotten (Forget key, Pair again).
  if (!keyInUse()) return Promise.resolve();
  if (loading) return loading;
  const since = keyGeneration();
  const read = (async () => {
    try {
      const answer = await api("/v1/alerts/screens");
      if (since !== keyGeneration()) return;
      Object.assign(section(), { list: answer && Array.isArray(answer.items) ? answer : { items: [] }, failed: false, at: Date.now() });
    } catch {
      // Said nowhere: the card is extra, and shows what it last read (or nothing).
      if (since !== keyGeneration()) return;
      Object.assign(section(), { failed: true, at: Date.now() });
    } finally {
      if (loading === read) loading = null;
      if (since === keyGeneration()) notify();
    }
  })();
  loading = read;
  return read;
}

// "Shows: Doorbell, Cameras", in the agreement's order; "Shows nothing" for none.
export function kindsText(kinds) {
  const list = Array.isArray(kinds) ? kinds : [];
  const names = SCREEN_KINDS.filter((kind) => list.includes(kind)).map((kind) => t(`alerts.screens.kinds.${kind}`));
  return names.length ? t("alerts.screens.shows", { kinds: names.join(", ") }) : t("alerts.screens.nothing");
}

function screenRow(screen) {
  // The room by the app's own name for it (Settings → Rooms, in this language), else Composer's.
  const room = Number.isInteger(screen.room_id) ? roomName({ id: screen.room_id, name: typeof screen.room === "string" ? screen.room : "" }) : null;
  return h(
    "li",
    { class: "alert-screen", dataset: { key: `alert-screen:${screen.id}` } },
    h("span", { class: "alert-screen-name", dir: "auto" }, String(screen.name ?? "")),
    room ? h("span", { class: "field-help alert-screen-room", dir: "auto" }, room) : null,
    h("span", { class: "field-help alert-screen-kinds" }, kindsText(screen.kinds))
  );
}

// The card, for admins with a DirectorLink that has screens; null otherwise, and while the home has
// none.
export function screensCard() {
  if (!state.loaded || !state.role || !can("admin") || !screensSupported()) return null;
  const current = section();
  if (!loading && (!current.at || Date.now() - current.at > FRESH_MS)) loadScreens();
  const items = Array.isArray(current.list?.items) ? current.list.items : [];
  if (!items.length) return null;
  const language = LANGUAGES.find((item) => item.code === current.list.language)?.label || LANGUAGES[0].label;
  return h(
    "section",
    { class: "card settings-card", id: "settings-alert-screens", "aria-labelledby": "settings-alert-screens-title", dataset: { key: "alert-screens" } },
    h("h2", { class: "settings-title", id: "settings-alert-screens-title" }, icon("tv"), t("alerts.screens.title")),
    h("p", { class: "field-help" }, t("alerts.screens.help")),
    h("ul", { class: "alert-screens", dataset: { key: "alert-screens-list" } }, items.map(screenRow)),
    h("p", { class: "field-help", dataset: { key: "alert-screens-language" } }, t("alerts.screens.language", { language }))
  );
}
