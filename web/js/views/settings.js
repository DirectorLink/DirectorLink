// Settings: appearance, language, room names, controller, app and about.

import { h, name } from "../dom.js";
import { LANGUAGES, formatTime, languagePreference, t } from "../i18n.js";
import { icon } from "../icons.js";
import { roomName } from "../model.js";
import { installApp } from "../pwa.js";
import { connect, errorText, requestAccess, revokeAndForget, roleLabel, saveRoomNames, useHost } from "../session.js";
import { PALETTES, THEMES, palettePreference, themePreference } from "../theme.js";
import { can, notify, state, ui } from "../state.js";
import { offlineBanner, pageHeader } from "./common.js";

export function settingsView({ onPalette, onTheme, onLanguage, navigate }) {
  return [
    pageHeader({ title: t("settings.title") }),
    offlineBanner(),
    h(
      "div",
      { class: "settings" },
      appearanceSection(onPalette, onTheme),
      languageSection(onLanguage),
      roomsSection(),
      controllerSection(navigate),
      appSection(),
      aboutSection()
    ),
  ];
}

function card(id, iconName, title, ...content) {
  return h(
    "section",
    { class: "card settings-card", id: `settings-${id}`, "aria-labelledby": `settings-${id}-title` },
    h("h2", { class: "settings-title", id: `settings-${id}-title` }, icon(iconName), title),
    ...content
  );
}

// A group of real radio buttons, drawn as segments or swatches.
function radioGroup({ legend, groupName, options, value, onChange, className = "segmented" }) {
  return h(
    "fieldset",
    { class: `radio-group ${className}` },
    h("legend", { class: "field-label" }, legend),
    h(
      "div",
      { class: "radio-options" },
      options.map((option) => {
        const id = `${groupName}-${option.value}`;
        return h(
          "div",
          { class: "radio-option" },
          h("input", {
            type: "radio",
            id,
            name: groupName,
            value: option.value,
            checked: option.value === value,
            dataset: { key: id },
            onchange: () => onChange(option.value),
          }),
          h("label", { for: id, lang: option.lang, dir: option.dir }, option.visual || null, h("span", { class: "radio-label" }, option.label))
        );
      })
    )
  );
}

function appearanceSection(onPalette, onTheme) {
  return card(
    "appearance",
    "palette",
    t("settings.appearance.title"),
    radioGroup({
      legend: t("settings.appearance.palette"),
      groupName: "palette",
      className: "swatches",
      value: palettePreference(),
      onChange: onPalette,
      options: PALETTES.map((palette) => ({
        value: palette,
        label: t(`palettes.${palette}`),
        visual: h(
          "span",
          { class: "swatch", dataset: { swatch: palette }, "aria-hidden": "true" },
          h("span", { class: "swatch-a" }),
          h("span", { class: "swatch-b" }),
          h("span", { class: "swatch-c" })
        ),
      })),
    }),
    radioGroup({
      legend: t("settings.appearance.theme"),
      groupName: "theme",
      value: themePreference(),
      onChange: onTheme,
      options: THEMES.map((theme) => ({
        value: theme,
        label: t(`settings.appearance.themes.${theme}`),
        visual: icon(theme === "light" ? "sun" : theme === "dark" ? "moon" : "auto"),
      })),
    }),
    h("p", { class: "field-help" }, t("settings.appearance.autoHelp"))
  );
}

function languageSection(onLanguage) {
  return card(
    "language",
    "globe",
    t("settings.language.title"),
    radioGroup({
      legend: t("settings.language.label"),
      groupName: "language",
      value: languagePreference(),
      onChange: onLanguage,
      options: [
        { value: "auto", label: t("settings.language.auto") },
        ...LANGUAGES.map((language) => ({ value: language.code, label: language.label, lang: language.code, dir: language.dir })),
      ],
    })
  );
}

// ---- rooms ---------------------------------------------------------------------------------

