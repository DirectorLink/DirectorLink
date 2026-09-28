// Scenes (#/scenes) and the scene editor (#/scene/new, #/scene/<id>; admins). The list runs a
// scene with one tap. The editor builds a scene from actions: where (a room or the whole home),
// what (lights, AC, blinds, doors and gates; all of them or chosen ones) and what to do. "Copy the
// house as it is now" makes the actions from the current state; "Try it now" runs them unsaved.

import { emptyState, skeletonCards, slider } from "../components.js";
import { h, iconButton, name } from "../dom.js";
import { formatNumber, formatTemperature, t } from "../i18n.js";
import { icon } from "../icons.js";
import { blindStateLabel, deviceRoomId, fanLabel, modeLabel, roomById, roomName, shownBrightness } from "../model.js";
import {
  SCENE_ICONS,
  STEP_ICONS,
  STEP_TYPES,
  copyHouse,
  devicesOfType,
  findScene,
  loadScenes,
  resultText,
  runScene,
  sceneSummary,
  stepAction,
  stepWhat,
  stepWhere,
} from "../scenes.js";
import { api, errorText, noteForbidden, refreshDevices, roleLabel } from "../session.js";
import { can, notify, state, ui } from "../state.js";
import { isLoading, notReadyState, offlineBanner, pageHeader, staleBanner } from "./common.js";

const MAX_STEPS = 40;
const MESSAGE_MS = 6000;
const MODE_ORDER = ["off", "cool", "heat", "auto"];

function notice(message) {
  return message ? h("p", { class: `notice notice-${message.kind}`, role: message.kind === "error" ? "alert" : "status" }, message.text) : null;
}

// A message on the scenes list (saved, deleted) that goes away by itself.
function flash(text) {
  const stamp = Date.now();
  ui.scenesMessage = { kind: "success", text, stamp };
  window.setTimeout(() => {
    if (ui.scenesMessage?.stamp === stamp) {
      ui.scenesMessage = null;
      notify();
    }
  }, MESSAGE_MS);
}

function waiting(header) {
  return [header, h("div", { class: "scene-list", "aria-busy": "true" }, skeletonCards(3)), h("p", { class: "visually-hidden", role: "status" }, t("common.loading"))];
}

// ---- the list ------------------------------------------------------------------------------

export function scenesView({ navigate }) {
  const header = pageHeader({ title: t("scenes.title") });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (isLoading() || state.scenes === null) return waiting(header);
  if (state.scenesUnsupported) return [header, emptyState("scene", t("scenes.title"), t("scenes.updateDriver"))];
  const admin = can("admin");
  const scenes = state.scenes;
  return [
    header,
    offlineBanner(),
    staleBanner(),
    notice(ui.scenesMessage),
    h("p", { class: "muted-note scene-intro" }, admin ? t("scenes.helpAdmin") : t("scenes.help")),
    can("member") ? null : h("p", { class: "notice notice-info" }, t("scenes.viewOnly", { role: roleLabel(state.role) })),
    scenes.length
      ? h("ul", { class: "scene-list" }, scenes.map((scene) => h("li", {}, sceneCard(scene, admin))))
      : emptyState("scene", t("scenes.emptyTitle"), admin ? t("scenes.emptyText") : t("scenes.emptyTextMember")),
    admin ? newScene(navigate, scenes.length) : null,
  ];
}

function runButton(scene) {
  const run = ui.sceneRuns[scene.id];
  const ran = run && run.stage !== "running" && run.stage !== "error";
  return h(
    "button",
    {
      type: "button",
      class: `button ${ran ? "button-secondary" : "button-primary"} scene-run`,
      title: t("scenes.runLabel", { name: scene.name }),
      disabled: run?.stage === "running",
      dataset: { key: `scene-run:${scene.id}` },
      onclick: () => runScene(scene),
    },
    icon(ran ? "check" : "play"),
    run?.stage === "running" ? t("scenes.running") : ran ? t("scenes.result.short") : t("scenes.run")
  );
}

