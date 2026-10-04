// Music (js/music.js, ADR-044): each Sonos room's card on its room screen, what plays on Home, and
// for admins the Sonos rooms with the Control4 room each is shown in (musicRoomsSection, on Settings
// → Rooms). A group plays as one: play, pause and skip on any of its rooms work on the group;
// volume and mute are each room's own. Playback controls stay left to right in Hebrew too.
// Since 1.8.0 (ADR-057, a driver with features.sonos_groups) a group of rooms has one card: what it
// plays once, a slider for the group and one per room, Leave group per room; a playing room plays in
// more rooms, and a room that plays nothing plays what another group plays, too.

import { inlineError, slider } from "../components.js";
import { h, iconButton, name } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { hiddenRoomIds, roomById, roomName } from "../model.js";
import {
  groupLeader,
  groupMates,
  groupRooms,
  groupsAvailable,
  isPlaying,
  joinGroup,
  leaveGroup,
  loadFavorites,
  musicArt,
  musicAvailable,
  musicCommand,
  musicFavorites,
  musicKey,
  musicRooms,
  placeMusicRoom,
  playFavorite,
  setGroupVolume,
  setMusicLevels,
} from "../music.js";
import { can, state } from "../state.js";

// A name inside a sentence in the other direction (a Sonos name in Hebrew, or the reverse).
function isolate(text) {
  return `⁨${text}⁩`;
}

// "Playing", "Paused", "Stopped", "Starting…", or nothing known.
export function musicStateText(item) {
  if (item.reachable === false) return t("music.state.unreachable");
  return t(`music.state.${["playing", "paused", "stopped", "transitioning"].includes(item.state) ? item.state : "unknown"}`);
}

// What plays, as two lines: { title, detail } (the detail may be empty).
export function nowPlayingText(item) {
  const playing = item.now_playing;
  if (!playing) return { title: t("music.nothing"), detail: "" };
  const join = (...parts) => parts.filter(Boolean).join(" · ");
  if (playing.kind === "radio") {
    const song = playing.title ? (playing.artist ? `${playing.artist} – ${playing.title}` : playing.title) : "";
    return { title: playing.station || t("music.kinds.radio"), detail: song };
  }
  if (playing.kind === "connect") {
    const source = playing.source ? t("music.via", { source: isolate(playing.source) }) : t("music.kinds.connect");
    return playing.title ? { title: playing.title, detail: join(playing.artist, source) } : { title: playing.source || t("music.kinds.connect"), detail: "" };
  }
  if (playing.kind === "tv" || playing.kind === "line_in") return { title: t(`music.kinds.${playing.kind}`), detail: "" };
  return { title: playing.title || t("music.kinds.music"), detail: join(playing.artist, playing.album) };
}

function artTile(item, size = "") {
  const url = musicArt(item);
  return h(
    "span",
    { class: `music-art ${size}`.trim(), "aria-hidden": "true" },
    url ? h("img", { src: url, alt: "", width: size ? "40" : "72", height: size ? "40" : "72" }) : icon("music")
  );
}

// On Home, Pause takes the group's line away (Music playing lists what plays): the keyboard goes to
// the section's title, or to the page's once nothing plays. Both keep it over the redraw (data-key).
function focusAfterPause() {
  document.querySelector(playingGroups().length ? "#home-music-title" : ".page-title")?.focus({ preventScroll: true });
}

function transportControls(item, { compact = false } = {}) {
  const playing = isPlaying(item);
  const off = item.reachable === false;
  const skip = item.can_skip && !off;
  const button = (iconName, label, action, extra = {}) =>
    iconButton(iconName, label, {
      class: `music-button ${extra.main ? "music-main-button" : ""}`.trim(),
      disabled: extra.disabled,
      // Play and pause are one button: one data-key, so its focus stays when it turns into the other.
      dataset: { key: `${musicKey(item)}:${extra.main ? "main" : action}${compact ? ":home" : ""}` },
      onclick: () => {
        const sent = musicCommand(item, action);
        if (compact && action === "pause") focusAfterPause();
        return sent;
      },
    });
  const main = playing
    ? button("pause", t("music.pause", { name: item.name }), "pause", { main: true, disabled: off })
    : button("play", t("music.play", { name: item.name }), "play", { main: true, disabled: off });
  if (compact) return h("div", { class: "music-controls is-compact", dir: "ltr" }, main);
  return h(
    "div",
    { class: "music-controls", role: "group", "aria-label": t("music.controls", { name: item.name }), dir: "ltr" },
    button("skipPrevious", t("music.previous"), "previous", { disabled: !skip }),
    main,
    button("skipNext", t("music.next"), "next", { disabled: !skip })
  );
}

