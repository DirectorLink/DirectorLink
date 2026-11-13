// Arm and Disarm under a partition on Home, the choice of mode, and the dialog the alarm code is typed
// into (DirectorLink 1.15.0, ADR-091; js/alarm-control.js sends it and follows what the alarm does).
// Only for a partition the controller says this person may arm and disarm (`control.allowed`); while
// its driver cannot (`control.available` false) a note says why instead.
//
// The code is typed for every command, in a masked number field that the browser is asked neither to
// fill nor to save, in a dialog of its own outside the screen (redraws never touch it). The field's
// value is read once, when it is sent; then the field is emptied and the dialog taken out of the page.
// It is never kept, logged, put in `ui` or `state`, or shown.
//
// Since 1.16.0 (ADR-092), where the partition goes without a code (`control.without_code`): Arm (and
// its mode) sends at once; Disarm asks "Disarm House?" first, in the same dialog without a field, so
// that a tap by mistake disarms nothing. When the controller asks for the code after all, the
// dialog asks for it, saying why.

import { h, iconButton } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { armModeLabel } from "../alarm.js";
import {
  CODE_MAX,
  CODE_NEEDED,
  CODE_PATTERN,
  alarmActions,
  alarmPartition,
  cancelChoice,
  chooseMode,
  clearMessage,
  controlAllowed,
  controlAvailable,
  controlOf,
  sendAlarmCommand,
  statusKey,
  takeFocus,
  wantFocus,
  withoutCode,
} from "../alarm-control.js";
import { whenForgotten } from "../session.js";

const isolate = (text) => `⁨${text}⁩`;

// The open dialog: { dialog, input, opener (the data-key of the button that opened it) }, or null.
let open = null;

function focusKey(key) {
  const target = [...(document.querySelectorAll?.("[data-key]") || [])].find((item) => item.dataset.key === key && !item.disabled);
  target?.focus({ preventScroll: true });
}

// Gives the keyboard to the element once app.js has drawn it (it keeps it over later redraws: data-key).
function focusable(element) {
  if (takeFocus(element.dataset.key)) window.setTimeout(() => focusKey(element.dataset.key), 0);
  return element;
}

function actionButton(partition, action, onclick) {
  const key = `alarm:${partition.id}:${action}`;
  return focusable(
    h(
      "button",
      {
        type: "button",
        class: `button ${action === "disarm" ? "button-primary" : "button-secondary"} button-small alarm-button`,
        "aria-label": t(`alarm.control.${action}Label`, { name: partition.name }),
        dataset: { key },
        onclick,
      },
      icon(action === "disarm" ? "shieldOff" : "shield"),
      h("span", {}, t(`alarm.control.${action}`))
    )
  );
}

function modeChoice(partition, modes) {
  const id = partition.id;
  const titleId = `alarm-${id}-modes`;
  return h(
    "div",
    { class: "alarm-actions alarm-modes", role: "group", "aria-labelledby": titleId },
    h("span", { class: "alarm-modes-title", id: titleId }, t("alarm.control.chooseMode")),
    modes.map((mode, index) => {
      const key = `alarm:${id}:mode:${index}`;
      return focusable(
        h(
          "button",
          {
            type: "button",
            class: "button button-secondary button-small alarm-mode",
            "aria-label": t("alarm.control.modeLabel", { name: partition.name, mode: armModeLabel(mode) }),
            dataset: { key },
            onclick: () => command(id, "arm", mode, key),
          },
          h("span", { dir: "auto" }, armModeLabel(mode))
        )
      );
    }),
    h(
      "button",
      {
        type: "button",
        class: "button button-quiet button-small",
        dataset: { key: `alarm:${id}:cancel` },
        onclick: () => {
          wantFocus(`alarm:${id}:arm`);
          cancelChoice(id);
        },
      },
      t("common.cancel")
    )
  );
}

