// Say or type a command (1.9.0, ADR-063): the field under Home's header, and the same field in a
// dialog from the header of the other screens on wide screens, or with the "/" key. A microphone
// where the browser can turn speech into text (the Web Speech API: Chrome, Edge, Safari; not the
// iPhone's Home Screen app, where the keyboard's own microphone does it). What it understood, the
// result, the questions and the second taps come from js/commands.js.

import { chooseOption, clearCommand, commandMessage, commandState, confirmCommand, submitCommand } from "../commands.js";
import { doorbellButton, relayButton } from "../components.js";
import { announce, h, iconButton } from "../dom.js";
import { currentLanguage, t } from "../i18n.js";
import { icon } from "../icons.js";
import { IS_IOS } from "../platform.js";
import { findScene, isolate, runScene } from "../scenes.js";
import { can, deviceKey, notify, state, subscribe, ui } from "../state.js";

// What is being typed, kept over redraws (not in the renderer's signature, so typing redraws nothing).
let draft = "";
// The speech service while it listens, and what it heard so far.
let listening = null;
let heard = "";
// The browser refused its speech service (no Siri, a policy): the keyboard's microphone then.
let speechOff = false;

// ---- the microphone --------------------------------------------------------------------------

function recognitionClass() {
  return window.SpeechRecognition || window.webkitSpeechRecognition || null;
}

function homeScreenApp() {
  try {
    if (window.matchMedia("(display-mode: standalone)").matches) return true;
  } catch {
    // No media queries here.
  }
  return navigator.standalone === true;
}

// The microphone button, where the browser listens. On iPhone and iPad the Home Screen app has the
// API but WebKit does not listen there: the keyboard's own microphone types into the field instead.
export function speechAvailable() {
  if (speechOff || !recognitionClass()) return false;
  return !(IS_IOS && homeScreenApp());
}

function setFields(text) {
  for (const input of document.querySelectorAll?.(".command-input") || []) input.value = text;
}

const SPEECH_ERRORS = {
  "not-allowed": "blocked",
  "service-not-allowed": "unavailable",
  "no-speech": "noSpeech",
  "audio-capture": "noMicrophone",
  network: "network",
  "language-not-supported": "language",
};

function startListening() {
  const Recognition = recognitionClass();
  if (!Recognition || listening) return;
  readyToSpeak();
  let recognition;
  try {
    recognition = new Recognition();
  } catch {
    speechOff = true;
    commandMessage(t("command.speech.unavailable"), "error");
    return;
  }
  recognition.lang = currentLanguage() === "he" ? "he-IL" : "en-US";
  recognition.interimResults = true;
  recognition.maxAlternatives = 3;
  recognition.continuous = false;
  let finals = null;
  let failure = null;
  recognition.onresult = (event) => {
    const results = Array.from(event.results || []);
    heard = results.map((result) => result[0]?.transcript || "").join("");
    // What it hears is in the field, to send or correct if listening stops before it is final.
    draft = heard;
    setFields(heard);
    const last = results[results.length - 1];
    if (last?.isFinal) {
      const before = results.slice(0, -1).map((result) => result[0]?.transcript || "").join("");
      finals = Array.from(last).map((alternative) => `${before}${alternative.transcript}`.trim());
    }
    notify();
  };
  recognition.onerror = (event) => {
    failure = event?.error || "failed";
  };
  recognition.onend = () => {
    listening = null;
    heard = "";
    if (finals?.length) {
      draft = finals[0];
      setFields(draft);
      run(finals[0], finals.slice(1));
    } else if (failure && failure !== "aborted") {
      const reason = SPEECH_ERRORS[failure] || "failed";
      if (reason === "unavailable") speechOff = true;
      commandMessage(t(`command.speech.${reason}`), "error");
    } else {
      notify();
    }
  };
  listening = recognition;
  clearCommand();
  try {
    recognition.start();
  } catch {
    listening = null;
    commandMessage(t("command.speech.failed"), "error");
  }
  notify();
}

function stopListening() {
  try {
    listening?.stop();
  } catch {
    listening = null;
    notify();
  }
}

// ---- the field -----------------------------------------------------------------------------

function run(text, alternatives = []) {
  const shown = submitCommand(text, alternatives);
  // Understood: the field empties for the next one. Not understood: the words stay to correct.
  if (shown && !["ask", "problem", "unknown", "message"].includes(shown.stage)) {
    draft = "";
    setFields("");
  }
}