function volumeControls(item) {
  const muted = item.muted === true;
  const volume = Number.isFinite(item.volume) ? item.volume : 0;
  return h(
    "div",
    { class: "music-volume" },
    h(
      "button",
      {
        type: "button",
        class: `icon-button music-mute ${muted ? "is-muted" : ""}`,
        "aria-pressed": String(muted),
        "aria-label": t("music.mute", { name: item.name }),
        title: t("music.mute", { name: item.name }),
        disabled: item.reachable === false || item.muted == null,
        dataset: { key: `${musicKey(item)}:mute` },
        onclick: () => setMusicLevels(item, { muted: !muted }),
      },
      icon(muted ? "volumeOff" : "volume")
    ),
    slider({
      label: t("music.volume", { name: item.name }),
      value: volume,
      key: `${musicKey(item)}:volume`,
      disabled: item.reachable === false || !Number.isFinite(item.volume),
      format: (value) => t("common.percent", { percent: value }),
      onCommit: (value) => setMusicLevels(item, { volume: value }),
    })
  );
}

// The favorites load when the person opens the panel, and again only when they ask (Retry, or
// closing and opening it): never because a redraw opened it again (app.js restoreUi), or a speaker
// that does not answer would be asked over and over.
function favoritesPanel(item) {
  const loaded = musicFavorites(item);
  const summary = h(
    "summary",
    {
      dataset: { key: `${musicKey(item)}:favorites:title` },
      // Before it opens (the click opens it); with the keyboard too.
      onclick: () => {
        if (!panel.open && musicFavorites(item)?.stage !== "ready") loadFavorites(item);
      },
    },
    icon("star"),
    t("music.favorites.title")
  );
  let body;
  if (!loaded || loaded.stage === "loading") {
    body = h("p", { class: "muted-note", role: "status" }, t("common.loading"));
  } else if (loaded.stage === "error") {
    body = h(
      "div",
      { class: "music-favorites-error" },
      h("p", { class: "inline-error", role: "alert" }, loaded.text),
      h(
        "button",
        {
          type: "button",
          class: "button button-secondary button-small",
          dataset: { key: `${musicKey(item)}:favorites:retry` },
          onclick: () => {
            // The button goes while they load: the keyboard waits on the panel's title.
            summary.focus({ preventScroll: true });
            loadFavorites(item);
          },
        },
        icon("refresh"),
        t("common.retry")
      )
    );
  } else if (!loaded.items.length) {
    body = h("p", { class: "muted-note" }, t("music.favorites.none"));
  } else {
    const playable = loaded.items.filter((favorite) => favorite.playable);
    body = [
      h(
        "ul",
        { class: "music-favorites-list" },
        loaded.items.map((favorite) =>
          h(
            "li",
            {},
            h(
              "button",
              {
                type: "button",
                class: "music-favorite",
                disabled: !favorite.playable || !can("member") || item.reachable === false,
                title: favorite.playable ? t("music.favorites.start", { name: favorite.title }) : t("music.favorites.onlyInSonos"),
                dataset: { key: `${musicKey(item)}:favorite:${favorite.id}` },
                onclick: () => playFavorite(item, favorite),
              },
              icon(favorite.playable ? "play" : "music"),
              h(
                "span",
                { class: "music-favorite-text" },
                name(favorite.title, "span", "music-favorite-name"),
                favorite.description ? name(favorite.description, "span", "device-meta") : null
              )
            )
          )
        )
      ),
      // Viewers start none: what only the Sonos app starts is said to those who can.
      playable.length < loaded.items.length && can("member")
        ? h("p", { class: "field-help" }, playable.length ? t("music.favorites.someOnlyInSonos") : t("music.favorites.onlyShortcuts"))
        : null,
    ];
  }
  const panel = h(
    "details",
    {
      class: "music-favorites",
      dataset: { key: `${musicKey(item)}:favorites` },
      // Opened some other way (the browser's find in page): loaded if they never were.
      ontoggle: (event) => {
        if (event.target.open && !musicFavorites(item)) loadFavorites(item);
      },
    },
    summary,
    body
  );
  return panel;
}

// ---- groups (1.8.0, ADR-057) ---------------------------------------------------------------

// "Kitchen + Living Room": the rooms of an item's group, its coordinator first.
export function groupName(item) {
  return groupRooms(item)
    .map((room) => room.name)
    .join(" + ");
}

