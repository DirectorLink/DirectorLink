// Settings → Alerts (#/settings/alerts, 1.10.0; on Settings → Controller before): "Alerts on this
// device" (ADR-047, ADR-050, js/alerts.js), for anyone signed in to an account with DirectorLink 1.7.0
// on the controller (admins only before), on a device linked to the home; signed out, the page offers
// to sign in (and Off, while this device still gets them), after saying why this browser cannot have
// them, if it cannot. Once on, a switch per kind this key may get: the controller says which (its role, and
// what the home has); admins also choose the servers' offline alert, and (1.8.0) their push when a
// new device of their account asks to join, so the device that approves need not be open. On iPhone
// and iPad they work only in the app added to the Home Screen (iOS 16.4 or later): the card says so
// there. Settings' list has a row for the page, with a line saying how alerts are on this device.

import {
  ALERT_KINDS,
  alertsAllowed,
  alertsForKey,
  alertsOn,
  alertsSupport,
  alertsUi,
  chooseAlert,
  controllerChooses,
  deviceRequestAlertsOn,
  offlineAlertsOn,
  turnAlertsOff,
  turnAlertsOn,
} from "../alerts.js";
import { loadAccount } from "../account.js";
import { h } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { savedRemote } from "../remote.js";
import { can, state } from "../state.js";
import { notReadyState, signInButtons } from "./common.js";

// Why the switch cannot be used on this device (the key of its text: alerts.settings.<key>, and
// settings.rows.alerts.<key> on Settings' list), or null.
function obstacle(support, linked) {
  if (!linked) return "notLinked";
  switch (support) {
    case "homeScreen":
      return "homeScreen";
    case "iosVersion":
      return "iosVersion";
    case "denied":
      return "blocked";
    case "unsupported":
      return "unsupported";
    default:
      return null;
  }
}

// One kind's switch; busy while its change is saved. `help`: a line under its name.
function kindRow(kind, on, help = null) {
  const busy = alertsUi.saving === kind;
  const label = `alerts-kind-${kind}`;
  return h(
    "div",
    { class: "toggle-row alerts-toggle" },
    h(
      "span",
      { class: "toggle-text" },
      h("span", { id: label }, t(`alerts.settings.kinds.${kind}`)),
      help ? h("span", { class: "field-help", id: `${label}-help` }, help) : null
    ),
    h(
      "button",
      {
        type: "button",
        role: "switch",
        class: "switch",
        "aria-checked": String(on),
        "aria-labelledby": label,
        "aria-describedby": help ? `${label}-help` : null,
        "aria-busy": busy ? "true" : null,
        "aria-disabled": alertsUi.saving ? "true" : null,
        dataset: { key: `alerts-kind:${kind}` },
        onclick: () => {
          if (!alertsUi.saving) chooseAlert(kind, !on);
        },
      },
      h("span", { class: "switch-thumb" })
    )
  );
}

// The kinds this device may choose, each { kind, on }: the servers' own for admins (the home
// offline, a new device of theirs asking to join), then the controller's.
function offeredKinds() {
  const offered = [];
  if (can("admin")) offered.push({ kind: "offline", on: offlineAlertsOn() });
  // A new device of their own account asking to join: since 1.9.0 every user approves it (ADR-061).
  if (can("admin") || state.system?.features?.users === true) offered.push({ kind: "device_requests", on: deviceRequestAlertsOn() });
  const kinds = alertsUi.choices?.kinds || {};
  for (const kind of ALERT_KINDS) {
    // Camera alerts only with a controller that has them (DirectorLink 1.8.0 and a camera on the
    // DirectorLink · Hikvision Camera driver, ADR-056; since 1.10.0 any driver of DirectorLink's
    // camera agreement, ADR-065).
    if (kind === "camera" && state.system?.features?.camera_alerts !== true) continue;
    if (typeof kinds[kind] === "boolean") offered.push({ kind, on: kinds[kind] });
  }
  return offered;
}