function field(where) {
  const placeholder = !speechAvailable() && IS_IOS ? t("command.placeholderDictation") : t("command.placeholder");
  const input = h("input", {
    type: "text",
    id: `command-input-${where}`,
    class: "command-input",
    value: draft,
    placeholder,
    enterkeyhint: "go",
    autocomplete: "off",
    autocorrect: "off",
    autocapitalize: "off",
    spellcheck: "false",
    dataset: { key: `command-input:${where}` },
    onfocus: readyToSpeak,
    oninput: (event) => {
      draft = event.target.value;
    },
    onkeydown: (event) => {
      if (event.key !== "Escape") return;
      if (draft) {
        draft = "";
        event.target.value = "";
        event.preventDefault?.();
      } else if (commandState()) {
        clearCommand();
        event.preventDefault?.();
      }
    },
  });
  const mic = speechAvailable()
    ? iconButton(listening ? "stop" : "mic", listening ? t("command.stopListening") : t("command.speak"), {
        class: `command-mic ${listening ? "is-listening" : ""}`,
        "aria-pressed": String(Boolean(listening)),
        dataset: { key: `command-mic:${where}` },
        onclick: () => (listening ? stopListening() : startListening()),
      })
    : null;
  return h(
    "form",
    {
      class: "command-form",
      onsubmit: (event) => {
        event.preventDefault?.();
        run(draft);
      },
    },
    h("label", { class: "visually-hidden", for: `command-input-${where}` }, t("command.label")),
    input,
    mic,
    iconButton("moveForward", t("command.go"), { type: "submit", class: "command-go", dataset: { key: `command-go:${where}` } })
  );
}

function said(text) {
  return h("p", { class: "command-said", dir: "auto" }, text);
}

// A door or gate the command named: its own Open button, in its second tap already.
function doorControl(ref) {
  const list = ref.kind === "relay" ? state.relays : state.doorbells;
  const device = (list || []).find((item) => item.id === ref.id);
  if (!device) return null;
  const confirming = (ref.kind === "relay" ? ui.relayStage : ui.doorbellStage)[ref.id] === "confirm";
  const error = state.errors[deviceKey(ref.kind, ref.id)];
  return [
    h("div", { class: "command-actions" }, ref.kind === "relay" ? relayButton(device) : doorbellButton(device)),
    error ? h("p", { class: "command-result is-error", role: "alert" }, error.text) : confirming ? h("p", { class: "command-hint" }, t("relays.confirmHint")) : null,
  ];
}

// A scene that opens doors: its Run button, which asks for its second tap as on Scenes.
function sceneControl(id, where) {
  const scene = findScene(id);
  if (!scene) return null;
  const run = ui.sceneRuns[scene.id];
  const label = run?.stage === "running" ? t("scenes.running") : run?.stage === "confirm" ? t("scenes.tapAgain") : t("scenes.run");
  return [
    h(
      "div",
      { class: "command-actions" },
      h(
        "button",
        {
          type: "button",
          class: `button button-primary button-small ${run?.stage === "confirm" ? "is-confirm" : ""}`,
          disabled: run?.stage === "running",
          "aria-label": t("scenes.runLabel", { name: scene.name }),
          dataset: { key: `command-scene:${where}` },
          onclick: () => runScene(scene),
        },
        icon(run?.stage === "confirm" ? "door" : "scene"),
        h("span", {}, label)
      )
    ),
    run?.text && run.stage !== "running" ? h("p", { class: `command-result is-${run.stage === "done" ? "done" : run.stage === "confirm" ? "info" : "error"}` }, run.text) : null,
  ];
}

function examples(list, where) {
  return h(
    "div",
    { class: "command-examples" },
    h("span", { class: "command-examples-label" }, t("command.examples")),
    list.map((example, index) =>
      h(
        "button",
        {
          type: "button",
          class: "chip command-example",
          dir: "auto",
          dataset: { key: `command-example:${where}:${index}` },
          // Puts it in the field, to change or send.
          onclick: () => {
            draft = example;
            setFields(example);
            document.querySelector?.(`#command-input-${where}`)?.focus();
          },
        },
        example
      )
    )
  );
}

function body(now, where) {
  switch (now.stage) {
    case "running":
      return [said(now.said), h("p", { class: "command-result is-running" }, t("command.result.running"))];
    case "done":
    case "partial":
    case "error":
      return [now.said ? said(now.said) : null, h("p", { class: `command-result is-${now.stage}` }, icon(now.stage === "done" ? "check" : "info"), h("span", {}, now.text))];
    case "ask":
      return [
        h("p", { class: "command-question", id: `command-question-${where}` }, now.text),
        h(
          "div",
          { class: "command-options", role: "group", "aria-labelledby": `command-question-${where}` },
          now.labels.map((label, index) =>
            h(
              "button",
              { type: "button", class: "button button-secondary button-small command-option", dataset: { key: `command-option:${where}:${index}` }, onclick: () => chooseOption(index) },
              h("span", { dir: "auto" }, label)
            )
          )
        ),
      ];
    case "confirm": {
      const blinds = now.action.filters.length === 1 && now.action.filters[0] === "blinds";
      return [
        said(now.said),
        h("p", { class: "command-result" }, now.text),
        h(
          "div",
          { class: "command-actions" },
          h(
            "button",
            { type: "button", class: "button button-primary button-small", dataset: { key: `command-confirm:${where}` }, onclick: confirmCommand },
            icon(blinds ? "blinds" : "power"),
            h("span", {}, t(blinds ? "command.off.close" : "command.off.confirm"))
          ),
          h("button", { type: "button", class: "button button-quiet button-small", dataset: { key: `command-cancel:${where}` }, onclick: clearCommand }, t("common.cancel"))
        ),
      ];
    }
    case "door":
      return [said(now.said), doorControl(now.action.device)];
    case "scene":
      return [said(now.said), sceneControl(now.action.id, where)];
    default:
      return [
        h("p", { class: `command-result is-${now.stage === "unknown" || now.kind === "error" ? "error" : "info"}` }, now.text),
        now.examples ? examples(now.examples, where) : null,
      ];
  }
}