function isGrouped(item) {
  return groupsAvailable() && (item.group?.rooms || []).length > 1;
}

// Where a Sonos room is and what it does, for a list to pick from: "Living Room · Paused".
function roomMeta(item) {
  const where = item.room_id != null && roomById(item.room_id) ? roomName(roomById(item.room_id)) : null;
  return [where && where !== item.name ? where : null, musicStateText(item)].filter(Boolean).join(" · ");
}

// A list to pick from, folded until opened (its open state kept over redraws by its data-key).
function pickPanel(key, title, help, entries) {
  const summary = h("summary", { dataset: { key: `${key}:title` } }, icon("plus"), title);
  return h(
    "details",
    { class: "music-favorites music-pick", dataset: { key } },
    summary,
    h("p", { class: "field-help" }, help),
    h(
      "ul",
      { class: "music-favorites-list" },
      entries.map(({ id, label, meta, disabled, onPick }) =>
        h(
          "li",
          {},
          h(
            "button",
            {
              type: "button",
              class: "music-favorite",
              disabled,
              dataset: { key: `${key}:${id}` },
              onclick: () => {
                // The row goes once it is done: the keyboard waits on the panel's title.
                summary.focus({ preventScroll: true });
                return onPick();
              },
            },
            icon("plus"),
            h("span", { class: "music-favorite-text" }, name(label, "span", "music-favorite-name"), meta ? h("span", { class: "device-meta" }, meta) : null)
          )
        )
      )
    )
  );
}

// On a group that plays: the other rooms; a tap and one plays it too.
function morePanel(item) {
  const leader = groupLeader(item);
  const inGroup = new Set(groupRooms(item).map((room) => room.id));
  const others = musicRooms().filter((room) => !inGroup.has(room.id));
  if (!others.length) return null;
  return pickPanel(
    `${musicKey(leader)}:more`,
    t("music.group.more"),
    t("music.group.moreHelp"),
    others.map((room) => ({
      id: room.id,
      label: room.name,
      meta: roomMeta(room),
      disabled: room.reachable === false || leader.reachable === false,
      onPick: () => joinGroup(room, leader),
    }))
  );
}

// On a room that plays nothing: the groups that play; a tap and it plays that too.
function herePanel(item) {
  const groups = playingGroups({ all: true }).filter((leader) => leader.group?.id !== item.group?.id && leader.id !== item.id);
  if (!groups.length) return null;
  return pickPanel(
    `${musicKey(item)}:here`,
    t("music.group.here"),
    t("music.group.hereHelp", { name: isolate(item.name) }),
    groups.map((leader) => {
      const text = nowPlayingText(leader);
      return {
        id: leader.id,
        label: groupName(leader),
        meta: [text.title, text.detail].filter(Boolean).join(" · "),
        disabled: item.reachable === false || leader.reachable === false,
        onPick: () => joinGroup(item, leader),
      };
    })
  );
}

// A room of a group on its card: its name, its own volume and mute, and Leave group.
function memberRow(room) {
  const member = can("member");
  return h(
    "li",
    { class: "music-member" },
    h(
      "div",
      { class: "music-member-head" },
      name(room.name, "span", "music-member-name"),
      member
        ? h(
            "button",
            {
              type: "button",
              class: "button button-quiet button-small",
              disabled: room.reachable === false,
              "aria-label": t("music.group.leaveLabel", { name: room.name }),
              dataset: { key: `${musicKey(room)}:leave` },
              onclick: () => leaveGroup(room),
            },
            t("music.group.leave")
          )
        : Number.isFinite(room.volume)
          ? h("span", { class: "device-meta" }, t("music.volumeLevel", { percent: room.volume }))
          : null
    ),
    member ? volumeControls(room) : null,
    inlineError(musicKey(room))
  );
}

