// Climate: every thermostat, grouped by room, with the same quick controls as the room screen.

import { emptyState, skeletonCards, thermostatCard } from "../components.js";
import { h, name } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { deviceRoomId, roomName } from "../model.js";
import { can, state } from "../state.js";
import { isLoading, notReadyState, offlineBanner, pageHeader, staleBanner } from "./common.js";

export function climateView() {
  const header = pageHeader({ title: t("climate.title") });
  const notReady = notReadyState();
  if (notReady) return [header, notReady];
  if (isLoading()) return [header, h("div", { class: "climate-groups", "aria-busy": "true" }, skeletonCards(2))];
  if (!state.thermostats.length) {
    return [header, emptyState("climate", t("climate.emptyTitle"), t("climate.emptyText"))];
  }

  // Rooms in Control4 order; thermostats without a room last.
  const order = new Map(state.rooms.map((room, index) => [room.id, index]));
  const groups = new Map();
  for (const thermostat of state.thermostats) {
    const id = deviceRoomId(thermostat);
    if (!groups.has(id)) groups.set(id, { room: thermostat.room, items: [] });
    groups.get(id).items.push(thermostat);
  }
  const sorted = [...groups.entries()].sort(([a], [b]) => (order.get(a) ?? 1e9) - (order.get(b) ?? 1e9));

  return [
    header,
    offlineBanner(),
    staleBanner(),
    !can("member") ? h("p", { class: "view-only-hint" }, icon("info"), h("span", {}, t("roles.viewOnlyHint"))) : null,
    h(
      "div",
      { class: "climate-groups" },
      sorted.map(([id, group]) =>
        h(
          "section",
          { class: "climate-group" },
          h(
            "div",
            { class: "section-head" },
            h("h2", { class: "section-title" }, icon("rooms"), name(roomName(group.room))),
            id ? h("a", { class: "button button-quiet button-small", href: `#/room/${id}` }, t("climate.openRoom"), icon("chevronForward")) : null
          ),
          h("div", { class: "device-list" }, group.items.map((thermostat) => thermostatCard(thermostat)))
        )
      )
    ),
  ];
}
