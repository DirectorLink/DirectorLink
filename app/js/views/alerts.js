// Settings → Controller: "Alerts on this device" (ADR-047, js/alerts.js), for admins signed in to
// an account, on a device linked to the home. On iPhone and iPad they work only in the app added to
// the Home Screen (iOS 16.4 or later): the card says so there.

import { alertsOn, alertsSupport, alertsUi, turnAlertsOff, turnAlertsOn } from "../alerts.js";
import { h } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { savedRemote } from "../remote.js";
import { can, state } from "../state.js";

// Why the switch cannot be used on this device, or null.
function obstacle(support, linked) {
  if (!linked) return t("alerts.settings.notLinked");
  switch (support) {
    case "homeScreen":
      return t("alerts.settings.homeScreen");
    case "iosVersion":
      return t("alerts.settings.iosVersion");
    case "denied":
      return t("alerts.settings.blocked");
    case "unsupported":
      return t("alerts.settings.unsupported");
    default:
      return null;
  }
}

export function alertsPanel() {
  if (!state.role || !can("admin") || state.account.status !== "signed-in") return null;
  const support = alertsSupport();
  const linked = Boolean(savedRemote());
  const on = alertsOn();
  const hint = obstacle(support, linked);
  // What the last tap led to, unless the hint already says it (the permission refused: blocked).
  const message = alertsUi.message ? t(`alerts.settings.${alertsUi.message.key}`) : null;
  // Off while it cannot be used or is busy, but focusable (aria-disabled): the keyboard stays on
  // it while it works, and its new state, or why it is off, is read on it.
  const off = Boolean(hint) || alertsUi.busy;
  return h(
    "section",
    { class: "card settings-card", id: "settings-alerts", "aria-labelledby": "settings-alerts-title" },
    h("h2", { class: "settings-title", id: "settings-alerts-title" }, icon("bell"), t("alerts.settings.title")),
    h(
      "div",
      { class: "toggle-row alerts-toggle" },
      h(
        "span",
        { class: "toggle-text" },
        h("span", { class: "toggle-title", id: "alerts-switch-label" }, t("alerts.settings.label")),
        h("span", { class: "field-help", id: "alerts-switch-help" }, t("alerts.settings.help"))
      ),
      h(
        "button",
        {
          type: "button",
          role: "switch",
          class: "switch",
          "aria-checked": String(on),
          "aria-labelledby": "alerts-switch-label",
          "aria-describedby": hint ? "alerts-switch-help alerts-hint" : "alerts-switch-help",
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
    ),
    hint ? h("p", { class: "notice notice-info", id: "alerts-hint", role: message === hint ? "status" : null, dataset: { key: "alerts-hint" } }, hint) : null,
    message && message !== hint ? h("p", { class: `notice notice-${alertsUi.message.kind}`, role: "status", dataset: { key: "alerts-message" } }, message) : null
  );
}