function sceneCard(scene, admin) {
  const run = ui.sceneRuns[scene.id];
  return h(
    "div",
    { class: `card scene-card ${run ? `is-${run.stage}` : ""}` },
    h("span", { class: "scene-icon", "aria-hidden": "true" }, icon(scene.icon || "bulb")),
    h(
      "div",
      { class: "scene-text" },
      admin
        ? h("a", { class: "scene-name", href: `#/scene/${scene.id}`, dir: "auto", title: t("scenes.editLabel", { name: scene.name }), dataset: { key: `scene-edit:${scene.id}` } }, scene.name)
        : name(scene.name, "span", "scene-name"),
      h("span", { class: "scene-summary", dir: "auto" }, sceneSummary(scene)),
      // A plain "Done" is on the button already.
      run?.text && run.stage !== "done" ? h("span", { class: `scene-result scene-result-${run.stage}`, role: "status" }, run.text) : null
    ),
    can("member") ? runButton(scene) : null
  );
}

// Ready-made starting points: they open the editor filled in, nothing is saved until Save.
function sceneIdeas() {
  const has = { lights: state.lights.length > 0, climate: state.thermostats.length > 0, blinds: state.blinds.length > 0 };
  const step = (type, set) => has[type] && { type, room_id: null, device_ids: null, set };
  return [
    { id: "allOff", icon: "home", steps: [step("lights", { on: false }), step("climate", { mode: "off" })] },
    { id: "goodNight", icon: "moon", steps: [step("lights", { on: false }), step("blinds", { position: 0 })] },
    { id: "goodMorning", icon: "sun", steps: [step("blinds", { position: 100 })] },
    { id: "leaving", icon: "leave", steps: [step("lights", { on: false }), step("climate", { mode: "off" }), step("blinds", { position: 0 })] },
    { id: "cool", icon: "climate", steps: [step("climate", { mode: "cool", target_temperature: 24 })] },
  ]
    .map((idea) => ({ ...idea, steps: idea.steps.filter(Boolean) }))
    .filter((idea) => idea.steps.length);
}

function newScene(navigate, count) {
  const ideas = sceneIdeas();
  const full = count >= 50;
  return h(
    "section",
    { class: "home-section scene-new" },
    full
      ? h("p", { class: "notice notice-info" }, t("scenes.editor.limit"))
      : h(
          "a",
          { class: "button button-primary", href: "#/scene/new", dataset: { key: "scene-new" }, onclick: () => { ui.sceneIdea = null; } },
          icon("plus"),
          t("scenes.newScene")
        ),
    !full && ideas.length
      ? [
          h("h2", { class: "section-title" }, t("scenes.ideas")),
          h(
            "div",
            { class: "chip-row" },
            ideas.map((idea) =>
              h(
                "button",
                {
                  type: "button",
                  class: "chip",
                  dataset: { key: `scene-idea:${idea.id}` },
                  onclick: () => {
                    ui.sceneIdea = idea;
                    navigate("#/scene/new");
                  },
                },
                t(`scenes.idea.${idea.id}`)
              )
            )
          ),
        ]
      : null
  );
}

// ---- the editor ----------------------------------------------------------------------------

// Opening the editor starts from the saved scene (or an idea) again.
export function resetSceneEditor() {
  ui.sceneEditor = null;
}

function draftFor(key) {
  if (ui.sceneEditor?.key === key) return ui.sceneEditor;
  const base = { key, adding: null, busy: false, message: null };
  if (key === "new") {
    const idea = ui.sceneIdea;
    ui.sceneIdea = null;
    ui.sceneEditor = {
      ...base,
      id: null,
      version: null,
      name: idea ? t(`scenes.idea.${idea.id}`) : "",
      icon: idea?.icon || "bulb",
      show_on_home: false,
      steps: idea ? idea.steps : [],
    };
    return ui.sceneEditor;
  }
  const scene = findScene(key);
  if (!scene) return null;
  ui.sceneEditor = {
    ...base,
    id: scene.id,
    version: scene.version,
    name: scene.name,
    icon: scene.icon || "bulb",
    show_on_home: Boolean(scene.show_on_home),
    steps: JSON.parse(JSON.stringify(scene.steps || [])),
  };
  return ui.sceneEditor;
}