function output(where) {
  if (listening) {
    return h(
      "div",
      { class: "command-output is-listening" },
      h(
        "div",
        { class: "command-body" },
        h("p", { class: "command-said" }, icon("mic"), h("span", { dir: "auto" }, heard ? t("command.hearing", { words: isolate(heard) }) : t("command.listening"))),
        h("p", { class: "command-note" }, t("command.speechNote"))
      )
    );
  }
  const now = commandState();
  if (!now) return null;
  return h(
    "div",
    { class: `command-output is-${now.stage}` },
    h("div", { class: "command-body" }, body(now, where)),
    now.stage === "running" ? null : iconButton("close", t("command.dismiss"), { class: "command-dismiss", dataset: { key: `command-dismiss:${where}` }, onclick: clearCommand })
  );
}

// For the renderer's signature (app.js): what the command area shows.
export function commandSignature() {
  return [commandState(), Boolean(listening), heard, speechOff];
}

function allowed() {
  return Boolean(state.apiKey) && state.loaded && can("member");
}

let spoken = false;

// The live region that says what a command understood (dom.js), made as the field is used, before
// there is anything to say.
function readyToSpeak() {
  if (spoken) return;
  spoken = true;
  announce("");
}

// Home: under the header, for everyone who controls something.
export function commandBar() {
  if (!allowed()) return null;
  return h("section", { class: "command", "aria-label": t("command.label") }, field("home"), output("home"));
}

// ---- from the other screens ----------------------------------------------------------------

let dialog = null;
let dialogDrawn = "";

function drawDialog(force = false) {
  const now = JSON.stringify([commandSignature(), currentLanguage(), ui.relayStage, ui.doorbellStage, ui.sceneRuns, Object.keys(state.errors)]);
  if (!force && now === dialogDrawn) return;
  dialogDrawn = now;
  const active = document.activeElement;
  const key = dialog.contains(active) ? active.dataset?.key : null;
  dialog.replaceChildren(
    h(
      "div",
      { class: "dialog-head" },
      h("h2", { id: "command-dialog-title", class: "dialog-title" }, t("command.title")),
      iconButton("close", t("common.close"), { onclick: () => dialog.close() })
    ),
    field("dialog"),
    output("dialog")
  );
  const target = key ? [...dialog.querySelectorAll("[data-key]")].find((item) => item.dataset.key === key && !item.disabled) : null;
  target?.focus({ preventScroll: true });
}

export function openCommandDialog() {
  if (!allowed()) return;
  if (!dialog) {
    dialog = h("dialog", { id: "command-dialog", class: "dialog command-dialog", "aria-labelledby": "command-dialog-title" });
    dialog.addEventListener("click", (event) => {
      if (event.target === dialog) dialog.close();
    });
    dialog.addEventListener("close", stopListening);
    document.body.append(dialog);
    subscribe(() => {
      if (dialog.open) drawDialog();
    });
  }
  drawDialog(true);
  if (!dialog.open) dialog.showModal();
  dialog.querySelector(".command-input")?.focus();
}

// A screen's header: the way to the dialog, on screens wide enough for it (styles.css).
export function commandButton() {
  if (!allowed()) return null;
  return iconButton("say", t("command.open"), { class: "command-open", dataset: { key: "command-open" }, onclick: openCommandDialog });
}

// "/" anywhere but in a field: Home's field, or the dialog.
document.addEventListener("keydown", (event) => {
  if (event.key !== "/" || event.ctrlKey || event.metaKey || event.altKey || event.defaultPrevented) return;
  const target = event.target;
  if (target?.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target?.tagName)) return;
  if (!allowed() || document.querySelector("dialog[open]")) return;
  event.preventDefault();
  const home = document.querySelector("#command-input-home");
  if (home) home.focus();
  else openCommandDialog();
});
