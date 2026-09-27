// Home: summary chips, the favorites strip and the room cards.

import { cameraPicture, emptyState, favoriteStar, relayButton, skeletonCards } from "../components.js";
import { setLight } from "../controls.js";
import { h, iconButton, name } from "../dom.js";
import { favoriteDevices, moveFavorite, toggleFavorite } from "../favorites.js";
import { formatTemperature, t } from "../i18n.js";
import { icon } from "../icons.js";
import {
  blindIsOpen,
  blindStateLabel,
  climateIsOn,
  deviceRoomId,
  lightIsOn,
  matchesFilter,
  modeLabel,
  roomName,
  shownBrightness,
  summaryCounts,
  visibleRooms,
} from "../model.js";
import { installApp } from "../pwa.js";
import { can, notify, state, ui } from "../state.js";
import { connectScreen } from "./connect.js";
import { isLoading, offlineBanner, pageHeader, staleBanner, unreachableState } from "./common.js";

export function homeView({ openCamera, openFavoritesPicker }) {
  const header = pageHeader({
    title: t("home.title"),
    actions: state.canInstall
      ? [iconButton("download", t("settings.app.install"), { class: "install-button", dataset: { key: "install-home" }, onclick: installApp })]
      : [],
  });
  if (state.status === "setup" || state.status === "waiting" || (!state.apiKey && state.status === "connecting")) {
    return [header, offlineBanner(), connectScreen()];
  }
  if (isLoading()) {
    return [
      header,
      h("div", { class: "summary", "aria-hidden": "true" }, skeletonCards(3, "skeleton-chip")),
      h("h2", { class: "section-title" }, t("home.rooms")),
      h("div", { class: "room-grid", "aria-busy": "true" }, skeletonCards(4)),
      h("p", { class: "visually-hidden", role: "status" }, t("common.loading")),
    ];
  }
  if (!state.loaded) {
    return [header, offlineBanner(), unreachableState()];
  }
  return [
    header,
    offlineBanner(),
    staleBanner(),
    summaryChips(),
    favoritesSection({ openCamera, openFavoritesPicker }),
    roomsSection(),
  ];
}

// ---- summary -------------------------------------------------------------------------------

function summaryChips() {
  const counts = summaryCounts();
  const chips = [];
  const add = (filter, iconName, label, active) =>
    chips.push(
      h(
        "button",
        {
          type: "button",
          class: `summary-chip summary-${filter} ${active ? "has-on" : ""} ${ui.filter === filter ? "is-active" : ""}`,
          "aria-pressed": String(ui.filter === filter),
          dataset: { key: `filter:${filter}` },
          onclick: () => {
            ui.filter = ui.filter === filter ? null : filter;
            notify();
          },
        },
        icon(iconName),
        h("span", {}, label)
      )
    );
  if (state.lights.length) {
    add("lights", "bulb", counts.lightsOn ? t("home.lightsOn", { count: counts.lightsOn }) : t("home.lightsAllOff"), counts.lightsOn > 0);
  }
  if (state.thermostats.length) {
    add("climate", "climate", counts.climateOn ? t("home.climateOn", { count: counts.climateOn }) : t("home.climateAllOff"), counts.climateOn > 0);
  }
  if (state.blinds.length) {
    add("blinds", "blinds", counts.blindsOpen ? t("home.blindsOpen", { count: counts.blindsOpen }) : t("home.blindsAllClosed"), counts.blindsOpen > 0);
  }
  if (!chips.length) return null;
  return h("div", { class: "summary", role: "group", "aria-label": t("home.filterLabel") }, chips);
}

// ---- favorites -----------------------------------------------------------------------------

function favoritesSection({ openCamera, openFavoritesPicker }) {
  const items = favoriteDevices();
  const editing = ui.editFavorites;
  const hasDevices = state.lights.length + state.thermostats.length + state.blinds.length + state.cameras.length + state.relays.length > 0;
  if (!hasDevices) return null;

  const toggleEdit = h(
    "button",
    {
      type: "button",
      class: "button button-quiet button-small",
      "aria-pressed": String(editing),
      dataset: { key: "favorites-edit" },
      onclick: () => {
        ui.editFavorites = !editing;
        notify();
      },
    },
    icon(editing ? "check" : "edit"),
    editing ? t("common.done") : t("common.edit")
  );

  let body;
  if (!items.length && !editing) {
    body = h(
      "div",
      { class: "favorites-empty" },
      icon("star"),
      h("p", {}, t("favorites.emptyText")),
      h(
        "button",
        { type: "button", class: "button button-secondary button-small", dataset: { key: "favorites-add-empty" }, onclick: openFavoritesPicker },
        icon("plus"),
        t("favorites.addDevices")
      )
    );
  } else {
    const tiles = items.map((item, index) => favoriteTile(item, { editing, index, count: items.length, openCamera }));
    if (editing) {
      tiles.push(
        h(
          "button",
          { type: "button", class: "fav-tile fav-add", dataset: { key: "favorites-add" }, onclick: openFavoritesPicker },
          icon("plus"),
          h("span", {}, t("favorites.addDevices"))
        )
      );
    }
    body = h("div", { class: `favorites ${editing ? "is-editing" : ""}`, role: "list" }, tiles.map((tile) => h("div", { role: "listitem", class: "fav-item" }, tile)));
  }

  return h(
    "section",
    { class: "home-section", "aria-labelledby": "favorites-title" },
    h("div", { class: "section-head" }, h("h2", { id: "favorites-title", class: "section-title" }, icon("star"), t("favorites.title")), toggleEdit),
    body
  );
}