export function sceneEditorView(key, { navigate }) {
  const title = key === "new" ? t("scenes.editor.newTitle") : t("scenes.editor.editTitle");
  const header = pageHeader({ title, back: "#/scenes" });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (isLoading() || state.scenes === null) return waiting(header);
  if (state.scenesUnsupported) return [header, emptyState("scene", title, t("scenes.updateDriver"))];
  if (!can("admin")) return [header, h("p", { class: "notice notice-info" }, t("scenes.editor.adminOnly", { role: roleLabel(state.role) }))];
  const draft = draftFor(key);
  if (!draft) {
    return [header, emptyState("scene", t("scenes.editor.notFound"), "", h("a", { class: "button button-primary", href: "#/scenes" }, t("scenes.title")))];
  }
  if (draft.adding) return addActionView(draft);
  return [
    header,
    offlineBanner(),
    staleBanner(),
    h(
      "div",
      { class: "scene-editor" },
      nameSection(draft),
      stepsSection(draft),
      copySection(draft),
      homeToggle(draft),
      notice(draft.message),
      editorActions(draft, navigate)
    ),
  ];
}

function nameSection(draft) {
  return h(
    "section",
    { class: "card scene-section" },
    h(
      "div",
      { class: "field" },
      h("label", { class: "field-label", for: "scene-name" }, t("scenes.editor.name")),
      h("input", {
        id: "scene-name",
        type: "text",
        maxlength: "64",
        value: draft.name,
        placeholder: t("scenes.editor.namePlaceholder"),
        dir: "auto",
        autocomplete: "off",
        dataset: { key: "scene-name" },
        oninput: (event) => {
          draft.name = event.target.value;
        },
      })
    ),
    h(
      "div",
      { class: "scene-icons", role: "group", "aria-label": t("scenes.editor.icon") },
      SCENE_ICONS.map((iconName) =>
        h(
          "button",
          {
            type: "button",
            class: `scene-icon-choice ${draft.icon === iconName ? "is-active" : ""}`,
            "aria-pressed": String(draft.icon === iconName),
            "aria-label": t(`scenes.editor.icons.${iconName}`),
            title: t(`scenes.editor.icons.${iconName}`),
            dataset: { key: `scene-icon:${iconName}` },
            onclick: () => {
              draft.icon = iconName;
              notify();
            },
          },
          icon(iconName)
        )
      )
    )
  );
}

function stepsSection(draft) {
  const count = draft.steps.length;
  return h(
    "section",
    { class: "card scene-section" },
    h(
      "div",
      { class: "section-head" },
      h("h2", { class: "section-title" }, t("scenes.editor.steps")),
      h("span", { class: "muted-note" }, t("scenes.editor.count", { count }))
    ),
    count ? h("ol", { class: "step-list" }, draft.steps.map((step, index) => stepRow(draft, step, index))) : null,
    h(
      "button",
      {
        type: "button",
        class: "button button-secondary button-wide",
        disabled: count >= MAX_STEPS,
        dataset: { key: "scene-add" },
        onclick: () => {
          draft.adding = newAdding();
          draft.message = null;
          notify();
          window.scrollTo(0, 0);
        },
      },
      icon("plus"),
      t("scenes.editor.add")
    )
  );
}

