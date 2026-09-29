// Settings: appearance, language, room names, controller, account, app and about.

import { SIGN_IN_PROVIDERS, deleteAccount, loadAccount, removeProvider, signIn, signOut } from "../account.js";
import { IS_IOS } from "../platform.js";
import { qrCanvas } from "../qr.js";
import { approveHomeSecret, claimHome, homeStatus, invitationLink, registerInvitation, saveRemote, savedRemote } from "../remote.js";
import { disableNotifications, enableNotifications, notificationSupport, notificationsOn } from "../doorbells.js";
import { h, iconButton, name } from "../dom.js";
import { LANGUAGES, formatDateTime, formatTime, languagePreference, t } from "../i18n.js";
import { icon } from "../icons.js";
import { hiddenRoomIds, roomName } from "../model.js";
import { setRoomHidden } from "../profile.js";
import { installApp } from "../pwa.js";
import { api, checkInThroughAccount, connect, errorText, revokeAndForget, roleLabel, saveRoomNames, useHost } from "../session.js";
import { PALETTES, THEMES, palettePreference, themePreference } from "../theme.js";
import { can, notify, state, ui } from "../state.js";
import { offlineBanner, pageHeader, signInButtons } from "./common.js";
import { updateFact, updatePanel } from "./updates.js";

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
      accountSection(),
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
  const admin = can("admin");
  const personal = Boolean(state.profile);
  const hidden = hiddenRoomIds();
  return card(
    "rooms",
    "rooms",
    t("settings.rooms.title"),
    h("p", { class: "field-help" }, personal ? (admin ? t("settings.rooms.orderHelpAdmin") : t("settings.rooms.orderHelp")) : t("settings.rooms.updateForHiding")),
    ui.roomOrderMessage ? h("p", { class: `notice notice-${ui.roomOrderMessage.kind}`, role: "alert" }, ui.roomOrderMessage.text) : null,
    h("ul", { class: "room-order-list" }, state.rooms.map((room, index) => roomRow(room, index, hidden, { admin, personal }))),
    h("h3", { class: "settings-subtitle" }, t("settings.rooms.namesTitle")),
    // Renaming rooms (PATCH /v1/rooms/{id}) needs an admin key.
    admin
      ? [h("p", { class: "field-help" }, t("settings.rooms.help")), h("div", { class: "room-editor-list" }, state.rooms.map(roomEditor))]
      : h("p", { class: "notice notice-info" }, t("settings.rooms.askAdmin", { role: roleLabel(state.role) }))
  );
}

// One room: shown or hidden for this person, and (admins) moved up or down for everyone.
function roomRow(room, index, hidden, { admin, personal }) {
  const id = `room-show-${room.id}`;
  const shown = !hidden.has(room.id);
  return h(
    "li",
    { class: "room-order-row", dataset: { key: `room-row:${room.id}` } },
    personal
      ? h("input", { type: "checkbox", id, checked: shown, dataset: { key: `room-show:${room.id}` }, onchange: (event) => setRoomHidden(room.id, !event.target.checked) })
      : null,
    h(
      "label",
      { class: "room-order-name", for: personal ? id : null },
      name(roomName(room), "span"),
      shown ? null : h("span", { class: "room-order-hidden" }, t("settings.rooms.hiddenForYou"))
    ),
    admin
      ? h(
          "span",
          { class: "room-order-moves" },
          iconButton("arrowUp", t("settings.rooms.moveUp", { name: roomName(room) }), { disabled: index === 0, dataset: { key: `room-up:${room.id}` }, onclick: () => moveRoom(index, -1) }),
          iconButton("arrowDown", t("settings.rooms.moveDown", { name: roomName(room) }), { disabled: index === state.rooms.length - 1, dataset: { key: `room-down:${room.id}` }, onclick: () => moveRoom(index, 1) })
        )
      : null
  );
}

