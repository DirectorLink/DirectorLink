// Music (js/music.js, ADR-044): each Sonos room's card on its room screen, what plays on Home, and
// for admins the Sonos rooms with the Control4 room each is shown in (musicRoomsSection, on Settings
// → Rooms). A group plays as one: play, pause and skip on any of its rooms work on the group;
// volume and mute are each room's own. Playback controls stay left to right in Hebrew too.

import { inlineError, slider } from "../components.js";
import { h, iconButton, name } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { hiddenRoomIds, roomById, roomName } from "../model.js";
import {
  groupMates,
  isPlaying,
  loadFavorites,
  musicArt,
  musicAvailable,
  musicCommand,
  musicFavorites,
  musicKey,
  musicRooms,
  placeMusicRoom,
  playFavorite,
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

function transportControls(item, { compact = false } = {}) {
  const playing = isPlaying(item);
  const off = item.reachable === false;
  const skip = item.can_skip && !off;
  const button = (iconName, label, action, extra = {}) =>
    iconButton(iconName, label, {
      class: `music-button ${extra.main ? "music-main-button" : ""}`.trim(),
      disabled: extra.disabled,
      dataset: { key: `${musicKey(item)}:${action}${compact ? ":home" : ""}` },
      onclick: () => musicCommand(item, action),
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

function favoritesPanel(item) {
  const loaded = musicFavorites(item);
  let body;
  if (!loaded || loaded.stage === "loading") {
    body = h("p", { class: "muted-note", role: "status" }, t("common.loading"));
  } else if (loaded.stage === "error") {
    body = h("p", { class: "inline-error", role: "alert" }, loaded.text);
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
  return h(
    "details",
    {
      class: "music-favorites",
      dataset: { key: `${musicKey(item)}:favorites` },
      ontoggle: (event) => {
        if (event.target.open && musicFavorites(item)?.stage !== "ready") loadFavorites(item);
      },
    },
    h("summary", {}, icon("star"), t("music.favorites.title")),
    body
  );
}

// One Sonos room on its room screen.
export function musicCard(item) {
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
    favoritesPanel(item),
    inlineError(musicKey(item))
  );
}

// The Sonos rooms shown in a Control4 room (room.js).
export function musicCards(items) {
  return items.map((item) => musicCard(item));
}

// ---- Home ----------------------------------------------------------------------------------

function roomRank(roomId) {
  const index = state.rooms.findIndex((room) => room.id === roomId);
  return index < 0 ? state.rooms.length : index;
}

// The groups playing in rooms this person shows, in the home's room order: one line each.
export function playingGroups() {
  if (!musicAvailable()) return [];
  const hidden = hiddenRoomIds();
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
    h("div", { class: "section-head" }, h("h2", { id: "home-music-title", class: "section-title" }, icon("music"), t("music.playingTitle"))),
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
        const byName = item.room_match === "name" ? item.room_id : null;
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
              byName != null && roomById(byName) ? t("music.rooms.sameName", { room: roomName(roomById(byName)) }) : t("music.rooms.noneOption")
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