function stepRow(draft, step, index) {
  const what = stepWhat(step);
  const move = (offset) => {
    const steps = [...draft.steps];
    [steps[index], steps[index + offset]] = [steps[index + offset], steps[index]];
    draft.steps = steps;
    notify();
  };
  const where = stepWhere(step);
  return h(
    "li",
    { class: "step-row" },
    h("span", { class: `step-icon step-${step.type}`, "aria-hidden": "true" }, icon(STEP_ICONS[step.type])),
    h(
      "span",
      { class: "step-text" },
      name(what, "span", "step-what"),
      h("span", { class: "step-where" }, name(where, "span"), step.type === "relays" ? h("span", {}, ` · ${t("scenes.editor.needsDoors")}`) : null)
    ),
    h("span", { class: "step-action" }, stepAction(step)),
    h(
      "span",
      { class: "step-tools" },
      iconButton("arrowUp", t("scenes.editor.moveUp", { what }), { disabled: index === 0, dataset: { key: `step-up:${index}` }, onclick: () => move(-1) }),
      iconButton("arrowDown", t("scenes.editor.moveDown", { what }), { disabled: index === draft.steps.length - 1, dataset: { key: `step-down:${index}` }, onclick: () => move(1) }),
      iconButton("close", t("scenes.editor.remove", { what }), {
        class: "danger",
        dataset: { key: `step-remove:${index}` },
        onclick: () => {
          draft.steps = draft.steps.filter((_, other) => other !== index);
          notify();
        },
      })
    )
  );
}

function copySection(draft) {
  return h(
    "section",
    { class: "scene-copy" },
    h("p", { class: "field-help" }, t("scenes.editor.copyHelp")),
    h(
      "button",
      {
        type: "button",
        class: "button button-secondary",
        dataset: { key: "scene-copy" },
        onclick: () => {
          if (draft.steps.length && !window.confirm(t("scenes.editor.copyConfirm", { count: draft.steps.length }))) return;
          draft.steps = copyHouse();
          draft.message = { kind: draft.steps.length ? "success" : "info", text: t("scenes.editor.copied", { count: draft.steps.length }) };
          notify();
        },
      },
      icon("copy"),
      t("scenes.editor.copy")
    )
  );
}

function homeToggle(draft) {
  return h(
    "div",
    { class: "card scene-section toggle-row" },
    h(
      "span",
      { class: "toggle-text" },
      h("span", { class: "toggle-title", id: "scene-home-label" }, t("scenes.editor.showOnHome")),
      h("span", { class: "field-help" }, t("scenes.editor.showOnHomeHelp"))
    ),
    h(
      "button",
      {
        type: "button",
        role: "switch",
        class: "switch",
        "aria-checked": String(draft.show_on_home),
        "aria-labelledby": "scene-home-label",
        dataset: { key: "scene-home" },
        onclick: () => {
          draft.show_on_home = !draft.show_on_home;
          notify();
        },
      },
      h("span", { class: "switch-thumb" })
    )
  );
}

function editorActions(draft, navigate) {
  return h(
    "div",
    { class: "scene-actions" },
    h(
      "button",
      { type: "button", class: "button button-secondary", disabled: draft.busy || !draft.steps.length, dataset: { key: "scene-try" }, onclick: () => tryDraft(draft) },
      icon("play"),
      t("scenes.editor.try")
    ),
    h(
      "button",
      { type: "button", class: "button button-primary", disabled: draft.busy, dataset: { key: "scene-save" }, onclick: () => saveDraft(draft, navigate) },
      icon("check"),
      draft.busy ? t("common.saving") : t("scenes.editor.save")
    ),
    draft.id
      ? h(
          "button",
          { type: "button", class: "button button-danger", disabled: draft.busy, dataset: { key: "scene-delete" }, onclick: () => deleteDraft(draft, navigate) },
          t("scenes.editor.delete")
        )
      : null
  );
}

async function tryDraft(draft) {
  draft.busy = true;
  draft.message = null;
  notify();
  try {
    const result = await api("/v1/scenes/try", { method: "POST", body: { steps: draft.steps } });
    draft.message = {
      kind: result.failed ? "error" : result.skipped ? "info" : "success",
      text: result.failed || result.skipped ? resultText(result) : t("scenes.editor.tried"),
    };
    window.setTimeout(() => refreshDevices(), 1500);
  } catch (error) {
    noteForbidden(error);
    draft.message = { kind: "error", text: errorText(error) };
  }
  draft.busy = false;
  notify();
}