// A group of rooms on a room's screen: what it plays once, its controls, a slider for the group
// and one per room (each room's own volume), Leave group per room.
export function groupCard(item) {
  const leader = groupLeader(item);
  const text = nowPlayingText(leader);
  const member = can("member");
  const volume = Number.isFinite(item.group?.volume) ? item.group.volume : null;
  const title = groupName(item);
  return h(
    "div",
    { class: `device music-card music-group ${isPlaying(leader) ? "is-playing" : ""} ${leader.reachable === false ? "is-unreachable" : ""}`.trim() },
    h(
      "div",
      { class: "music-main" },
      artTile(leader),
      h(
        "div",
        { class: "music-text" },
        name(title, "span", "device-name"),
        name(text.title, "span", "music-title"),
        text.detail ? name(text.detail, "span", "music-detail") : null,
        h("span", { class: "device-meta" }, [musicStateText(leader), !member && volume != null ? t("music.volumeLevel", { percent: volume }) : null].filter(Boolean).join(" · "))
      )
    ),
    member ? transportControls(leader) : null,
    member
      ? h(
          "div",
          { class: "music-group-volume" },
          h("span", { class: "music-group-label" }, icon("volume"), t("music.group.volume")),
          slider({
            label: t("music.group.volumeLabel", { rooms: title }),
            value: volume ?? 0,
            key: `${musicKey(leader)}:group-volume`,
            disabled: volume == null || leader.reachable === false,
            format: (value) => t("common.percent", { percent: value }),
            onCommit: (value) => setGroupVolume(leader, value),
          })
        )
      : null,
    h("ul", { class: "music-members", "aria-label": t("music.group.rooms", { rooms: title }) }, groupRooms(item).map((room) => memberRow(room))),
    member ? morePanel(leader) : null,
    favoritesPanel(leader),
    inlineError(musicKey(leader))
  );
}

// One Sonos room on its room screen (in a group of rooms: the group's card, groupCard).
export function musicCard(item) {
  if (isGrouped(item)) return groupCard(item);
  const text = nowPlayingText(item);
  const mates = groupMates(item);
  const member = can("member");
  const meta = [
    musicStateText(item),
    mates.length ? t("music.groupWith", { rooms: mates.map((mate) => isolate(mate.name)).join(", ") }) : null,
    !member && Number.isFinite(item.volume) ? t("music.volumeLevel", { percent: item.volume }) : null,
  ].filter(Boolean);
  return h(
    "div",
    { class: `device music-card ${isPlaying(item) ? "is-playing" : ""} ${item.reachable === false ? "is-unreachable" : ""}`.trim() },
    h(
      "div",
      { class: "music-main" },
      artTile(item),
      h(
        "div",
        { class: "music-text" },
        name(item.name, "span", "device-name"),
        name(text.title, "span", "music-title"),
        text.detail ? name(text.detail, "span", "music-detail") : null,
        h("span", { class: "device-meta" }, meta.join(" · "))
      )
    ),
    member ? transportControls(item) : null,
    member ? volumeControls(item) : null,
    member && groupsAvailable() ? (isPlaying(item) ? morePanel(item) : herePanel(item)) : null,
    favoritesPanel(item),
    inlineError(musicKey(item))
  );
}

// The Sonos rooms shown in a Control4 room (room.js): a group with more than one of them there
// has one card.
export function musicCards(items) {
  const shown = new Set();
  const cards = [];
  for (const item of items) {
    const id = isGrouped(item) ? `group:${item.group.id}` : item.id;
    if (shown.has(id)) continue;
    shown.add(id);
    cards.push(musicCard(item));
  }
  return cards;
}

// ---- Home ----------------------------------------------------------------------------------

function roomRank(roomId) {
  const index = state.rooms.findIndex((room) => room.id === roomId);
  return index < 0 ? state.rooms.length : index;
}

// The groups playing in rooms this person shows (`all`: in hidden rooms too), in the home's room
// order: one line each.
export function playingGroups({ all = false } = {}) {
  if (!musicAvailable()) return [];
  const hidden = all ? new Set() : hiddenRoomIds();
  const groups = new Map();
  for (const item of musicRooms()) {
    if (!isPlaying(item) || (item.room_id != null && hidden.has(item.room_id))) continue;
    const id = item.group?.id || item.id;
    const known = groups.get(id);
    // The coordinator stands for the group, or the first of its rooms shown.
    if (!known || (item.group?.coordinator && !known.group?.coordinator)) groups.set(id, item);
  }
  return [...groups.values()].sort((a, b) => roomRank(a.room_id) - roomRank(b.room_id) || String(a.name).localeCompare(String(b.name)));
}