function favoriteTile({ entry, kind, device }, { editing, index, count, openCamera }) {
  const room = device.room ? name(roomName(device.room), "span", "fav-room") : null;
  let content;
  let stateClass = "";
  if (kind === "light") {
    stateClass = device.on ? "is-on" : "";
    content = [
      h("span", { class: "fav-icon" }, icon("bulb")),
      name(device.name, "span", "fav-name"),
      room,
      h("span", { class: "fav-state" }, device.on ? (device.dimmable ? t("lights.level", { percent: shownBrightness(device) }) : t("lights.on")) : t("lights.off")),
    ];
  } else if (kind === "thermostat") {
    stateClass = climateIsOn(device) ? "is-cool" : "";
    content = [
      h("span", { class: "fav-icon" }, icon("climate")),
      name(device.name, "span", "fav-name"),
      room,
      h(
        "span",
        { class: "fav-state" },
        [
          Number.isFinite(device.current_temperature) ? formatTemperature(device.current_temperature) : null,
          climateIsOn(device) ? `${modeLabel(device.mode)} ${formatTemperature(device.target_temperature)}` : modeLabel(device.mode),
        ]
          .filter(Boolean)
          .join(" · ")
      ),
    ];
  } else if (kind === "blind") {
    stateClass = blindIsOpen(device) ? "is-open" : "";
    content = [h("span", { class: "fav-icon" }, icon("blinds")), name(device.name, "span", "fav-name"), room, h("span", { class: "fav-state" }, blindStateLabel(device))];
  } else if (kind === "camera") {
    content = [cameraPicture(device, 320), h("span", { class: "fav-caption" }, name(device.name, "span", "fav-name"))];
    stateClass = "fav-camera";
  } else if (kind === "relay") {
    content = [h("span", { class: "fav-icon" }, icon("door")), name(device.name, "span", "fav-name"), room];
    stateClass = "fav-relay";
  }

  if (editing) {
    return h(
      "div",
      { class: `fav-tile ${stateClass} is-editing` },
      h("div", { class: "fav-body" }, content),
      h(
        "div",
        { class: "fav-edit" },
        iconButton("moveBack", t("favorites.moveEarlier", { name: device.name }), {
          dataset: { key: `${entry}:earlier` },
          disabled: index === 0,
          onclick: () => {
            moveFavorite(entry, -1);
            ui.tick += 1;
            notify();
          },
        }),
        iconButton("close", t("favorites.remove", { name: device.name }), {
          class: "danger",
          dataset: { key: `${entry}:remove` },
          onclick: () => {
            toggleFavorite(kind, device.id);
            ui.tick += 1;
            notify();
          },
        }),
        iconButton("moveForward", t("favorites.moveLater", { name: device.name }), {
          dataset: { key: `${entry}:later` },
          disabled: index === count - 1,
          onclick: () => {
            moveFavorite(entry, 1);
            ui.tick += 1;
            notify();
          },
        })
      )
    );
  }

  if (kind === "light" && can("member")) {
    return h(
      "button",
      {
        type: "button",
        class: `fav-tile ${stateClass}`,
        "aria-pressed": String(Boolean(device.on)),
        dataset: { key: `${entry}:tile` },
        onclick: () => setLight(device, { on: !device.on }),
      },
      content,
      state.errors[entry] ? h("span", { class: "fav-error", role: "alert" }, state.errors[entry].text) : null
    );
  }
  if (kind === "camera") {
    return h(
      "button",
      { type: "button", class: `fav-tile ${stateClass}`, "aria-label": t("cameras.open", { name: device.name }), dataset: { key: `${entry}:tile` }, onclick: () => openCamera(device) },
      content
    );
  }
  if (kind === "relay") {
    return h(
      "div",
      { class: `fav-tile ${stateClass}` },
      content,
      relayButton(device, { compact: true }),
      state.errors[entry] ? h("span", { class: "fav-error", role: "alert" }, state.errors[entry].text) : null
    );
  }
  return h("a", { class: `fav-tile ${stateClass}`, href: `#/room/${deviceRoomId(device)}`, dataset: { key: `${entry}:tile` } }, content);
}