// What goes under the partition's row: the buttons, the modes, "Arming…", or why it cannot now; and
// what went wrong. null when there is nothing (this person may not arm or disarm it).
export function alarmControls(partition) {
  const id = partition.id;
  const control = controlOf(id) || {};
  const message = control.message ? h("p", { class: "inline-error alarm-message", role: "alert", dataset: { key: `alarm:${id}:message` } }, control.message.text) : null;
  if (!controlAllowed(partition)) return message;
  if (!controlAvailable(partition)) return [h("p", { class: "muted-note alarm-note" }, t("alarm.control.unavailable")), message];
  if (control.stage === "sending" || control.stage === "pending") {
    const text = control.stage === "sending" ? t("alarm.control.sending") : t(control.action === "arm" ? "alarm.control.arming" : "alarm.control.disarming");
    return [focusable(h("p", { class: "alarm-pending", role: "status", tabindex: "-1", dataset: { key: statusKey(id) } }, icon("refresh"), h("span", {}, text))), message];
  }
  const { modes, disarm } = alarmActions(partition);
  if (control.stage === "choose" && modes.length > 1) return [modeChoice(partition, modes), message];
  const buttons = [];
  if (modes.length) {
    buttons.push(
      actionButton(partition, "arm", () => {
        clearMessage(id);
        if (modes.length === 1) {
          command(id, "arm", modes[0], `alarm:${id}:arm`);
        } else {
          wantFocus(`alarm:${id}:mode:0`);
          chooseMode(id);
        }
      })
    );
  }
  if (disarm) {
    buttons.push(
      actionButton(partition, "disarm", () => {
        clearMessage(id);
        command(id, "disarm", null, `alarm:${id}:disarm`);
      })
    );
  }
  return [buttons.length ? h("div", { class: "alarm-actions" }, buttons) : null, message];
}

// ---- the code ------------------------------------------------------------------------------

// Arm in `mode`, or Disarm, pressed: the code asked for, or (1.16.0) none where the partition goes
// without one: arming goes at once, disarming once confirmed.
function command(id, action, mode, opener) {
  const partition = alarmPartition(id);
  if (!withoutCode(partition, action)) {
    openCodeDialog(id, action, mode, opener);
  } else if (action === "disarm") {
    openCodeDialog(id, action, mode, opener, { confirm: true });
  } else {
    sendWithoutCode(id, action, mode);
  }
}

// "Sending…", then "Arming…", has the keyboard. The controller asked for the code after all (an
// admin changed Settings → Alarm meanwhile): the dialog asks for it.
async function sendWithoutCode(id, action, mode) {
  wantFocus(statusKey(id));
  if ((await sendAlarmCommand({ id, action, mode, code: null })) === CODE_NEEDED) {
    openCodeDialog(id, action, mode, `alarm:${id}:${action}`, { needed: true });
  }
}

// The dialog for arming partition `id` in `mode`, or disarming it. `opener`: the data-key of the
// button that opened it, which gets the keyboard back when it is closed without sending. `confirm`
// (1.16.0): a disarm without a code, only confirmed ("Disarm House?"), no field. `needed`: the
// controller asked for the code of a command sent without one; the dialog says so.
export function openCodeDialog(id, action, mode, opener, { confirm = false, needed = false } = {}) {
  closeCodeDialog();
  const partition = alarmPartition(id);
  if (!controlAvailable(partition)) return;
  if (confirm) {
    openConfirmDialog(id, partition, opener);
    return;
  }
  const title =
    action === "arm"
      ? t("alarm.control.armTitle", { name: isolate(partition.name), mode: armModeLabel(mode) })
      : t("alarm.control.disarmTitle", { name: isolate(partition.name) });
  const problem = h("p", { id: "alarm-code-problem", class: "inline-error", role: "alert" });
  const input = h("input", {
    id: "alarm-code",
    type: "password",
    inputmode: "numeric",
    pattern: "[0-9]*",
    maxlength: String(CODE_MAX),
    // Neither filled nor saved: the code is typed each time (password managers asked to leave it too).
    autocomplete: "off",
    autocapitalize: "off",
    autocorrect: "off",
    spellcheck: "false",
    enterkeyhint: "send",
    required: true,
    "aria-describedby": "alarm-code-help alarm-code-problem",
    "data-1p-ignore": "true",
    "data-lpignore": "true",
    "data-bwignore": "true",
    "data-form-type": "other",
    dataset: { key: "alarm-code" },
    // Digits only, at most 12 (a paste or a computer's keyboard may bring others).
    oninput: () => {
      const digits = input.value.replace(/\D/g, "").slice(0, CODE_MAX);
      if (digits !== input.value) input.value = digits;
      problem.textContent = "";
    },
  });
  const submit = (event) => {
    event.preventDefault();
    const code = input.value;
    if (!CODE_PATTERN.test(code)) {
      problem.textContent = t("alarm.control.codeInvalid");
      input.focus();
      return;
    }
    input.value = "";
    closeCodeDialog({ sent: true });
    // "Sending…", then "Arming…", has the keyboard.
    wantFocus(statusKey(id));
    sendAlarmCommand({ id, action, mode, code });
  };
  const form = h(
    "form",
    { class: "alarm-code-form", autocomplete: "off", novalidate: true, onsubmit: submit },
    h(
      "div",
      { class: "field" },
      needed ? h("p", { class: "notice notice-info", role: "status", dataset: { key: "alarm-code-needed" } }, t("alarm.control.codeNeeded")) : null,
      h("label", { class: "field-label", for: "alarm-code" }, t("alarm.control.codeLabel")),
      input,
      h("p", { id: "alarm-code-help", class: "field-help" }, t("alarm.control.codeHelp")),
      problem
    ),
    h(
      "div",
      { class: "button-row" },
      h(
        "button",
        { type: "submit", class: "button button-primary", dataset: { key: "alarm-code-send" } },
        icon(action === "disarm" ? "shieldOff" : "shield"),
        h("span", {}, t(`alarm.control.${action}`))
      ),
      h("button", { type: "button", class: "button button-quiet", dataset: { key: "alarm-code-cancel" }, onclick: () => closeCodeDialog() }, t("common.cancel"))
    )
  );
  showDialog(title, form, input, opener);
  input.focus();
}