async function saveDraft(draft, navigate) {
  const sceneName = draft.name.trim();
  const problem = !sceneName ? "needName" : !draft.steps.length ? "needSteps" : null;
  if (problem) {
    draft.message = { kind: "error", text: t(`scenes.editor.${problem}`) };
    notify();
    if (problem === "needName") document.querySelector("#scene-name")?.focus();
    return;
  }
  draft.busy = true;
  draft.message = null;
  notify();
  const body = { name: sceneName.slice(0, 64), icon: draft.icon, show_on_home: draft.show_on_home, steps: draft.steps };
  try {
    if (draft.id) await api(`/v1/scenes/${draft.id}`, { method: "PATCH", body: { ...body, version: draft.version } });
    else await api("/v1/scenes", { method: "POST", body });
    draft.busy = false;
    flash(t("scenes.saved", { name: sceneName }));
    await loadScenes();
    navigate("#/scenes");
    return;
  } catch (error) {
    noteForbidden(error);
    const codes = { VERSION_CONFLICT: "conflict", SCENE_LIMIT_REACHED: "limit" };
    draft.message = { kind: "error", text: codes[error?.code] ? t(`scenes.editor.${codes[error.code]}`) : errorText(error) };
  }
  draft.busy = false;
  notify();
}

async function deleteDraft(draft, navigate) {
  if (draft.busy || !window.confirm(t("scenes.editor.deleteConfirm", { name: draft.name }))) return;
  draft.busy = true;
  notify();
  try {
    await api(`/v1/scenes/${draft.id}`, { method: "DELETE" });
  } catch (error) {
    // Already deleted on another device: the same outcome.
    if (error?.status !== 404) {
      noteForbidden(error);
      draft.busy = false;
      draft.message = { kind: "error", text: errorText(error) };
      notify();
      return;
    }
  }
  draft.busy = false;
  flash(t("scenes.deleted", { name: draft.name }));
  await loadScenes();
  navigate("#/scenes");
}

// ---- adding an action ----------------------------------------------------------------------

function newAdding() {
  return { room: null, type: null, choose: false, picked: [], light: "off", brightness: 50, mode: null, temperature: 24, fan: null, blind: "close", position: 50, relay: "close" };
}

// Devices of `type` in `room` (null: the whole home).
function scopeDevices(type, room) {
  return devicesOfType(type).filter((device) => room == null || deviceRoomId(device) === room);
}

function roomsWithDevices() {
  return state.rooms.filter((room) => STEP_TYPES.some((type) => scopeDevices(type, room.id).length));
}

function choiceChip(label, active, key, onclick) {
  return h("button", { type: "button", class: `chip ${active ? "is-active" : ""}`, "aria-pressed": String(active), dataset: { key }, onclick }, name(label, "span"));
}

function segments(options, value, key, onPick) {
  return h(
    "div",
    { class: "segments", role: "group", style: { "grid-template-columns": `repeat(${options.length}, minmax(0, 1fr))` } },
    options.map(([option, label]) =>
      h(
        "button",
        {
          type: "button",
          class: `segment ${value === option ? "is-active" : ""}`,
          "aria-pressed": String(value === option),
          dataset: { key: `${key}:${option}` },
          onclick: () => {
            onPick(option);
            notify();
          },
        },
        label
      )
    )
  );
}

function addSection(title, ...content) {
  return h("section", { class: "card scene-section" }, h("h2", { class: "add-title" }, title), ...content);
}

function unique(values) {
  return [...new Set(values)];
}

