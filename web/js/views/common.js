// Page header, connection chip and the states every screen shares (not connected, loading,
// controller unreachable).

import { h, iconButton } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { connect } from "../session.js";
import { state } from "../state.js";
import { emptyState } from "../components.js";

export function connectionChip() {
  const status = state.status;
  const kind =
    status === "connected" ? "ok" : status === "unreachable" ? "error" : status === "connecting" ? "busy" : "idle";
  const label = t(`status.${status}`);
  return h(
    "a",
    {
      class: `status-chip status-${kind}`,
      href: "#/settings",
      "aria-label": t("status.chipLabel", { status: label }),
    },
    h("span", { class: "status-dot", "aria-hidden": "true" }),
    h("span", { class: "status-text" }, label)
  );
}

export function pageHeader({ title, back, actions = [], titleDir } = {}) {
  return h(
    "header",
    { class: "page-header" },
    back
      ? h(
          "a",
          { class: "icon-button back-button", href: back, "aria-label": t("common.back"), dataset: { key: "back" }, onclick: goBack },
          icon("chevronBack")
        )
      : null,
    h("h1", { class: "page-title", tabindex: "-1", dir: titleDir }, title),
    h("div", { class: "page-actions" }, ...actions, connectionChip())
  );
}

// Back returns to the previous screen when there is one in this app, else to the link target.
function goBack(event) {
  if (window.history.state?.c4bridgeInApp) {
    event.preventDefault();
    window.history.back();
  }
}

export function offlineBanner() {
  if (state.online) return null;
  return h("p", { class: "banner banner-info" }, icon("cloudOff"), h("span", {}, t("offline.banner")));
}

// Data is shown from the last successful read while the controller cannot be reached.
export function staleBanner() {
  if (state.status !== "unreachable" || !state.loaded) return null;
  return h(
    "div",
    { class: "banner banner-error", role: "status" },
    icon("wifiOff"),
    h("span", {}, t("status.staleBanner")),
    h("button", { type: "button", class: "button button-small", dataset: { key: "stale-retry" }, onclick: () => connect() }, t("common.retry"))
  );
}

// For screens other than Home when there is nothing to show yet.
export function notReadyState() {
  if (state.status === "setup" || state.status === "waiting") {
    return emptyState(
      "controller",
      t("connect.notConnectedTitle"),
      t("connect.notConnectedText"),
      h("a", { class: "button button-primary", href: "#/" }, t("connect.goConnect"))
    );
  }
  if (state.status === "unreachable" && !state.loaded) {
    return unreachableState();
  }
  return null;
}

export function unreachableState() {
  return emptyState(
    "wifiOff",
    t("status.unreachableTitle"),
    state.notice?.text || t("errors.unreachable"),
    h(
      "div",
      { class: "button-row" },
      h("button", { type: "button", class: "button button-primary", dataset: { key: "retry" }, onclick: () => connect() }, icon("refresh"), t("common.retry")),
      h("a", { class: "button button-secondary", href: "#/settings" }, t("settings.controller.title"))
    )
  );
}

export function isLoading() {
  return !state.loaded && state.status === "connecting";
}
