// Building blocks shared by the screens: device controls, tiles, empty and loading states.

import { attachCameraImages } from "./camera-feed.js";
import {
  cancelRelay,
  nudgeTarget,
  pressRelay,
  setBlind,
  setLight,
  setThermostat,
  stopBlind,
} from "./controls.js";
import { h, iconButton, name } from "./dom.js";
import { isFavorite, toggleFavorite } from "./favorites.js";
import { formatTemperature, t } from "./i18n.js";
import { icon } from "./icons.js";
import { blindStateLabel, climateIsOn, fanLabel, labelOr, modeLabel, roomName, shownBrightness } from "./model.js";
import { can, deviceKey, notify, state, ui } from "./state.js";

// ---- generic -------------------------------------------------------------------------------

export function inlineError(key) {
  const error = state.errors[key];
  return error ? h("p", { class: "inline-error", role: "alert" }, error.text) : null;
}

export function emptyState(iconName, title, text, action) {
  return h(
    "div",
    { class: "empty" },
    h("span", { class: "empty-icon" }, icon(iconName)),
    h("h2", { class: "empty-title" }, title),
    text ? h("p", { class: "empty-text" }, text) : null,
    action || null
  );
}

export function skeletonCards(count, className = "skeleton-card") {
  return Array.from({ length: count }, () => h("div", { class: `skeleton ${className}`, "aria-hidden": "true" }));
}

export function sectionTitle(iconName, text, extra) {
  return h("div", { class: "section-head" }, h("h2", { class: "section-title" }, icon(iconName), text), extra || null);
}

export function favoriteStar(kind, device) {
  const on = isFavorite(kind, device.id);
  return h(
    "button",
    {
      type: "button",
      class: `icon-button star ${on ? "is-favorite" : ""}`,
      "aria-pressed": String(on),
      "aria-label": t(on ? "favorites.remove" : "favorites.add", { name: device.name }),
      title: t(on ? "favorites.remove" : "favorites.add", { name: device.name }),
      dataset: { key: `${kind}:${device.id}:star` },
      onclick: () => {
        toggleFavorite(kind, device.id);
        ui.tick += 1;
        notify();
      },
    },
    icon("star")
  );
}

// Range input with a visible value. The screen is not redrawn while the thumb is held.
export function slider({ label, value, min = 0, max = 100, step = 1, key, format, onCommit, disabled }) {
  const output = h("output", { class: "slider-value" }, format(value));
  const input = h("input", {
    type: "range",
    class: "slider",
    min: String(min),
    max: String(max),
    step: String(step),
    value: String(value),
    "aria-label": label,
    "aria-valuetext": format(value),
    disabled: Boolean(disabled),
    dataset: { key },
  });
  const fill = () => input.style.setProperty("--fill", `${((Number(input.value) - min) / (max - min)) * 100}%`);
  fill();
  input.addEventListener("input", () => {
    output.textContent = format(Number(input.value));
    input.setAttribute("aria-valuetext", format(Number(input.value)));
    fill();
  });
  input.addEventListener("pointerdown", () => {
    ui.dragging = true;
  });
  input.addEventListener("change", () => {
    ui.dragging = false;
    onCommit(Number(input.value));
  });
  return h("div", { class: "slider-row" }, input, output);
}

window.addEventListener("pointerup", () => {
  if (ui.dragging) {
    ui.dragging = false;
    notify();
  }
});
window.addEventListener("pointercancel", () => {
  ui.dragging = false;
});

function chip(label, { pressed, key, onclick, disabled }) {
  return h(
    "button",
    {
      type: "button",
      class: `chip ${pressed ? "is-active" : ""}`,
      "aria-pressed": String(Boolean(pressed)),
      dataset: { key },
      disabled: Boolean(disabled),
      onclick,
    },
    label
  );
}

// ---- lights --------------------------------------------------------------------------------

export function lightSwitch(light) {
  const label = t("lights.toggle", { name: light.name });
  return h(
    "button",
    {
      type: "button",
      role: "switch",
      class: "switch",
      "aria-checked": String(Boolean(light.on)),
      "aria-label": label,
      dataset: { key: `light:${light.id}:switch` },
      onclick: () => setLight(light, { on: !light.on }),
    },
    h("span", { class: "switch-thumb" })
  );
}

function lightStatus(light) {
  if (!light.on) return t("lights.off");
  if (!light.dimmable) return t("lights.on");
  const level = t("lights.level", { percent: shownBrightness(light) });
  return light.brightness_reported ? level : `${level} · ${t("lights.levelNotReported")}`;
}