function kindsList() {
  const rows = offeredKinds().map(({ kind, on }) => kindRow(kind, on, kind === "camera" ? t("alerts.settings.cameraHelp") : null));
  if (!rows.length) return null;
  return h(
    "div",
    { class: "alerts-kinds", role: "group", "aria-labelledby": "alerts-kinds-title", dataset: { key: "alerts-kinds" } },
    h("h3", { class: "settings-subtitle", id: "alerts-kinds-title" }, t("alerts.settings.kindsTitle")),
    rows
  );
}

// The page's one card: its title says that what it holds is this device's.
function alertsCard(...content) {
  return h(
    "section",
    { class: "card settings-card", id: "settings-alerts", "aria-labelledby": "settings-alerts-title" },
    h("h2", { class: "settings-title", id: "settings-alerts-title" }, icon("bell"), t("alerts.settings.cardTitle")),
    ...content
  );
}

// What a sign-in begun on this page came back with, when it did not work (Settings → Account says
// the rest of the account's notices).
const SIGN_IN_NOTICES = ["cancelled", "expired", "failed", "unverified"];

// "Alerts on this device" and its switch: `on`; `off`: it cannot be used now; `hinted`: a notice
// (#alerts-hint) says why, or how things are.
function mainSwitch(on, off, hinted) {
  return h(
    "div",
    { class: "toggle-row alerts-toggle" },
    h(
      "span",
      { class: "toggle-text" },
      h("span", { class: "toggle-title", id: "alerts-switch-label" }, t("alerts.settings.label")),
      h("span", { class: "field-help", id: "alerts-switch-help" }, t(controllerChooses() ? "alerts.settings.help" : "alerts.settings.helpAdmins"))
    ),
    h(
      "button",
      {
        type: "button",
        role: "switch",
        class: "switch",
        "aria-checked": String(on),
        "aria-labelledby": "alerts-switch-label",
        "aria-describedby": hinted ? "alerts-switch-help alerts-hint" : "alerts-switch-help",
        "aria-busy": alertsUi.busy ? "true" : null,
        "aria-disabled": off ? "true" : null,
        dataset: { key: "alerts-switch" },
        onclick: () => {
          if (off) return;
          if (on) turnAlertsOff();
          else turnAlertsOn();
        },
      },
      h("span", { class: "switch-thumb" })
    )
  );
}

// What the last tap led to (alerts.settings.<key>), unless `shown` says it already.
function lastMessage(shown = null) {
  const message = alertsUi.message ? t(`alerts.settings.${alertsUi.message.key}`) : null;
  return message && message !== shown ? h("p", { class: `notice notice-${alertsUi.message.kind}`, role: "status", dataset: { key: "alerts-message" } }, message) : null;
}

// Signed out, or the account service out of reach (1.10.0). Alerts that are on keep coming (a
// session that ended, a cookie cleared: the browser keeps its subscription): the switch says so and
// turns them off, which needs no account (js/alerts.js turnAlertsOff). A browser that cannot have
// them says why before anything else: signing in would not help (on iPhone and iPad the Home Screen
// app keeps its own sign-in). Else alerts come through the account: the page offers to sign in, and
// comes back here.
function signedOutCard() {
  const account = state.account;
  const loading = account.status === "unknown" || account.status === "loading";
  const unavailable = account.status === "unavailable";
  const on = alertsOn();
  const reason = on ? null : obstacle(alertsSupport(), true);
  if (reason && reason !== "blocked") {
    return alertsCard(h("p", { class: "notice notice-info", id: "alerts-hint", dataset: { key: "alerts-hint" } }, t(`alerts.settings.${reason}`)));
  }
  if (loading && !on) return alertsCard(h("p", { class: "field-help", role: "status" }, t("common.loading")));
  const hint = on ? (loading || unavailable ? null : t("alerts.settings.onSignedOut")) : reason ? t(`alerts.settings.${reason}`) : null;
  return alertsCard(
    on ? mainSwitch(true, alertsUi.busy, Boolean(hint)) : null,
    hint ? h("p", { class: "notice notice-info", id: "alerts-hint", dataset: { key: "alerts-hint" } }, hint) : null,
    lastMessage(hint),
    on ? null : h("p", { class: "field-help" }, t("alerts.settings.signInHelp")),
    SIGN_IN_NOTICES.includes(account.notice) ? h("p", { class: "notice notice-error", role: "status" }, t(`settings.account.notice.${account.notice}`)) : null,
    unavailable ? h("p", { class: "notice notice-error", role: "status" }, t("settings.account.unavailable")) : null,
    loading
      ? null
      : h(
          "div",
          { class: "button-row" },
          h("div", { class: "sign-in-buttons" }, signInButtons({ hash: "#/settings/alerts", key: "alerts-sign-in" })),
          unavailable ? h("button", { type: "button", class: "button button-secondary", dataset: { key: "alerts-account-retry" }, onclick: loadAccount }, icon("refresh"), t("common.retry")) : null
        )
  );
}

