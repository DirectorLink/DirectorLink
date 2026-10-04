// A person's role and, for a member, what they may see and do (DirectorLink 1.8.0, ADR-054): the
// editor that Settings → People and devices and Invite someone show. `draft` is an access object as
// GET /v1/profiles/{id}/access answers it (role, all_rooms, rooms, kinds, cameras, doors, alarm,
// scenes); the editor changes it in place and calls `changed()` after each change. The controller
// enforces all of it: the app only shows a member what they may use.

import { h, name } from "../dom.js";
import { t } from "../i18n.js";
import { roomName } from "../model.js";
import { state } from "../state.js";

// The kinds of devices a member may be given, as the controller names them.
export const KINDS = ["light", "climate", "fan", "blind", "music", "refrigerator"];

// The controller has admins and members (GET /v1/system features); older ones four roles per key.
export function peopleSupported() {
  return state.system?.features?.people_permissions === true;
}

// A new member: every room and kind, cameras and the alarm's status, no doors, no scenes.
export function newMemberAccess() {
  return { role: "member", all_rooms: true, rooms: [], kinds: Object.fromEntries(KINDS.map((kind) => [kind, true])), cameras: true, doors: false, alarm: true, scenes: [] };
}

// A copy to edit, with every field there.
export function copyAccess(access) {
  const base = newMemberAccess();
  const source = access && typeof access === "object" ? access : {};
  return {
    role: source.role === "admin" ? "admin" : "member",
    all_rooms: typeof source.all_rooms === "boolean" ? source.all_rooms : base.all_rooms,
    rooms: Array.isArray(source.rooms) ? [...source.rooms] : [],
    kinds: Object.fromEntries(KINDS.map((kind) => [kind, typeof source.kinds?.[kind] === "boolean" ? source.kinds[kind] : true])),
    cameras: typeof source.cameras === "boolean" ? source.cameras : base.cameras,
    doors: source.doors === true,
    alarm: typeof source.alarm === "boolean" ? source.alarm : base.alarm,
    scenes: Array.isArray(source.scenes) ? [...source.scenes] : [],
  };
}

// What PATCH /v1/profiles/{id}/access and an invitation's `access` take (an admin's role alone).
export function accessBody(draft) {
  if (draft.role === "admin") return { role: "admin" };
  const rooms = new Set(state.rooms.map((room) => room.id));
  const scenes = new Set((state.scenes || []).map((scene) => scene.id));
  return {
    role: "member",
    all_rooms: draft.all_rooms,
    // Only rooms and scenes the controller still has (one removed meanwhile would be refused).
    rooms: draft.rooms.filter((id) => rooms.has(id)),
    kinds: { ...draft.kinds },
    cameras: draft.cameras,
    doors: draft.doors,
    alarm: draft.alarm,
    scenes: draft.scenes.filter((id) => scenes.has(id)),
  };
}

// "All rooms", "2 rooms · lights, climate · cameras": what a member may do, in a line.
export function accessSummary(access) {
  if (!access || access.role === "admin") return t("perm.summaryAdmin");
  const parts = [access.all_rooms ? t("perm.allRooms") : t("perm.roomCount", { count: (access.rooms || []).length })];
  const kinds = KINDS.filter((kind) => access.kinds?.[kind]);
  parts.push(kinds.length === KINDS.length ? t("perm.allKinds") : kinds.length ? kinds.map((kind) => t(`perm.kindShort.${kind}`)).join(", ") : t("perm.noKinds"));
  if (access.cameras) parts.push(t("perm.summaryCameras"));
  if (access.doors) parts.push(t("perm.summaryDoors"));
  parts.push(t("perm.sceneCount", { count: (access.scenes || []).length }));
  return parts.join(" · ");
}

function checkRow(id, label, checked, onchange, meta) {
  return h(
    "li",
    { class: "pick-item" },
    h("input", { type: "checkbox", id, checked, dataset: { key: id }, onchange: (event) => onchange(event.target.checked) }),
    h("label", { for: id, class: "pick-label" }, label, meta ? h("span", { class: "device-meta" }, meta) : null)
  );
}

function switchRow(id, title, help, on, set) {
  return h(
    "div",
    { class: "toggle-row perm-toggle" },
    h("span", { class: "toggle-text" }, h("span", { class: "toggle-title", id: `${id}-label` }, title), help ? h("span", { class: "field-help", id: `${id}-help` }, help) : null),
    h(
      "button",
      {
        type: "button",
        role: "switch",
        class: "switch",
        "aria-checked": String(on),
        "aria-labelledby": `${id}-label`,
        "aria-describedby": help ? `${id}-help` : null,
        dataset: { key: id },
        onclick: () => set(!on),
      },
      h("span", { class: "switch-thumb" })
    )
  );
}