// ---- rooms ---------------------------------------------------------------------------------

function roomStatus(group) {
  const parts = [];
  if (group.lights.length) {
    const on = group.lights.filter(lightIsOn).length;
    parts.push(on ? t("rooms.lightsOnOf", { on, count: group.lights.length }) : t("rooms.lightsOff", { count: group.lights.length }));
  }
  for (const thermostat of group.thermostats) {
    parts.push(
      climateIsOn(thermostat)
        ? t("rooms.climateOn", { mode: modeLabel(thermostat.mode), temperature: formatTemperature(thermostat.target_temperature) })
        : t("rooms.climateOff")
    );
  }
  if (group.blinds.length) {
    const open = group.blinds.filter(blindIsOpen).length;
    parts.push(
      group.blinds.length === 1
        ? blindStateLabel(group.blinds[0])
        : open
          ? t("rooms.blindsOpen", { count: open })
          : t("rooms.blindsClosed")
    );
  }
  if (group.cameras.length) parts.push(t("rooms.cameras", { count: group.cameras.length }));
  if (group.relays.length) parts.push(t("rooms.relays", { count: group.relays.length }));
  return parts.join(" · ");
}

function roomCard({ room, group }) {
  const lightsOn = group.lights.some(lightIsOn);
  const climateOn = group.thermostats.some(climateIsOn);
  const blindsOpen = group.blinds.some(blindIsOpen);
  const badges = [
    group.lights.length ? h("span", { class: `badge ${lightsOn ? "badge-on" : ""}` }, icon("bulb")) : null,
    group.thermostats.length ? h("span", { class: `badge ${climateOn ? "badge-cool" : ""}` }, icon("climate")) : null,
    group.blinds.length ? h("span", { class: `badge ${blindsOpen ? "badge-open" : ""}` }, icon("blinds")) : null,
    group.cameras.length ? h("span", { class: "badge" }, icon("camera")) : null,
    group.relays.length ? h("span", { class: "badge" }, icon("door")) : null,
  ];
  return h(
    "a",
    { class: `room-card ${lightsOn ? "is-on" : ""}`, href: `#/room/${room.id}`, dataset: { key: `room:${room.id}` } },
    h("span", { class: "room-card-top" }, h("span", { class: "badges", "aria-hidden": "true" }, badges), icon("chevronForward", "room-chevron")),
    name(roomName(room), "span", "room-name"),
    h("span", { class: "room-status" }, roomStatus(group))
  );
}

function roomsSection() {
  const rooms = visibleRooms();
  if (!rooms.length) {
    return emptyState("rooms", t("home.noDevicesTitle"), t("home.noDevicesText"));
  }
  const shown = rooms.filter((entry) => matchesFilter(entry.group, ui.filter));
  return h(
    "section",
    { class: "home-section", "aria-labelledby": "rooms-title" },
    h(
      "div",
      { class: "section-head" },
      h("h2", { id: "rooms-title", class: "section-title" }, icon("rooms"), ui.filter ? t(`home.filtered.${ui.filter}`) : t("home.rooms")),
      ui.filter
        ? h(
            "button",
            { type: "button", class: "button button-quiet button-small", dataset: { key: "filter-clear" }, onclick: () => { ui.filter = null; notify(); } },
            icon("close"),
            t("home.showAll")
          )
        : null
    ),
    shown.length
      ? h("div", { class: "room-grid" }, shown.map(roomCard))
      : h("p", { class: "muted-note" }, t("home.noMatch"))
  );
}

// Favorites picker (dialog body): every device with a star.
export function favoritesPicker() {
  const groups = [
    ["lights", "light", "bulb"],
    ["climate", "thermostat", "climate"],
    ["blinds", "blind", "blinds"],
    ["relays", "relay", "door"],
    ["cameras", "camera", "camera"],
  ];
  const lists = { light: state.lights, thermostat: state.thermostats, blind: state.blinds, relay: state.relays, camera: state.cameras };
  return groups
    .filter(([, kind]) => lists[kind].length)
    .map(([section, kind, iconName]) =>
      h(
        "section",
        { class: "picker-group" },
        h("h3", { class: "picker-title" }, icon(iconName), t(`sections.${section}`)),
        h(
          "ul",
          { class: "picker-list" },
          lists[kind].map((device) =>
            h(
              "li",
              { class: "picker-item" },
              h("span", { class: "picker-text" }, name(device.name, "span", "device-name"), name(roomName(device.room), "span", "device-meta")),
              favoriteStar(kind, device)
            )
          )
        )
      )
    );
}