// The step the choices describe, or null while chosen devices are wanted and none is picked.
function buildStep(adding, devices) {
  const picked = devices.filter((device) => adding.picked.includes(device.id)).map((device) => device.id);
  if (adding.choose && !picked.length) return null;
  let set;
  if (adding.type === "lights") set = adding.light === "off" ? { on: false } : adding.light === "on" ? { on: true } : { brightness: adding.brightness };
  else if (adding.type === "climate") {
    set = adding.mode === "off" ? { mode: "off" } : { mode: adding.mode, target_temperature: adding.temperature };
    if (adding.mode !== "off" && adding.fan) set.fan_speed = adding.fan;
  } else if (adding.type === "blinds") set = { position: adding.blind === "open" ? 100 : adding.blind === "close" ? 0 : adding.position };
  else set = { state: adding.relay === "open" ? "open" : "closed" };
  return { type: adding.type, room_id: adding.room, device_ids: adding.choose ? picked : null, set };
}

function nowText(type, device) {
  if (type === "lights") return device.on ? (device.dimmable ? t("lights.level", { percent: shownBrightness(device) }) : t("lights.on")) : t("lights.off");
  if (type === "climate") return [modeLabel(device.mode), Number.isFinite(device.target_temperature) && device.mode !== "off" ? formatTemperature(device.target_temperature) : null].filter(Boolean).join(" ");
  if (type === "blinds") return blindStateLabel(device);
  return "";
}

function whichDevices(adding, devices, where) {
  if (devices.length < 2) return null;
  const kind = t(`scenes.add.kinds.${adding.type}`);
  if (!adding.choose) {
    return h(
      "div",
      { class: "which-row" },
      h("span", {}, h("span", { class: "which-label" }, t("scenes.add.which", { kind })), " ", h("span", { dir: "auto" }, t("scenes.add.allIn", { count: devices.length, where }))),
      h(
        "button",
        {
          type: "button",
          class: "button button-secondary button-small",
          dataset: { key: "add-choose" },
          onclick: () => {
            adding.choose = true;
            adding.picked = [];
            notify();
          },
        },
        t("scenes.add.choose")
      )
    );
  }
  const all = devices.every((device) => adding.picked.includes(device.id));
  return h(
    "div",
    { class: "pick-panel" },
    h(
      "div",
      { class: "which-row" },
      h("span", {}, t("scenes.add.picked", { picked: adding.picked.filter((id) => devices.some((device) => device.id === id)).length, count: devices.length })),
      h(
        "button",
        {
          type: "button",
          class: "button button-quiet button-small",
          dataset: { key: "add-pick-all" },
          onclick: () => {
            adding.picked = all ? [] : devices.map((device) => device.id);
            notify();
          },
        },
        all ? t("scenes.add.pickNone") : t("scenes.add.pickAll", { count: devices.length })
      )
    ),
    h(
      "ul",
      { class: "pick-list" },
      devices.map((device) => {
        const id = `pick-${device.id}`;
        const meta = [adding.room == null ? roomName(device.room) : null, nowText(adding.type, device)].filter(Boolean).join(" · ");
        return h(
          "li",
          { class: "pick-item" },
          h("input", {
            type: "checkbox",
            id,
            checked: adding.picked.includes(device.id),
            dataset: { key: `pick:${device.id}` },
            onchange: (event) => {
              adding.picked = event.target.checked ? [...adding.picked, device.id] : adding.picked.filter((other) => other !== device.id);
              notify();
            },
          }),
          h("label", { for: id, class: "pick-label" }, name(device.name, "span", "device-name"), meta ? h("span", { class: "device-meta", dir: "auto" }, meta) : null)
        );
      })
    ),
    h("p", { class: "field-help" }, t("scenes.add.pickHelp")),
    h(
      "button",
      {
        type: "button",
        class: "button button-quiet button-small",
        dataset: { key: "add-use-all" },
        onclick: () => {
          adding.choose = false;
          adding.picked = [];
          notify();
        },
      },
      t("scenes.add.useAll", { count: devices.length })
    )
  );
}