function toggleIn(list, value, on) {
  const without = list.filter((item) => item !== value);
  return on ? [...without, value] : without;
}

// The editor: the role, then (members) rooms, kinds, cameras, doors and gates, the alarm and the
// scenes they may run. `prefix` keeps its ids apart from another editor's; `lockedRole` (the home's
// owner, always an admin) shows the role without a choice.
export function permissionsEditor(draft, { prefix = "perm", changed, lockedRole = false } = {}) {
  const update = (change) => {
    change();
    changed?.();
  };
  const roleChoice = (value) =>
    h(
      "label",
      { class: `perm-role ${draft.role === value ? "is-active" : ""}`.trim() },
      h("input", {
        type: "radio",
        name: `${prefix}-role`,
        value,
        checked: draft.role === value,
        disabled: lockedRole,
        dataset: { key: `${prefix}-role:${value}` },
        onchange: () => update(() => (draft.role = value)),
      }),
      h("span", { class: "toggle-text" }, h("span", { class: "toggle-title" }, t(`perm.${value}`)), h("span", { class: "field-help" }, t(`perm.${value}Help`)))
    );
  const parts = [
    h("fieldset", { class: "perm-roles" }, h("legend", { class: "settings-subtitle" }, t("perm.role")), roleChoice("admin"), roleChoice("member")),
    lockedRole ? h("p", { class: "field-help" }, t("perm.ownerNote")) : null,
  ];
  if (draft.role !== "member" || lockedRole) return parts;

  const hiddenNote = state.rooms.some((room) => room.hidden_from_members) ? t("perm.roomsHiddenNote") : null;
  parts.push(
    h(
      "fieldset",
      { class: "perm-group" },
      h("legend", { class: "settings-subtitle" }, t("perm.rooms")),
      h(
        "ul",
        { class: "pick-list" },
        checkRow(`${prefix}-all-rooms`, h("span", { class: "device-name" }, t("perm.allRooms")), draft.all_rooms, (on) => update(() => (draft.all_rooms = on))),
        draft.all_rooms
          ? null
          : state.rooms.map((room) =>
              checkRow(
                `${prefix}-room-${room.id}`,
                name(roomName(room), "span", "device-name"),
                draft.rooms.includes(room.id),
                (on) => update(() => (draft.rooms = toggleIn(draft.rooms, room.id, on))),
                room.hidden_from_members ? t("perm.hiddenFromMembers") : null
              )
            )
      ),
      hiddenNote ? h("p", { class: "field-help" }, hiddenNote) : null
    ),
    h(
      "fieldset",
      { class: "perm-group" },
      h("legend", { class: "settings-subtitle" }, t("perm.kinds")),
      h("p", { class: "field-help" }, t("perm.kindsHelp")),
      h(
        "ul",
        { class: "pick-list" },
        KINDS.map((kind) =>
          checkRow(`${prefix}-kind-${kind}`, h("span", { class: "device-name" }, t(`perm.kind.${kind}`)), draft.kinds[kind] === true, (on) => update(() => (draft.kinds[kind] = on)))
        )
      )
    ),
    switchRow(`${prefix}-cameras`, t("perm.cameras"), t("perm.camerasHelp"), draft.cameras, (on) => update(() => (draft.cameras = on))),
    switchRow(`${prefix}-doors`, t("perm.doors"), t("perm.doorsHelp"), draft.doors, (on) => update(() => (draft.doors = on))),
    switchRow(`${prefix}-alarm`, t("perm.alarm"), t("perm.alarmHelp"), draft.alarm, (on) => update(() => (draft.alarm = on)))
  );
  const scenes = state.scenes || [];
  parts.push(
    h(
      "fieldset",
      { class: "perm-group" },
      h("legend", { class: "settings-subtitle" }, t("perm.scenes")),
      h("p", { class: "field-help" }, t("perm.scenesHelp")),
      scenes.length
        ? h(
            "ul",
            { class: "pick-list" },
            scenes.map((scene) =>
              checkRow(`${prefix}-scene-${scene.id}`, name(scene.name, "span", "device-name"), draft.scenes.includes(scene.id), (on) => update(() => (draft.scenes = toggleIn(draft.scenes, scene.id, on))))
            )
          )
        : h("p", { class: "muted-note" }, state.scenes === null ? t("common.loading") : t("perm.noScenes"))
    )
  );
  return parts;
}
