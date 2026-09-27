// First-time setup on Home: the controller address and the pairing code from Composer
// (DirectorLink → Actions → New Pairing Code). A code lasts 15 minutes and works once.

import { formatPairingCode } from "../../api-client.js";
import { h } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { pairWithCode } from "../session.js";
import { state, ui } from "../state.js";

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

// Shows the code as "1234 5678" while it is typed or pasted (with or without the space or a
// dash), keeping the caret after the same digit.
export function formatCodeField(input) {
  const caretDigits = input.value.slice(0, input.selectionStart ?? input.value.length).replace(/\D/g, "").length;
  const formatted = formatPairingCode(input.value);
  if (formatted !== input.value) {
    input.value = formatted;
    const caret = Math.min(formatted.length, caretDigits > 4 ? caretDigits + 1 : caretDigits);
    try {
      input.setSelectionRange(caret, caret);
    } catch {
      // Not focused.
    }
  }
  return formatted;
}

export function connectScreen() {
  const host = draftInput("host", state.host, {
    id: "controller-host",
    type: "text",
    inputmode: "url",
    autocomplete: "off",
    autocapitalize: "off",
    spellcheck: "false",
    dir: "ltr",
    placeholder: "192.168.1.50",
    "aria-describedby": "controller-host-help",
    required: true,
  });
  const code = draftInput("pairingCode", "", {
    id: "pairing-code",
    class: "code-input",
    type: "text",
    inputmode: "numeric",
    autocomplete: "one-time-code",
    autocapitalize: "off",
    spellcheck: "false",
    dir: "ltr",
    placeholder: "1234 5678",
    "aria-describedby": "pairing-code-help",
    required: true,
  });
  code.addEventListener("input", () => {
    ui.drafts.pairingCode = formatCodeField(code);
  });
  const busy = state.status === "connecting";

  const form = h(
    "form",
    {
      class: "connect-form",
      novalidate: true,
      onsubmit: async (event) => {
        event.preventDefault();
        await pairWithCode(host.value, code.value);
        // A code works once: once it bought a key, it is of no use in the field.
        if (state.apiKey) ui.drafts.pairingCode = "";
      },
    },
    h("label", { class: "field-label", for: "controller-host" }, t("connect.hostLabel")),
    host,
    h("p", { id: "controller-host-help", class: "field-help" }, t("connect.hostHelp")),
    h("label", { class: "field-label", for: "pairing-code" }, t("connect.codeLabel")),
    code,
    h("p", { id: "pairing-code-help", class: "field-help" }, t("connect.codeHelp")),
    notice(),
    h(
      "button",
      { type: "submit", class: "button button-primary button-wide", disabled: busy, dataset: { key: "pair" } },
      busy ? t("status.connecting") : t("connect.pair")
    )
  );

  return h(
    "div",
    { class: "connect" },
    h(
      "section",
      { class: "card connect-card", "aria-labelledby": "connect-title" },
      h("span", { class: "connect-icon" }, icon("key")),
      h("h2", { id: "connect-title", class: "connect-title" }, t("connect.title")),
      h("p", { class: "connect-text" }, t("connect.intro")),
      form
    ),
    h("p", { class: "connect-footnote" }, t("connect.lanNote"))
  );
}