export function lightRow(light, { showRoom = false } = {}) {
  const key = deviceKey("light", light.id);
  return h(
    "div",
    { class: `device light ${light.on ? "is-on" : ""}` },
    h(
      "div",
      { class: "device-main" },
      h("span", { class: "device-icon" }, icon("bulb")),
      h(
        "div",
        { class: "device-text" },
        name(light.name, "span", "device-name"),
        h("span", { class: "device-meta" }, showRoom ? [name(roomName(light.room)), " · "] : null, lightStatus(light))
      ),
      favoriteStar("light", light),
      // View-only keys (role viewer) see the state without controls.
      can("member") ? lightSwitch(light) : null
    ),
    light.dimmable && can("member")
      ? slider({
          label: t("lights.brightness", { name: light.name }),
          value: shownBrightness(light),
          key: `light:${light.id}:level`,
          format: (value) => t("common.percent", { percent: value }),
          onCommit: (value) => setLight(light, { brightness: value }),
        })
      : null,
    inlineError(key)
  );
}

// ---- climate -------------------------------------------------------------------------------

function climateStatus(thermostat) {
  const parts = [];
  if (!thermostat.online) parts.push(t("climate.offline"));
  if (Number.isFinite(thermostat.current_temperature)) {
    parts.push(t("climate.now", { temperature: formatTemperature(thermostat.current_temperature) }));
  }
  if (thermostat.activity && thermostat.activity !== "idle") {
    parts.push(labelOr(`climate.activity.${thermostat.activity}`, thermostat.activity));
  }
  return parts.join(" · ");
}

export function thermostatCard(thermostat, { showRoom = false } = {}) {
  const key = deviceKey("thermostat", thermostat.id);
  const target = thermostat.target_temperature;
  const min = thermostat.target_temperature_min;
  const max = thermostat.target_temperature_max;
  const active = climateIsOn(thermostat);
  const controls = can("member");
  const modes = controls ? thermostat.modes || [] : [];
  const fans = controls ? thermostat.fan_speeds || [] : [];
  const fanNote = !controls && thermostat.fan_speed ? ` · ${t("climate.fan")} ${fanLabel(thermostat.fan_speed)}` : "";
  return h(
    "div",
    { class: `device climate ${active ? "is-cool" : ""}` },
    h(
      "div",
      { class: "device-main" },
      h("span", { class: "device-icon" }, icon("climate")),
      h(
        "div",
        { class: "device-text" },
        name(thermostat.name, "span", "device-name"),
        h(
          "span",
          { class: "device-meta" },
          showRoom ? [name(roomName(thermostat.room)), " · "] : null,
          modeLabel(thermostat.mode),
          climateStatus(thermostat) ? ` · ${climateStatus(thermostat)}` : "",
          fanNote
        )
      ),
      favoriteStar("thermostat", thermostat)
    ),
    !controls
      ? h(
          "div",
          { class: "stepper stepper-readonly" },
          h(
            "div",
            { class: "stepper-value" },
            h("span", { class: "stepper-number" }, formatTemperature(target)),
            h("span", { class: "stepper-label" }, t("climate.targetShort"))
          )
        )
      : h(
      "div",
      { class: "stepper", role: "group", "aria-label": t("climate.target", { name: thermostat.name }) },
      iconButton("minus", t("climate.lower"), {
        class: "stepper-button",
        dataset: { key: `thermostat:${thermostat.id}:down` },
        disabled: Number.isFinite(target) && target <= min,
        onclick: () => nudgeTarget(thermostat, -1),
      }),
      h(
        "div",
        { class: "stepper-value" },
        h("output", { class: "stepper-number", "aria-live": "polite" }, formatTemperature(target)),
        h("span", { class: "stepper-label" }, t("climate.targetShort"))
      ),
      iconButton("plus", t("climate.raise"), {
        class: "stepper-button",
        dataset: { key: `thermostat:${thermostat.id}:up` },
        disabled: Number.isFinite(target) && target >= max,
        onclick: () => nudgeTarget(thermostat, 1),
      })
    ),
    modes.length
      ? h(
          "div",
          { class: "chip-row", role: "group", "aria-label": t("climate.mode") },
          modes.map((mode) =>
            chip(modeLabel(mode), {
              pressed: thermostat.mode === mode,
              key: `thermostat:${thermostat.id}:mode:${mode}`,
              onclick: () => thermostat.mode !== mode && setThermostat(thermostat, { mode }),
            })
          )
        )
      : null,
    fans.length
      ? h(
          "div",
          { class: "chip-row chip-row-fan", role: "group", "aria-label": t("climate.fan") },
          h("span", { class: "chip-row-label" }, icon("fan"), t("climate.fan")),
          fans.map((speed) =>
            chip(fanLabel(speed), {
              pressed: thermostat.fan_speed === speed,
              key: `thermostat:${thermostat.id}:fan:${speed}`,
              onclick: () => thermostat.fan_speed !== speed && setThermostat(thermostat, { fan_speed: speed }),
            })
          )
        )
      : null,
    inlineError(key)
  );
}

// ---- blinds --------------------------------------------------------------------------------

