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
          "aria-describedby": "alerts-switch-help",
          "aria-busy": alertsUi.busy ? "true" : null,
          disabled: Boolean(hint) || alertsUi.busy,
          dataset: { key: "alerts-switch" },
          onclick: () => (on ? turnAlertsOff() : turnAlertsOn()),
        },
        h("span", { class: "switch-thumb" })
      )
    ),
    hint ? h("p", { class: "notice notice-info", dataset: { key: "alerts-hint" } }, hint) : null,
    alertsUi.message ? h("p", { class: `notice notice-${alertsUi.message.kind}`, role: "status", dataset: { key: "alerts-message" } }, t(`alerts.settings.${alertsUi.message.key}`)) : null
  );
}