// Home: "Music playing", one line per group, with its pause button for members.
export function musicHomeSection() {
  const groups = playingGroups();
  if (!groups.length) return null;
  return h(
    "section",
    { class: "home-section music-home", "aria-labelledby": "home-music-title" },
    h(
      "div",
      { class: "section-head" },
      // Focused after a Pause takes a line away (focusAfterPause).
      h("h2", { id: "home-music-title", class: "section-title", tabindex: "-1", dataset: { key: "home-music-title" } }, icon("music"), t("music.playingTitle"))
    ),
    h(
      "ul",
      { class: "device-list music-home-list" },
      groups.map((item) => {
        const text = nowPlayingText(item);
        const rooms = [item.name, ...groupMates(item).map((mate) => mate.name)];
        const where = item.room_id != null && roomById(item.room_id) ? roomName(roomById(item.room_id)) : null;
        const label = h(
          "span",
          { class: "music-text" },
          name(rooms.join(" + "), "span", "device-name"),
          name([text.title, text.detail].filter(Boolean).join(" · "), "span", "device-meta")
        );
        return h(
          "li",
          { class: "device music-home-row is-playing" },
          h(
            "div",
            { class: "music-main" },
            artTile(item, "is-small"),
            where ? h("a", { class: "music-home-link", href: `#/room/${item.room_id}`, title: where, dataset: { key: `${musicKey(item)}:room` } }, label) : label,
            can("member") ? transportControls(item, { compact: true }) : null
          ),
          inlineError(musicKey(item))
        );
      })
    )
  );
}

// ---- admins: the room of each Sonos room ---------------------------------------------------

// A name as the driver compares them (driver/src/sonos/rooms.lua): "Living Room", "living room"
// and "LivingRoom" are one name (Lua lowers only A to Z, and its spaces are ASCII ones).
function comparableName(text) {
  return String(text ?? "")
    .replace(/[A-Z]/g, (letter) => letter.toLowerCase())
    .replace(/[ \t\n\v\f\r]+/g, "");
}

// The room a Sonos room goes back to when its first choice is picked (PUT /v1/music/{id}/room with
// null): the one whose name, or one of its names in other languages, is the Sonos room's. null when
// none is, or more than one, as the driver decides (Rooms.match).
function sameNameRoom(item) {
  if (item.room_match === "name") return roomById(item.room_id);
  if (item.room_match !== "admin") return null;
  const wanted = comparableName(item.name);
  if (!wanted) return null;
  const found = state.rooms.filter((room) => [room.name, ...Object.values(room.names || {})].some((other) => comparableName(other) === wanted));
  return found.length === 1 ? found[0] : null;
}

// For Settings → Rooms (views/settings.js musicSection): every Sonos room with the Control4 room it is shown in, and a choice for
// those whose name matches none (or the wrong one). Admins only; null otherwise.
export function musicRoomsSection() {
  if (!musicAvailable() || !can("admin")) return null;
  const items = musicRooms();
  if (!items.length) return null;
  const unplaced = items.filter((item) => item.room_id == null);
  const sorted = [...unplaced, ...items.filter((item) => item.room_id != null)];
  // A card like Settings' others (views/settings.js card()), so #settings-music.
  return h(
    "section",
    { class: "card settings-card music-rooms", id: "settings-music", "aria-labelledby": "settings-music-title" },
    h("h2", { class: "settings-title", id: "settings-music-title" }, icon("music"), t("music.rooms.title")),
    h("p", { class: "field-help" }, t("music.rooms.help")),
    unplaced.length ? h("p", { class: "notice notice-info" }, t("music.rooms.unplaced", { count: unplaced.length })) : null,
    h(
      "ul",
      { class: "device-list music-rooms-list" },
      sorted.map((item) => {
        const id = `music-room-${item.id}`;
        // The first choice is null: back to the room of the same name, or in none when no room has it.
        const byName = sameNameRoom(item);
        const how =
          item.room_match === "admin"
            ? t("music.rooms.picked")
            : item.room_match === "name"
              ? t("music.rooms.matched")
              : t("music.rooms.none");
        return h(
          "li",
          { class: `device music-room ${item.room_id == null ? "is-unplaced" : ""}`.trim() },
          h(
            "div",
            { class: "device-main" },
            h("span", { class: "device-icon" }, icon("music")),
            h("div", { class: "device-text" }, h("label", { for: id }, name(item.name, "span", "device-name")), h("span", { class: "device-meta" }, how))
          ),
          h(
            "select",
            {
              id,
              class: "select music-room-select",
              dataset: { key: `${musicKey(item)}:place` },
              onchange: (event) => placeMusicRoom(item, event.target.value === "" ? null : Number(event.target.value)),
            },
            h(
              "option",
              { value: "", selected: item.room_match !== "admin" },
              byName ? t("music.rooms.sameName", { room: roomName(byName) }) : t("music.rooms.noneOption")
            ),
            state.rooms.map((room) =>
              h("option", { value: String(room.id), selected: item.room_match === "admin" && item.room_id === room.id }, roomName(room))
            )
          ),
          inlineError(`${musicKey(item)}:room`)
        );
      })
    )
  );
}