export function blindRow(blind, { showRoom = false } = {}) {
  const key = deviceKey("blind", blind.id);
  const known = Number.isFinite(blind.position);
  const button = (label, iconName, action, keyName) =>
    h(
      "button",
      {
        type: "button",
        class: "segment",
        dataset: { key: `blind:${blind.id}:${keyName}` },
        onclick: action,
      },
      icon(iconName),
      h("span", {}, label)
    );
  return h(
    "div",
    { class: `device blind ${known && blind.position > 0 ? "is-open" : ""}` },
    h(
      "div",
      { class: "device-main" },
      h("span", { class: "device-icon" }, icon("blinds")),
      h(
        "div",
        { class: "device-text" },
        name(blind.name, "span", "device-name"),
        h("span", { class: "device-meta" }, showRoom ? [name(roomName(blind.room)), " · "] : null, blindStateLabel(blind))
      ),
      favoriteStar("blind", blind)
    ),
    can("member")
      ? h(
          "div",
          { class: "segments", role: "group", "aria-label": blind.name },
          button(t("blinds.close"), "arrowDown", () => setBlind(blind, 0), "close"),
          button(t("blinds.stop"), "stop", () => stopBlind(blind), "stop"),
          button(t("blinds.openAction"), "arrowUp", () => setBlind(blind, 100), "open")
        )
      : null,
    can("member")
      ? slider({
          label: t("blinds.position", { name: blind.name }),
          value: known ? blind.position : 0,
          key: `blind:${blind.id}:position`,
          format: (value) => t("blinds.percentOpen", { percent: value }),
          onCommit: (value) => setBlind(blind, value),
        })
      : null,
    inlineError(key)
  );
}

// ---- doors and gates -----------------------------------------------------------------------

function relayButtonLabel(relay) {
  const stage = ui.relayStage[relay.id];
  if (stage === "confirm") return t("relays.confirm");
  if (stage === "sending") return t("relays.opening");
  if (stage === "sent") return t("relays.sent");
  return t("relays.open");
}

// Opening doors and gates needs the doors role (or admin); null otherwise.
export function relayButton(relay, { compact = false } = {}) {
  if (!can("doors")) return null;
  const stage = ui.relayStage[relay.id] || "";
  return h(
    "button",
    {
      type: "button",
      class: `relay-button ${compact ? "relay-button-compact" : ""} ${stage ? `is-${stage}` : ""}`,
      "aria-label": `${relayButtonLabel(relay)} — ${relay.name}`,
      dataset: { key: `relay:${relay.id}:open` },
      disabled: stage === "sending",
      onclick: (event) => {
        event.stopPropagation();
        pressRelay(relay);
      },
    },
    icon(stage === "sent" ? "check" : "door"),
    h("span", {}, relayButtonLabel(relay))
  );
}

export function relayRow(relay, { showRoom = false } = {}) {
  const key = deviceKey("relay", relay.id);
  const confirming = ui.relayStage[relay.id] === "confirm";
  return h(
    "div",
    { class: "device relay" },
    h(
      "div",
      { class: "device-main" },
      h("span", { class: "device-icon" }, icon("door")),
      h(
        "div",
        { class: "device-text" },
        name(relay.name, "span", "device-name"),
        h(
          "span",
          { class: "device-meta" },
          showRoom ? [name(roomName(relay.room)), " · "] : null,
          !can("doors") ? t("relays.noAccess") : confirming ? t("relays.confirmHint") : t("relays.hint")
        )
      ),
      favoriteStar("relay", relay)
    ),
    can("doors")
      ? h(
      "div",
      { class: "relay-actions" },
      relayButton(relay),
      confirming
        ? h(
            "button",
            { type: "button", class: "button button-quiet", dataset: { key: `relay:${relay.id}:cancel` }, onclick: () => cancelRelay(relay) },
            t("common.cancel")
          )
        : null
    )
      : null,
    inlineError(key)
  );
}

// ---- cameras -------------------------------------------------------------------------------

// A camera picture. width: the snapshot size to request (320 thumbnails, 640 large).
export function cameraPicture(camera, width) {
  return h(
    "div",
    { class: "cam", dataset: { state: "loading" } },
    h("img", {
      alt: t("cameras.pictureOf", { name: camera.name }),
      dataset: { cameraId: String(camera.id), width: String(width) },
      decoding: "async",
    }),
    h("span", { class: "cam-placeholder cam-loading", "aria-hidden": "true" }),
    h("span", { class: "cam-placeholder cam-none" }, icon("noPicture"), h("span", {}, t("cameras.noPicture"))),
    h("span", { class: "cam-placeholder cam-busy" }, icon("refresh"), h("span", {}, t("cameras.busy")))
  );
}

export function cameraTile(camera, { width = 320, onOpen, showRoom = true, large = false } = {}) {
  return h(
    "div",
    { class: `camera-tile ${large ? "camera-tile-large" : ""}` },
    h(
      "button",
      {
        type: "button",
        class: "camera-open",
        "aria-label": t("cameras.open", { name: camera.name }),
        dataset: { key: `camera:${camera.id}:open${large ? ":large" : ""}` },
        onclick: () => onOpen(camera),
      },
      cameraPicture(camera, width),
      h(
        "span",
        { class: "camera-caption" },
        name(camera.name, "span", "camera-name"),
        showRoom && camera.room ? name(roomName(camera.room), "span", "camera-room") : null
      )
    ),
    favoriteStar("camera", camera)
  );
}

export { attachCameraImages };
