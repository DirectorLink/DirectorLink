// Page header, connection chip and the states every screen shares (not connected, loading,
// controller unreachable).

import { loadProviders, providersStatus, refreshProviders, signIn, signInProviders } from "../account.js";
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
  // Through the account (away from home, or on iPhone) the chip says so.
  const label = status === "connected" && state.transport === "remote" ? t("status.connectedRemote") : t(`status.${status}`);
  return h(
    "a",
    {
      class: `status-chip status-${kind}`,
      href: "#/settings/controller",
      "aria-label": t("status.chipLabel", { status: label }),
    },
    h("span", { class: "status-dot", "aria-hidden": "true" }),
    h("span", { class: "status-text" }, label)
  );
}

// `onBack(event)` runs first when Back is pressed; it may cancel with event.preventDefault().
export function pageHeader({ title, back, onBack, actions = [], titleDir } = {}) {
  return h(
    "header",
    { class: "page-header" },
    back
      ? h(
          "a",
          {
            class: "icon-button back-button",
            href: back,
            "aria-label": t("common.back"),
            dataset: { key: "back" },
            onclick: (event) => {
              onBack?.(event);
              if (!event.defaultPrevented) goBack(event);
            },
          },
          icon("chevronBack")
        )
      : null,
    h("h1", { class: "page-title", tabindex: "-1", dir: titleDir }, title),
    h("div", { class: "page-actions" }, ...actions, connectionChip())
  );
}

// Back returns to the previous screen when there is one in this app, else to the link target.
function goBack(event) {
  if (window.history.state?.directorlinkInApp) {
    event.preventDefault();
    window.history.back();
  }
}

export function offlineBanner() {
  if (state.online) return null;
  return h("p", { class: "banner banner-info" }, icon("cloudOff"), h("span", {}, t("offline.banner")));
}

// One button per sign-in provider the account server has set up (account.js), side by side and the
// same size. Until it has said which, one Sign in button asks it first: a device on which nobody
// signs in never contacts it. `ask`: ask at once (an invitation link needs a sign-in anyway). `key`
// names Google's button; others add their name. `style`: the button style for Google (Apple's is
// its own black or white, as Apple's guidelines ask); `size`: e.g. "button-wide".
export function signInButtons({ hash, key, style = "button-primary", size = "", ask = false }) {
  const providers = signInProviders();
  if (!providers) {
    if (ask && providersStatus() === "idle") loadProviders();
    const status = providersStatus();
    return [
      h(
        "button",
        { type: "button", class: `button ${style} ${size}`.trim(), dataset: { key: `${key}-choose` }, disabled: status === "loading", onclick: () => loadProviders() },
        icon("user"),
        status === "loading" ? t("common.loading") : t("connect.signInShort")
      ),
      status === "failed" ? h("p", { class: "notice notice-error", role: "status" }, t("connect.signInUnreachable")) : null,
    ];
  }
  refreshProviders();
  return providers.map((provider) =>
    h(
      "button",
      {
        type: "button",
        class: `button ${provider === "apple" ? "button-apple" : style} ${size}`.trim(),
        dataset: { key: provider === "google" ? key : `${key}-${provider}` },
        onclick: () => signIn(hash, provider),
      },
      icon(provider === "apple" ? "apple" : "user"),
      t(provider === "apple" ? "connect.signInApple" : "connect.signIn")
    )
  );
}

// Data is shown from the last successful read while the controller cannot be reached.
export function staleBanner() {
  if (state.status !== "unreachable" || !state.loaded) return null;
  // Through the account the reason is known (signed out, home offline, …); signed out, the banner
  // offers to sign in again.
  const remote = Boolean(state.notice?.remote);
  const signedOut = remote && state.account.status === "signed-out";
  return h(
    "div",
    { class: "banner banner-error", role: "status" },
    icon("wifiOff"),
    h("span", {}, remote ? state.notice.text : t("status.staleBanner")),
    signedOut
      ? signInProviders()?.length === 1
        ? signInButtons({ hash: "#/", key: "stale-sign-in", style: "", size: "button-small" })
        : h("a", { class: "button button-small", href: "#/settings/account", dataset: { key: "stale-sign-in" } }, t("connect.signInShort"))
      : h("button", { type: "button", class: "button button-small", dataset: { key: "stale-retry" }, onclick: () => connect() }, t("common.retry"))
  );
}

// For screens other than Home when there is nothing to show yet.
export function notReadyState() {
  if (state.status === "setup" || (!state.apiKey && state.status === "connecting")) {
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
      h("a", { class: "button button-secondary", href: "#/settings/controller" }, t("settings.controller.title"))
    )
  );
}

export function isLoading() {
  return !state.loaded && state.status === "connecting";
}