// Settings → Alerts (1.10.0): the switch and its kinds; signed out, the sign-in (and the switch's
// Off while alerts are still on); before connecting, what every Settings page says then; a member of
// a controller before 1.7.0, that alerts are for its admins there.
export function alertsPage() {
  if (!state.role) return notReadyState() || h("p", { class: "field-help", role: "status" }, t("common.loading"));
  if (!alertsForKey()) return alertsCard(h("p", { class: "notice notice-info", dataset: { key: "alerts-admins" } }, t("alerts.settings.adminOnly")));
  return alertsPanel() || signedOutCard();
}

// The line under Settings' Alerts row: how alerts are on this device, as its page says. null (no
// row) for whoever may not have them: before connecting, or a member of a controller before 1.7.0
// (as the card was). This device first: alerts on (still on with the account's session ended), or
// why this browser cannot have them; then the account.
export function alertsStatus() {
  if (!alertsForKey()) return null;
  const account = state.account.status;
  if (alertsOn()) {
    if (account === "signed-out") return t("settings.rows.alerts.onSignedOut");
    // How many kinds are on, once the controller has said which this key may choose.
    const kinds = account === "signed-in" && controllerChooses() && alertsUi.choices ? offeredKinds() : [];
    if (!kinds.length) return t("settings.rows.alerts.on");
    return t("settings.rows.alerts.onKinds", { on: kinds.filter((kind) => kind.on).length, count: kinds.length });
  }
  const browser = obstacle(alertsSupport(), true);
  if (browser) return t(`settings.rows.alerts.${browser}`);
  if (account === "unknown" || account === "loading") return t("common.loading");
  if (account === "unavailable") return t("settings.rows.accountUnavailable");
  if (account !== "signed-in") return t("settings.rows.alerts.signIn");
  if (!savedRemote()) return t("settings.rows.alerts.notLinked");
  return t("settings.rows.alerts.off");
}

export function alertsPanel() {
  if (!alertsAllowed()) return null;
  const support = alertsSupport();
  const linked = Boolean(savedRemote());
  const on = alertsOn();
  const chooses = controllerChooses();
  const reason = obstacle(support, linked);
  const hint = reason ? t(`alerts.settings.${reason}`) : null;
  // What the last tap led to, unless the hint already says it (the permission refused: blocked).
  const message = alertsUi.message ? t(`alerts.settings.${alertsUi.message.key}`) : null;
  // Off while it cannot be used or is busy, but focusable (aria-disabled): the keyboard stays on
  // it while it works, and its new state, or why it is off, is read on it.
  const off = Boolean(hint) || alertsUi.busy;
  return alertsCard(
    mainSwitch(on, off, Boolean(hint)),
    hint ? h("p", { class: "notice notice-info", id: "alerts-hint", role: message === hint ? "status" : null, dataset: { key: "alerts-hint" } }, hint) : null,
    lastMessage(hint),
    on && chooses && !hint ? kindsList() : null
  );
}