function roomsSection() {
  if (!state.loaded || !state.rooms.length) {
    return card("rooms", "rooms", t("settings.rooms.title"), h("p", { class: "muted-note" }, t("settings.rooms.connectFirst")));
  }
  return card(
    "rooms",
    "rooms",
    t("settings.rooms.title"),
    h("p", { class: "field-help" }, t("settings.rooms.help")),
    // Renaming rooms (PATCH /v1/rooms/{id}) needs an admin key.
    can("admin")
      ? h("div", { class: "room-editor-list" }, state.rooms.map(roomEditor))
      : h("p", { class: "notice notice-info" }, t("settings.rooms.askAdmin", { role: roleLabel(state.role) }))
  );
}

function roomEditor(room) {
  const names = room.names && typeof room.names === "object" ? room.names : {};
  const message = ui.roomMessages[room.id];
  const inputs = LANGUAGES.map((language) => {
    const key = `${room.id}:${language.code}`;
    const id = `room-name-${room.id}-${language.code}`;
    const input = h("input", {
      id,
      type: "text",
      maxlength: "64",
      lang: language.code,
      dir: "auto",
      autocomplete: "off",
      placeholder: room.name,
      value: ui.roomDrafts[key] ?? names[language.code] ?? "",
      dataset: { key: `room-name:${key}` },
    });
    input.addEventListener("input", () => {
      ui.roomDrafts[key] = input.value;
    });
    return h("div", { class: "field" }, h("label", { class: "field-label", for: id }, language.label), input);
  });

  const save = async (event) => {
    event.preventDefault();
    const next = {};
    for (const language of LANGUAGES) {
      const key = `${room.id}:${language.code}`;
      next[language.code] = String(ui.roomDrafts[key] ?? names[language.code] ?? "").trim();
    }
    ui.roomMessages[room.id] = { kind: "info", text: t("common.saving") };
    notify();
    try {
      await saveRoomNames(room.id, next);
      for (const language of LANGUAGES) delete ui.roomDrafts[`${room.id}:${language.code}`];
      ui.roomMessages[room.id] = { kind: "success", text: t("settings.rooms.saved") };
    } catch (error) {
      ui.roomMessages[room.id] = {
        kind: "error",
        text: error?.status === 404 || error?.status === 405 ? t("settings.rooms.updateDriver") : errorText(error),
      };
    }
    notify();
  };

  return h(
    "details",
    { class: "room-editor", dataset: { key: `room-editor:${room.id}` } },
    h("summary", {}, name(roomName(room), "span", "room-editor-name"), h("span", { class: "room-editor-original", dir: "auto" }, room.name)),
    h(
      "form",
      { class: "room-editor-form", onsubmit: save },
      inputs,
      h(
        "div",
        { class: "button-row" },
        h("button", { type: "submit", class: "button button-primary button-small", dataset: { key: `room-save:${room.id}` } }, t("common.save")),
        message ? h("p", { class: `notice notice-${message.kind}`, role: message.kind === "error" ? "alert" : "status" }, message.text) : null
      )
    )
  );
}

// ---- controller ----------------------------------------------------------------------------