// What the AC choices offer for these thermostats: their modes, temperature range and fan speeds.
function climateChoices(devices) {
  const offered = unique(devices.flatMap((device) => device.modes || []));
  return {
    modes: MODE_ORDER.filter((mode) => mode === "off" || offered.includes(mode)),
    min: Math.min(...devices.map((device) => (Number.isFinite(device.target_temperature_min) ? device.target_temperature_min : 16))),
    max: Math.max(...devices.map((device) => (Number.isFinite(device.target_temperature_max) ? device.target_temperature_max : 32))),
    fans: unique(devices.flatMap((device) => device.fan_speeds || [])),
  };
}

// Keeps the choices possible for the devices picked now (e.g. no Dim for on/off lights), before
// the step is built from them.
function settle(adding, devices) {
  if (adding.type === "lights" && adding.light === "dim" && !devices.some((device) => device.dimmable)) adding.light = "on";
  if (adding.type === "climate" && devices.length) {
    const { modes, min, max, fans } = climateChoices(devices);
    if (!modes.includes(adding.mode)) adding.mode = modes.includes("cool") ? "cool" : modes[modes.length - 1];
    adding.temperature = Math.min(max, Math.max(min, adding.temperature));
    if (!fans.includes(adding.fan)) adding.fan = null;
  }
}

function doControls(adding, devices) {
  if (adding.type === "lights") {
    const dimmable = devices.some((device) => device.dimmable);
    return [
      segments([["off", t("scenes.do.off")], ["on", t("scenes.do.on")], ...(dimmable ? [["dim", t("scenes.add.dim")]] : [])], adding.light, "add-light", (value) => {
        adding.light = value;
      }),
      adding.light === "dim"
        ? slider({
            label: t("scenes.add.brightness"),
            value: adding.brightness,
            min: 1,
            max: 100,
            key: "add-brightness",
            format: (value) => t("common.percent", { percent: value }),
            onCommit: (value) => {
              adding.brightness = value;
              notify();
            },
          })
        : null,
    ];
  }
  if (adding.type === "climate") {
    const { modes, min, max, fans } = climateChoices(devices);
    const parts = [segments(modes.map((mode) => [mode, modeLabel(mode)]), adding.mode, "add-mode", (value) => { adding.mode = value; })];
    if (adding.mode !== "off") {
      const nudge = (delta) => {
        adding.temperature = Math.min(max, Math.max(min, adding.temperature + delta));
        notify();
      };
      parts.push(
        h(
          "div",
          { class: "stepper", role: "group", "aria-label": t("scenes.add.temperature") },
          iconButton("minus", t("climate.lower"), { class: "stepper-button", disabled: adding.temperature <= min, dataset: { key: "add-temp-down" }, onclick: () => nudge(-1) }),
          h(
            "div",
            { class: "stepper-value" },
            h("output", { class: "stepper-number", "aria-live": "polite" }, formatTemperature(adding.temperature)),
            h("span", { class: "stepper-label" }, t("climate.targetShort"))
          ),
          iconButton("plus", t("climate.raise"), { class: "stepper-button", disabled: adding.temperature >= max, dataset: { key: "add-temp-up" }, onclick: () => nudge(1) })
        )
      );
      if (fans.length) {
        parts.push(
          h(
            "div",
            { class: "chip-row", role: "group", "aria-label": t("climate.fan") },
            h("span", { class: "chip-row-label" }, icon("fan"), t("climate.fan")),
            [null, ...fans].map((speed) =>
              choiceChip(speed ? fanLabel(speed) : t("scenes.add.fanKeep"), adding.fan === speed, `add-fan:${speed || "keep"}`, () => {
                adding.fan = speed;
                notify();
              })
            )
          )
        );
      }
    }
    return parts;
  }
  if (adding.type === "blinds") {
    return [
      segments([["open", t("scenes.do.open")], ["close", t("scenes.do.close")], ["set", t("scenes.add.position")]], adding.blind, "add-blind", (value) => {
        adding.blind = value;
      }),
      adding.blind === "set"
        ? slider({
            label: t("scenes.add.position"),
            value: adding.position,
            min: 1,
            max: 99,
            key: "add-position",
            format: (value) => t("blinds.percentOpen", { percent: value }),
            onCommit: (value) => {
              adding.position = value;
              notify();
            },
          })
        : null,
    ];
  }
  return [
    segments([["open", t("scenes.do.open")], ["close", t("scenes.do.close")]], adding.relay, "add-relay", (value) => {
      adding.relay = value;
    }),
    h("p", { class: "notice notice-info" }, t("scenes.add.doorsNote")),
  ];
}

