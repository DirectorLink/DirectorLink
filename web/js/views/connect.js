// First-time setup on Home: controller address, then "Request access" (approved with the
// C4Bridge Access button in the Control4 app) or the 8-digit pairing code from Composer.

import { h } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { cancelAccess, pairWithCode, requestAccess } from "../session.js";
import { state, ui } from "../state.js";

function countdown(expiresAt) {
  const seconds = Math.max(0, Math.round((Date.parse(expiresAt) - Date.now()) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function draftInput(key, fallback, props) {
  const input = h("input", { ...props, value: ui.drafts[key] ?? fallback, dataset: { key } });
  input.addEventListener("input", () => {
    ui.drafts[key] = input.value;
  });
  return input;
}

function notice() {
  if (!state.notice) return null;
  return h(
    "p",
    { class: `notice notice-${state.notice.kind}`, role: state.notice.kind === "error" ? "alert" : "status" },
    state.notice.text
  );
}

function waitingCard() {
  const expiresAt = state.access?.expiresAt;
  return h(
    "section",
    { class: "card connect-card waiting", "aria-labelledby": "waiting-title" },
    h("span", { class: "connect-icon pulse" }, icon("key")),
    h("h2", { id: "waiting-title", class: "connect-title" }, t("connect.waitingTitle")),
    h("ol", { class: "steps" }, h("li", {}, t("connect.step1")), h("li", {}, t("connect.step2"))),
    h(
      "p",
      { class: "countdown", role: "timer", "aria-live": "off" },
      expiresAt ? t("connect.timeLeft", { time: countdown(expiresAt) }) : t("connect.sending")
    ),
    h(
      "button",
      { id: "cancel-access-button", type: "button", class: "button button-secondary button-wide", dataset: { key: "cancel-access" }, onclick: cancelAccess },
      t("connect.cancel")
    )
  );
}

export function connectScreen() {
  if (state.status === "waiting") {
    return h("div", { class: "connect" }, notice(), waitingCard());
  }
  const host = draftInput("host", state.host, {
    id: "controller-host",
    type: "text",
    inputmode: "url",
    autocomplete: "off",
    autocapitalize: "off",
    spellcheck: "false",
    placeholder: "192.168.1.50",
    "aria-describedby": "controller-host-help",
    required: true,
  });
  const code = draftInput("pairingCode", "", {
    id: "pairing-code",
    type: "text",
    inputmode: "numeric",
    autocomplete: "one-time-code",
    spellcheck: "false",
    maxlength: "8",
    pattern: "[0-9]{8}",
    placeholder: "12345678",
    "aria-describedby": "pairing-code-help",
  });
  const busy = state.status === "connecting";

  const form = h(
    "form",
    {
      class: "connect-form",
      novalidate: true,
      onsubmit: (event) => {
        event.preventDefault();
        requestAccess(host.value);
      },
    },
    h("label", { class: "field-label", for: "controller-host" }, t("connect.hostLabel")),
    host,
    h("p", { id: "controller-host-help", class: "field-help" }, t("connect.hostHelp")),
    ui.drafts.pairingOpen ? null : notice(),
    h(
      "button",
      { type: "submit", class: "button button-primary button-wide", disabled: busy, dataset: { key: "request-access" } },
      busy ? t("status.connecting") : t("connect.requestAccess")
    ),
    h("p", { class: "field-help" }, t("connect.requestHelp"))
  );

  const pairing = h(
    "details",
    { class: "pairing", open: Boolean(ui.drafts.pairingOpen) },
    h("summary", { dataset: { key: "pairing-summary" } }, t("connect.useCode")),
    h("label", { class: "field-label", for: "pairing-code" }, t("connect.codeLabel")),
    code,
    h("p", { id: "pairing-code-help", class: "field-help" }, t("connect.codeHelp")),
    // With the code form open, messages show next to it.
    ui.drafts.pairingOpen ? notice() : null,
    h(
      "button",
      {
        type: "button",
        class: "button button-secondary button-wide",
        disabled: busy,
        dataset: { key: "pair" },
        onclick: () => {
          const value = code.value;
          ui.drafts.pairingCode = "";
          pairWithCode(host.value, value);
        },
      },
      t("connect.pair")
    )
  );
  pairing.addEventListener("toggle", () => {
    ui.drafts.pairingOpen = pairing.open;
  });

  return h(
    "div",
    { class: "connect" },
    h(
      "section",
      { class: "card connect-card", "aria-labelledby": "connect-title" },
      h("span", { class: "connect-icon" }, icon("home")),
      h("h2", { id: "connect-title", class: "connect-title" }, t("connect.title")),
      h("p", { class: "connect-text" }, t("connect.intro")),
      form,
      pairing
    ),
    h("p", { class: "connect-footnote" }, t("connect.lanNote"))
  );
}