function controllerSection(navigate) {
  const hostInput = h("input", {
    id: "settings-host",
    type: "text",
    inputmode: "url",
    autocomplete: "off",
    autocapitalize: "off",
    spellcheck: "false",
    placeholder: "192.168.1.50",
    value: ui.drafts.settingsHost ?? state.host,
    dataset: { key: "settings-host" },
  });
  hostInput.addEventListener("input", () => {
    ui.drafts.settingsHost = hostInput.value;
  });

  const submit = async (event) => {
    event.preventDefault();
    try {
      const previous = state.host;
      const host = useHost(hostInput.value);
      delete ui.drafts.settingsHost;
      ui.controllerMessage = null;
      if (host !== previous || !state.apiKey) {
        navigate("#/");
        await requestAccess(host);
      } else {
        await connect();
      }
    } catch (error) {
      ui.controllerMessage = { kind: "error", text: errorText(error) };
      notify();
    }
  };

  const system = state.system;
  const rows = [
    [t("settings.controller.status"), t(`status.${state.status}`)],
    state.role ? [t("settings.controller.access"), roleLabel(state.role)] : null,
    state.lastUpdated && state.loaded ? [t("settings.controller.updated"), formatTime(state.lastUpdated)] : null,
    system?.bridge?.version ? [t("settings.controller.bridgeVersion"), system.bridge.version] : null,
    system?.controller?.model ? [t("settings.controller.model"), system.controller.model] : null,
    system?.controller?.os_version ? [t("settings.controller.os"), system.controller.os_version] : null,
    system?.inventory
      ? [
          t("settings.controller.inventory"),
          t("settings.controller.inventoryValue", {
            rooms: system.inventory.rooms ?? 0,
            devices: system.inventory.devices ?? 0,
            supported: system.inventory.supported_devices ?? 0,
          }),
        ]
      : null,
  ].filter(Boolean);

  return card(
    "controller",
    "controller",
    t("settings.controller.title"),
    h(
      "form",
      { class: "inline-form", onsubmit: submit },
      h("label", { class: "field-label", for: "settings-host" }, t("connect.hostLabel")),
      h(
        "div",
        { class: "input-row" },
        hostInput,
        h("button", { type: "submit", class: "button button-primary", dataset: { key: "settings-host-save" } }, t("settings.controller.connect"))
      ),
      h("p", { class: "field-help" }, t("connect.hostHelp"))
    ),
    ui.controllerMessage ? h("p", { class: `notice notice-${ui.controllerMessage.kind}`, role: "alert" }, ui.controllerMessage.text) : null,
    h(
      "dl",
      { class: "facts" },
      rows.map(([label, value]) => h("div", { class: "fact" }, h("dt", {}, label), h("dd", { dir: "auto" }, value)))
    ),
    state.role && !can("member") ? h("p", { class: "notice notice-info" }, t("roles.viewOnly")) : null,
    state.status === "unreachable" && state.notice ? h("p", { class: "notice notice-error" }, state.notice.text) : null,
    h(
      "div",
      { class: "button-row" },
      state.status === "unreachable"
        ? h("button", { type: "button", class: "button button-secondary", dataset: { key: "settings-retry" }, onclick: () => connect() }, icon("refresh"), t("common.retry"))
        : null,
      state.apiKey
        ? h(
            "button",
            {
              type: "button",
              class: "button button-secondary",
              dataset: { key: "settings-new-access" },
              onclick: async () => {
                if (!window.confirm(t("settings.controller.newAccessConfirm"))) return;
                const host = state.host;
                await revokeAndForget();
                navigate("#/");
                requestAccess(host);
              },
            },
            icon("key"),
            t("settings.controller.newAccess")
          )
        : null,
      state.apiKey
        ? h(
            "button",
            {
              type: "button",
              class: "button button-danger",
              dataset: { key: "settings-forget" },
              onclick: async () => {
                if (!window.confirm(t("settings.controller.forgetConfirm"))) return;
                await revokeAndForget();
                state.notice = { kind: "info", text: t("settings.controller.forgotten") };
                navigate("#/");
              },
            },
            t("settings.controller.forget")
          )
        : null
    )
  );
}

// ---- app and about -------------------------------------------------------------------------

function appSection() {
  return card(
    "app",
    "download",
    t("settings.app.title"),
    h(
      "dl",
      { class: "facts" },
      h("div", { class: "fact" }, h("dt", {}, t("settings.app.offlineCopy")), h("dd", { id: "offline-status" }, t(`settings.app.offline.${state.offlineCopy}`))),
      h("div", { class: "fact" }, h("dt", {}, t("settings.app.secure")), h("dd", {}, window.isSecureContext ? t("settings.app.secureYes") : t("settings.app.secureNo")))
    ),
    h("p", { class: "field-help" }, t("settings.app.offlineHelp")),
    h(
      "div",
      { class: "button-row" },
      state.canInstall
        ? h("button", { id: "install-button", type: "button", class: "button button-primary", dataset: { key: "install" }, onclick: installApp }, icon("download"), t("settings.app.install"))
        : null,
      h("a", { class: "button button-secondary", href: "/console.html" }, icon("terminal"), t("settings.app.console"))
    )
  );
}

function aboutSection() {
  return card(
    "about",
    "info",
    t("settings.about.title"),
    h("p", {}, t("settings.about.text")),
    h("p", { class: "field-help" }, t("settings.about.independent")),
    h(
      "div",
      { class: "button-row" },
      h("a", { class: "button button-quiet", href: "https://github.com/IsraelCIL/C4Bridge", rel: "noreferrer", target: "_blank" }, t("settings.about.source"), icon("external"))
    )
  );
}