function addActionView(draft) {
  const adding = draft.adding;
  const available = STEP_TYPES.filter((type) => scopeDevices(type, adding.room).length);
  if (!available.includes(adding.type)) {
    adding.type = available[0] || null;
    adding.choose = false;
    adding.picked = [];
  }
  const where = adding.room == null ? t("scenes.wholeHome") : roomName(roomById(adding.room));
  const devices = adding.type ? scopeDevices(adding.type, adding.room) : [];
  const targets = adding.choose ? devices.filter((device) => adding.picked.includes(device.id)) : devices;
  settle(adding, targets.length ? targets : devices);
  const step = adding.type ? buildStep(adding, devices) : null;
  const pickRoom = (id) => () => {
    adding.room = id;
    adding.choose = false;
    adding.picked = [];
    notify();
  };
  return [
    pageHeader({ title: t("scenes.add.title") }),
    h(
      "div",
      { class: "scene-editor" },
      addSection(
        t("scenes.add.where"),
        h(
          "div",
          { class: "chip-row" },
          choiceChip(t("scenes.wholeHome"), adding.room == null, "add-room:home", pickRoom(null)),
          roomsWithDevices().map((room) => choiceChip(roomName(room), adding.room === room.id, `add-room:${room.id}`, pickRoom(room.id)))
        )
      ),
      available.length
        ? addSection(
            t("scenes.add.what"),
            h(
              "div",
              { class: "kind-grid" },
              available.map((type) =>
                h(
                  "button",
                  {
                    type: "button",
                    class: `kind-choice ${adding.type === type ? "is-active" : ""}`,
                    "aria-pressed": String(adding.type === type),
                    dataset: { key: `add-kind:${type}` },
                    onclick: () => {
                      adding.type = type;
                      adding.choose = false;
                      adding.picked = [];
                      notify();
                    },
                  },
                  icon(STEP_ICONS[type]),
                  h("span", { class: "kind-name" }, t(`scenes.add.kinds.${type}`)),
                  h("span", { class: "kind-count" }, formatNumber(scopeDevices(type, adding.room).length))
                )
              )
            ),
            whichDevices(adding, devices, where)
          )
        : h("p", { class: "muted-note" }, t("scenes.add.nothingHere")),
      adding.type ? addSection(t("scenes.add.do"), doControls(adding, targets.length ? targets : devices)) : null,
      h(
        "div",
        { class: "card scene-section add-foot" },
        h(
          "p",
          { class: "add-summary", role: "status", dir: "auto" },
          step ? t("scenes.add.adds", { summary: `${stepWhat(step)} (${stepWhere(step)}): ${stepAction(step)}` }) : t("scenes.add.pickOne")
        ),
        h(
          "div",
          { class: "scene-actions" },
          h(
            "button",
            {
              type: "button",
              class: "button button-secondary",
              dataset: { key: "add-cancel" },
              onclick: () => {
                draft.adding = null;
                notify();
              },
            },
            t("common.cancel")
          ),
          h(
            "button",
            {
              type: "button",
              class: "button button-primary",
              disabled: !step,
              dataset: { key: "add-confirm" },
              onclick: () => {
                // Built again from the choices as they are at the tap.
                settle(adding, targets.length ? targets : devices);
                const chosen = buildStep(adding, devices);
                if (!chosen) return;
                draft.steps = [...draft.steps, chosen];
                draft.adding = null;
                notify();
              },
            },
            icon("plus"),
            t("scenes.add.addButton")
          )
        )
      )
    ),
  ];
}