// Disarm without a code (1.16.0): "Disarm House?", Disarm or Cancel, so that a tap by mistake
// disarms nothing. Nothing to type: the alarm's driver uses its own code.
function openConfirmDialog(id, partition, opener) {
  const send = h(
    "button",
    { type: "submit", class: "button button-primary", dataset: { key: "alarm-confirm-send" } },
    icon("shieldOff"),
    h("span", {}, t("alarm.control.disarm"))
  );
  const confirmed = (event) => {
    event.preventDefault();
    closeCodeDialog({ sent: true });
    sendWithoutCode(id, "disarm", null);
  };
  const form = h(
    "form",
    { class: "alarm-code-form", novalidate: true, onsubmit: confirmed },
    h("p", { class: "field-help", dataset: { key: "alarm-confirm-help" } }, t("alarm.control.disarmConfirmHelp")),
    h(
      "div",
      { class: "button-row" },
      send,
      h("button", { type: "button", class: "button button-quiet", dataset: { key: "alarm-code-cancel" }, onclick: () => closeCodeDialog() }, t("common.cancel"))
    )
  );
  showDialog(t("alarm.control.disarmConfirmTitle", { name: isolate(partition.name) }), form, null, opener);
  send.focus();
}

// The dialog, outside the screen. A tap on the backdrop, Escape or Close: closed, and the code typed
// so far is gone.
function showDialog(title, form, input, opener) {
  const dialog = h(
    "dialog",
    { id: "alarm-dialog", class: "dialog alarm-dialog", "aria-labelledby": "alarm-dialog-title" },
    h("div", { class: "dialog-head" }, h("h2", { id: "alarm-dialog-title", class: "dialog-title alarm-dialog-title" }, title), iconButton("close", t("common.close"), { onclick: () => closeCodeDialog() })),
    form
  );
  dialog.addEventListener("click", (event) => {
    if (event.target === dialog) closeCodeDialog();
  });
  dialog.addEventListener("close", () => closeCodeDialog());
  document.body.append(dialog);
  open = { dialog, input, opener };
  dialog.showModal();
}

// Empties the field and takes the dialog out of the page. `sent`: the code went; the keyboard goes to
// "Sending…" rather than back to the button that opened it.
export function closeCodeDialog({ sent = false } = {}) {
  if (!open) return;
  const { dialog, input, opener } = open;
  open = null;
  if (input) input.value = "";
  if (dialog.open) dialog.close();
  dialog.remove();
  if (!sent && opener) window.setTimeout(() => focusKey(opener), 0);
}

// The key forgotten: a dialog left open goes, with whatever was typed.
whenForgotten(() => closeCodeDialog());