// The home's room order, for everyone (PUT /v1/rooms/order; drivers before 0.12.0 answer 404).
async function moveRoom(index, offset) {
  const before = state.rooms;
  const target = index + offset;
  if (target < 0 || target >= before.length) return;
  const rooms = [...before];
  [rooms[index], rooms[target]] = [rooms[target], rooms[index]];
  state.rooms = rooms;
  ui.roomOrderMessage = null;
  notify();
  try {
    const answer = await api("/v1/rooms/order", { method: "PUT", body: { room_ids: rooms.map((room) => room.id) } });
    if (Array.isArray(answer?.items)) state.rooms = answer.items;
  } catch (error) {
    state.rooms = before;
    ui.roomOrderMessage = { kind: "error", text: error?.status === 404 || error?.status === 405 ? t("settings.rooms.updateDriverOrder") : errorText(error) };
  }
  notify();
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
      // A device that joined with an invitation keeps its key for its home's first address.
      if ((previous && host !== previous) || !state.apiKey) {
        // A new controller needs its own key: pair with a code from its Composer project.
        state.notice = { kind: "info", text: t("connect.pairNew") };
        navigate("#/");
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
    // Admins: whether a newer DirectorLink is out (views/updates.js).
    updateFact(),
    system?.controller?.model ? [t("settings.controller.model"), system.controller.model] : null,
    system?.controller?.os_version ? [t("settings.controller.os"), system.controller.os_version] : null,
    system?.inventory
      ? [
          t("settings.controller.inventory"),
          [
            t("settings.controller.inventoryValue", {
              rooms: system.inventory.rooms ?? 0,
              devices: system.inventory.devices ?? 0,
              supported: system.inventory.supported_devices ?? 0,
            }),
            // Drivers with doorbells (0.9.2) count them too.
            system.inventory.doorbells ? t("settings.controller.inventoryDoorbells", { count: system.inventory.doorbells }) : null,
          ]
            .filter(Boolean)
            .join(" · "),
        ]
      : null,
  ].filter(Boolean);

  return card(
    "controller",
    "controller",
    t("settings.controller.title"),
    // iPhone and iPad cannot use the home-network connection (docs/ACCOUNTS.md).
    IS_IOS
      ? null
      : h(
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
    updatePanel(),
    state.role && !can("member") ? h("p", { class: "notice notice-info" }, t("roles.viewOnly")) : null,
    state.status === "unreachable" && state.notice ? h("p", { class: "notice notice-error" }, state.notice.text) : null,
    h(
      "div",
      { class: "button-row" },
      state.status === "unreachable"
        ? h("button", { type: "button", class: "button button-secondary", dataset: { key: "settings-retry" }, onclick: () => connect() }, icon("refresh"), t("common.retry"))
        : null,
      // Admins manage who has access: devices, invitations and, for the owner, people.
      state.loaded && can("admin")
        ? h("a", { class: "button button-secondary", href: "#/access", dataset: { key: "settings-access" } }, icon("user"), t("access.open"))
        : null,
      state.apiKey
        ? h(
            "button",
            {
              type: "button",
              class: "button button-secondary",
              dataset: { key: "settings-pair-again" },
              onclick: async () => {
                if (!window.confirm(t("settings.controller.pairAgainConfirm"))) return;
                await revokeAndForget();
                state.notice = { kind: "info", text: t("connect.pairNew") };
                navigate("#/");
              },
            },
            icon("key"),
            t("settings.controller.pairAgain")
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

// ---- account -------------------------------------------------------------------------------

// ---- This home: linking it to the account, adding devices, inviting (docs/ACCOUNTS.md) --------

let remoteInfoLoading = false;
function loadRemoteInfo() {
  if (remoteInfoLoading) return;
  remoteInfoLoading = true;
  api("/v1/remote")
    .then((info) => {
      state.remoteInfo = info;
    })
    .catch((error) => {
      state.remoteInfo = { enabled: false, lock: false, missing: error?.status === 404 || error?.status === 405 };
    })
    .finally(() => {
      remoteInfoLoading = false;
      notify();
    });
}

async function linkHome() {
  ui.homeBusy = true;
  ui.homeMessage = null;
  notify();
  try {
    // The home is asked again: the address may have changed since the card was drawn.
    const info = await api("/v1/remote");
    state.remoteInfo = info;
    const homeId = info?.home_id;
    // Already this account's home (another device linked it): this device only needs its key id.
    // Another account's: linking takes it over, so ask first.
    const known = homeId ? await homeStatus(homeId) : null;
    let linked = homeId;
    let transferred = false;
    if (!known?.owner && !known?.member) {
      if (known?.claimed && !window.confirm(t("settings.account.home.takeOverConfirm"))) {
        return;
      }
      const claim = await api("/v1/remote/claim", { method: "POST" });
      if (homeId && claim.home_id !== homeId) {
        throw new Error("The controller changed while linking");
      }
      transferred = Boolean((await claimHome(claim.home_id, claim.claim_token))?.transferred);
      linked = claim.home_id;
    }
    const me = await api("/v1/api-keys/current");
    saveRemote({ home: linked, keyId: me.id });
    // The account service learns this device's key now, not only after its first remote use.
    checkInThroughAccount(true);
    ui.homeMessage = { kind: "success", text: transferred ? t("settings.account.home.takenOver") : t("settings.account.home.linkedNow") };
  } catch (error) {
    ui.homeMessage = { kind: "error", text: error?.code === "REMOTE_ACCESS_OFF" ? t("settings.account.home.turnOn") : errorText(error) };
  } finally {
    ui.homeBusy = false;
    notify();
  }
}

// The owner replaces the secret the controller connects to the relay with (docs/RELAY.md): the
// controller makes it and gives only its hash, here on the home network; the account service
// then accepts only the new one. Someone with a copy of the controller's data cannot do this.
async function replaceHomeSecret() {
  const linked = savedRemote();
  if (!linked || !window.confirm(t("settings.account.home.secretConfirm"))) return;
  ui.homeBusy = true;
  ui.homeMessage = null;
  notify();
  try {
    const prepared = await api("/v1/remote/secret", { method: "POST" });
    if (prepared?.home_id !== linked.home) {
      throw new Error("The controller at this address is not this home's");
    }
    await approveHomeSecret(linked.home, prepared.secret_sha256);
    ui.homeMessage = { kind: "success", text: t("settings.account.home.secretReplaced") };
  } catch (error) {
    ui.homeMessage = { kind: "error", text: error?.code === "OWNER_ONLY" ? t("settings.account.home.secretOwnerOnly") : errorText(error) };
  } finally {
    ui.homeBusy = false;
    notify();
  }
}

function secretPanel() {
  return [
    h("p", { class: "field-help" }, t("settings.account.home.secretHelp")),
    h(
      "div",
      { class: "button-row" },
      h("button", { type: "button", class: "button button-secondary", dataset: { key: "replace-secret" }, disabled: Boolean(ui.homeBusy), onclick: replaceHomeSecret }, t("settings.account.home.secret"))
    ),
  ];
}

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

async function createInvitation({ forSelf }) {
  const email = forSelf ? state.account.user.email : (ui.drafts["invite-email"] || "").trim();
  const role = forSelf ? state.role || "admin" : ui.drafts["invite-role"] || "member";
  if (!EMAIL.test(email)) {
    ui.homeMessage = { kind: "error", text: t("settings.account.home.badEmail") };
    notify();
    return;
  }
  ui.homeBusy = true;
  ui.homeMessage = null;
  notify();
  let invitation = null;
  try {
    // Just under 7 days: the account refuses invitations longer than that.
    // For my other device, the new key joins my profile (drivers with profiles, 0.12.0 and later).
    const body = { role, expires_in: forSelf ? 600 : 7 * 24 * 3600 - 300 };
    if (forSelf && state.profile) body.for_me = true;
    try {
      // The controller registers it with the account service itself (1.0.0 and later).
      invitation = await api("/v1/invitations", { method: "POST", body: { ...body, email } });
    } catch (error) {
      const field = error?.problem?.errors?.[0]?.field;
      if (error?.code !== "INVALID_FIELD" || field !== "email") throw error;
      // A driver before 1.0.0: the home's owner registers it from here.
      invitation = await api("/v1/invitations", { method: "POST", body });
      await registerInvitation(invitation.home_id, invitation, email);
    }
    ui.homeInvitation = { link: invitationLink(invitation.home_id, invitation), expiresAt: invitation.expires_at, forSelf, email };
    ui.inviteForm = false;
  } catch (error) {
    // An invitation the account does not know can never be accepted: revoke it at home too.
    if (invitation?.id) {
      api(`/v1/invitations/${invitation.id}`, { method: "DELETE" }).catch(() => {});
    }
    ui.homeMessage = { kind: "error", text: errorText(error) };
  } finally {
    ui.homeBusy = false;
    notify();
  }
}

function draftField(key, fallback, props) {
  const input = h("input", { ...props, value: ui.drafts[key] ?? fallback, dataset: { key } });
  input.addEventListener("input", () => {
    ui.drafts[key] = input.value;
  });
  return input;
}

function invitationResult(invitation) {
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(invitation.link);
      ui.homeMessage = { kind: "success", text: t("settings.account.home.copied") };
    } catch {
      ui.homeMessage = { kind: "error", text: t("settings.account.home.copyFailed") };
    }
    notify();
  };
  return h(
    "div",
    { class: "invitation" },
    h("p", {}, invitation.forSelf ? t("settings.account.home.scanHelp") : t("settings.account.home.sendHelp", { email: invitation.email })),
    qrCanvas(invitation.link, { label: t("settings.account.home.qrLabel") }),
    h("input", { class: "invitation-link", type: "text", readonly: true, dir: "ltr", value: invitation.link, "aria-label": t("settings.account.home.linkLabel"), onfocus: (event) => event.target.select() }),
    h(
      "div",
      { class: "button-row" },
      h("button", { type: "button", class: "button button-primary", dataset: { key: "invitation-copy" }, onclick: copy }, t("settings.account.home.copy")),
      navigator.share
        ? h("button", { type: "button", class: "button button-secondary", dataset: { key: "invitation-share" }, onclick: () => navigator.share({ title: "DirectorLink", url: invitation.link }).catch(() => {}) }, t("settings.account.home.share"))
        : null,
      h("button", { type: "button", class: "button button-quiet", dataset: { key: "invitation-done" }, onclick: () => { ui.homeInvitation = null; ui.homeMessage = null; notify(); } }, t("common.done"))
    ),
    h("p", { class: "field-help" }, t("settings.account.home.expires", { time: formatDateTime(new Date(invitation.expiresAt)) }))
  );
}

function invitePanel() {
  if (ui.homeInvitation) {
    return invitationResult(ui.homeInvitation);
  }
  if (ui.inviteForm) {
    const roles = ["viewer", "member", "doors", "admin"];
    const role = h("select", { id: "invite-role", dataset: { key: "invite-role" } }, ...roles.map((value) => h("option", { value, selected: (ui.drafts["invite-role"] || "member") === value }, roleLabel(value))));
    role.addEventListener("change", () => {
      ui.drafts["invite-role"] = role.value;
    });
    return h(
      "form",
      { class: "invite-form", novalidate: true, onsubmit: (event) => { event.preventDefault(); createInvitation({ forSelf: false }); } },
      h("label", { class: "field-label", for: "invite-email" }, t("settings.account.home.email")),
      draftField("invite-email", "", { id: "invite-email", type: "email", autocomplete: "off", dir: "ltr", placeholder: "name@example.com" }),
      h("label", { class: "field-label", for: "invite-role" }, t("settings.account.home.role")),
      role,
      h("p", { class: "field-help" }, t("settings.account.home.inviteHelp")),
      h(
        "div",
        { class: "button-row" },
        h("button", { type: "submit", class: "button button-primary", dataset: { key: "invite-create" }, disabled: Boolean(ui.homeBusy) }, t("settings.account.home.create")),
        h("button", { type: "button", class: "button button-quiet", onclick: () => { ui.inviteForm = false; notify(); } }, t("common.cancel"))
      )
    );
  }
  return [
    h("p", { class: "field-help" }, t("settings.account.home.addHelp")),
    h(
      "div",
      { class: "button-row" },
      h("button", { type: "button", class: "button button-secondary", dataset: { key: "add-device" }, disabled: Boolean(ui.homeBusy), onclick: () => createInvitation({ forSelf: true }) }, icon("plus"), t("settings.account.home.addDevice")),
      h("button", { type: "button", class: "button button-secondary", dataset: { key: "invite" }, disabled: Boolean(ui.homeBusy), onclick: () => { ui.inviteForm = true; notify(); } }, icon("user"), t("settings.account.home.invite"))
    ),
  ];
}

function homeSection() {
  const linked = savedRemote();
  const content = [];
  if (linked) {
    content.push(h("p", { class: "field-help", id: "account-home-linked" }, t("settings.account.home.linked")));
    if (can("admin")) content.push(invitePanel());
    // On the home network only: the controller refuses it through the account.
    if (can("admin") && !ui.homeInvitation && !ui.inviteForm && state.status === "connected" && state.transport === "lan") content.push(...secretPanel());
  } else if (IS_IOS) {
    content.push(h("p", { class: "field-help" }, t("settings.account.home.iosJoin")));
  } else if (state.status !== "connected" || state.transport !== "lan") {
    content.push(h("p", { class: "field-help" }, t("settings.account.home.connectFirst")));
  } else if (!can("admin")) {
    content.push(h("p", { class: "field-help" }, t("settings.account.home.askAdmin")));
  } else {
    const info = state.remoteInfo;
    if (!info) {
      loadRemoteInfo();
      content.push(h("p", { class: "field-help", role: "status" }, t("common.loading")));
    } else if (info.missing) {
      content.push(h("p", { class: "notice notice-info" }, t("settings.account.home.updateDriver")));
    } else if (!info.enabled) {
      content.push(
        h("p", { class: "notice notice-info" }, t("settings.account.home.turnOn")),
        h("div", { class: "button-row" }, h("button", { type: "button", class: "button button-secondary", onclick: () => { state.remoteInfo = null; notify(); } }, icon("refresh"), t("common.retry")))
      );
    } else if (!info.lock) {
      content.push(h("p", { class: "notice notice-error" }, t("settings.account.home.noLock")));
    } else {
      content.push(
        h("p", { class: "field-help" }, t("settings.account.home.linkHelp")),
        h("div", { class: "button-row" }, h("button", { type: "button", class: "button button-primary", dataset: { key: "link-home" }, disabled: Boolean(ui.homeBusy), onclick: linkHome }, t("settings.account.home.link")))
      );
    }
  }
  const message = ui.homeMessage ? h("p", { class: `notice notice-${ui.homeMessage.kind}`, role: "status" }, ui.homeMessage.text) : null;
  return h("div", { class: "account-home", id: "account-home" }, h("h3", { class: "settings-subtitle" }, t("settings.account.home.title")), message, ...content);
}

// Signing in is optional: it is for using the home away from the home network, and for inviting
// family (docs/ACCOUNTS.md). Google shows its own page; this card only shows the result.
function accountSection() {
  const account = state.account;
  const notice = account.notice
    ? h("p", { class: `notice ${["deleted", "linked", "removed", "signedOutEverywhere"].includes(account.notice) ? "notice-success" : "notice-error"}`, role: "status" }, t(`settings.account.notice.${account.notice}`))
    : null;
  let body;
  if (account.status === "signed-in") {
    body = [
      h(
        "dl",
        { class: "facts" },
        h("div", { class: "fact" }, h("dt", {}, t("settings.account.signedInAs")), h("dd", { id: "account-email" }, account.user.email)),
        account.user.name ? h("div", { class: "fact" }, h("dt", {}, t("settings.account.name")), h("dd", {}, account.user.name)) : null,
        Array.isArray(account.user.providers) && account.user.providers.length
          ? h("div", { class: "fact" }, h("dt", {}, t("settings.account.providers")), h("dd", { id: "account-providers" }, account.user.providers.map((provider) => t(`settings.account.provider.${provider}`)).join(" · ")))
          : null
      ),
      h(
        "div",
        { class: "button-row" },
        h("button", { type: "button", class: "button button-secondary", dataset: { key: "account-sign-out" }, disabled: account.busy, onclick: () => signOut() }, t("settings.account.signOut")),
        h(
          "button",
          {
            type: "button",
            class: "button button-secondary",
            dataset: { key: "account-sign-out-everywhere" },
            disabled: account.busy,
            onclick: () => {
              if (window.confirm(t("settings.account.signOutEverywhereConfirm"))) signOut({ everywhere: true });
            },
          },
          t("settings.account.signOutEverywhere")
        ),
        // Signing in with another provider gives another account; adding it here, while signed in,
        // makes both sign in to this one.
        ...SIGN_IN_PROVIDERS.filter((provider) => Array.isArray(account.user.providers) && !account.user.providers.includes(provider)).map((provider) =>
          h(
            "button",
            { type: "button", class: "button button-secondary", dataset: { key: `account-add-${provider}` }, disabled: account.busy, onclick: () => signIn("#/settings", provider, { link: true }) },
            icon(provider === "apple" ? "apple" : "user"),
            t("settings.account.addProvider", { provider: t(`settings.account.provider.${provider}`) })
          )
        ),
        // With two, either may go (the last one stays).
        ...(Array.isArray(account.user.providers) && account.user.providers.length > 1
          ? account.user.providers.map((provider) =>
              h(
                "button",
                {
                  type: "button",
                  class: "button button-quiet",
                  dataset: { key: `account-remove-${provider}` },
                  disabled: account.busy,
                  onclick: () => {
                    const label = t(`settings.account.provider.${provider}`);
                    if (window.confirm(t("settings.account.removeProviderConfirm", { provider: label }))) removeProvider(provider);
                  },
                },
                t("settings.account.removeProvider", { provider: t(`settings.account.provider.${provider}`) })
              )
            )
          : []),
        h(
          "button",
          {
            type: "button",
            class: "button button-danger",
            dataset: { key: "account-delete" },
            disabled: account.busy,
            onclick: () => {
              if (window.confirm(t("settings.account.deleteConfirm"))) deleteAccount();
            },
          },
          t("settings.account.delete")
        )
      ),
      homeSection(),
    ];
  } else if (account.status === "unknown" || account.status === "loading") {
    body = [h("p", { class: "field-help", role: "status" }, t("common.loading"))];
  } else {
    body = [
      h("p", { class: "field-help" }, t("settings.account.intro")),
      account.status === "unavailable" ? h("p", { class: "notice notice-error", role: "status" }, t("settings.account.unavailable")) : null,
      h(
        "div",
        { class: "button-row" },
        signInButtons({ hash: "#/settings", key: "account-sign-in" }),
        account.status === "unavailable"
          ? h("button", { type: "button", class: "button button-secondary", dataset: { key: "account-retry" }, onclick: loadAccount }, icon("refresh"), t("common.retry"))
          : null
      ),
    ];
  }
  return card(
    "account",
    "user",
    t("settings.account.title"),
    notice,
    ...body,
    h("p", { class: "field-help" }, h("a", { href: "https://directorlink.io/privacy", target: "_blank", rel: "noopener" }, t("settings.account.privacy")))
  );
}

// ---- app and about -------------------------------------------------------------------------

// Doorbell notifications: asked for only from this button, shown only while the app is open.
function doorbellNotifications() {
  if (!state.doorbells.length) return null;
  const support = notificationSupport();
  const on = notificationsOn();
  const status =
    support === "unsupported"
      ? t("settings.app.notifications.unsupported")
      : support === "denied"
        ? t("settings.app.notifications.blocked")
        : on
          ? t("settings.app.notifications.on")
          : t("settings.app.notifications.off");
  const button =
    support === "unsupported" || support === "denied"
      ? null
      : on
        ? h("button", { type: "button", class: "button button-secondary", dataset: { key: "notifications-off" }, onclick: disableNotifications }, t("settings.app.notifications.turnOff"))
        : h(
            "button",
            { type: "button", class: "button button-secondary", dataset: { key: "notifications-on" }, onclick: () => enableNotifications() },
            icon("bell"),
            t("settings.app.notifications.turnOn")
          );
  return [
    h("dl", { class: "facts" }, h("div", { class: "fact" }, h("dt", {}, t("settings.app.notifications.label")), h("dd", { id: "doorbell-notifications" }, status))),
    h("p", { class: "field-help" }, t("settings.app.notifications.help")),
    button ? h("div", { class: "button-row" }, button) : null,
  ];
}

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
      h("a", { class: "button button-secondary", href: consoleUrl(), target: "_blank", rel: "noopener" }, icon("terminal"), t("settings.app.console"), icon("external"))
    ),
    doorbellNotifications()
  );
}

// The API console is its own site; a local copy of the app opens a local console
// (python -m http.server 8081 --bind 127.0.0.1 --directory console).
function consoleUrl() {
  return /^(localhost|127\.0\.0\.1)$/.test(window.location.hostname) ? "http://127.0.0.1:8081" : "https://console.directorlink.io";
}

function aboutSection() {
  return card(
    "about",
    "info",
    t("settings.about.title"),
    h("p", { class: "about-slogan" }, t("settings.about.slogan")),
    h("p", {}, t("settings.about.text")),
    h("p", { class: "field-help" }, t("settings.about.independent")),
    h(
      "div",
      { class: "button-row" },
      h("a", { class: "button button-quiet", href: "https://github.com/IsraelCIL/DirectorLink", rel: "noreferrer", target: "_blank" }, t("settings.about.source"), icon("external"))
    )
  );
}
