// People and devices (#/access, admin keys): the home's API keys with their roles, the invitations
// waiting to be accepted, and, for the home's owner, the accounts that belong to the home with the
// devices each uses (docs/ACCOUNTS.md). Devices and invitations come from the controller; people
// from the account service, which never sees the keys, only their ids.

import { h } from "../dom.js";
import { formatDateTime, formatRelative, t } from "../i18n.js";
import { icon } from "../icons.js";
import { listMembers, removeMember, savedRemote } from "../remote.js";
import { api, errorText, roleLabel } from "../session.js";
import { can, notify, state, ui } from "../state.js";
import { notReadyState, offlineBanner, pageHeader } from "./common.js";

const ROLES = ["viewer", "member", "doors", "admin"];
const REFRESH_MS = 30000;
let loading = false;

function failure(error) {
  return { error: errorText(error) };
}

// Loads what the screen shows into ui.access; the screen refreshes it every 30 s while open.
export async function loadAccess() {
  if (loading) return;
  loading = true;
  const home = savedRemote()?.home || state.remoteInfo?.home_id || null;
  const [devices, invitations, people] = await Promise.all([
    api("/v1/api-keys").then((answer) => answer?.items || [], failure),
    // Drivers before 0.10.0 have no invitations.
    api("/v1/invitations").then((answer) => answer?.items || [], (error) => (error?.status === 404 || error?.status === 405 ? [] : failure(error))),
    // Only the home's owner sees who belongs to it.
    home && state.account.status === "signed-in"
      ? listMembers(home).then(
          (answer) => answer?.items || [],
          (error) => (error?.code === "OWNER_ONLY" || error?.code === "NOT_A_MEMBER" ? null : failure(error))
        )
      : Promise.resolve(null),
  ]);
  ui.access = { ...(ui.access || {}), at: Date.now(), home, devices, invitations, people };
  loading = false;
  notify();
}

async function act(work, done) {
  ui.access = { ...ui.access, busy: true, message: null };
  notify();
  try {
    await work();
    ui.access.message = { kind: "success", text: done };
  } catch (error) {
    ui.access.message = { kind: "error", text: error?.code === "LAST_ADMIN" ? t("access.lastAdmin") : errorText(error) };
  } finally {
    ui.access.busy = false;
    await loadAccess();
  }
}

// Revoking a key: it stops working at home and away at once; an account whose last key it was
// leaves the home (the controller tells the account service).
function revokeDevice(device) {
  if (!window.confirm(t("access.revokeConfirm", { name: device.name }))) return;
  act(() => api(`/v1/api-keys/${device.id}`, { method: "DELETE" }), t("access.revoked", { name: device.name }));
}

function changeRole(device, role) {
  act(() => api(`/v1/api-keys/${device.id}`, { method: "PATCH", body: { role } }), t("access.roleChanged", { name: device.name, role: roleLabel(role) }));
}

function revokeInvitation(invitation) {
  if (!window.confirm(t("access.revokeInvitationConfirm"))) return;
  act(() => api(`/v1/invitations/${invitation.id}`, { method: "DELETE" }), t("access.invitationRevoked"));
}

// Removing a person: their keys are revoked at home first, then the account leaves the home.
function removePerson(person) {
  const name = person.name || person.email;
  if (!window.confirm(t("access.removeConfirm", { name, count: person.key_ids.length }))) return;
  act(async () => {
    for (const id of person.key_ids) {
      await api(`/v1/api-keys/${id}`, { method: "DELETE" }).catch((error) => {
        if (error?.status !== 404) throw error;
      });
    }
    await removeMember(ui.access.home, person.user_id);
  }, t("access.removed", { name }));
}

function section(id, title, help, content) {
  return h(
    "section",
    { class: "card settings-card", id: `access-${id}`, "aria-labelledby": `access-${id}-title` },
    h("h2", { class: "settings-title", id: `access-${id}-title` }, icon(id === "people" ? "user" : id === "devices" ? "key" : "plus"), title),
    help ? h("p", { class: "field-help" }, help) : null,
    content
  );
}

function problemNote(value) {
  return value && !Array.isArray(value) && value.error ? h("p", { class: "notice notice-error", role: "status" }, value.error) : null;
}

function lastUsed(device) {
  return device.last_used_at ? t("access.lastUsed", { time: formatRelative(device.last_used_at) }) : t("access.neverUsed");
}

function deviceRow(device, owners) {
  const busy = Boolean(ui.access.busy);
  const owner = owners.get(device.id);
  const role = h(
    "select",
    { class: "access-role", "aria-label": t("access.roleFor", { name: device.name }), disabled: busy || device.current, dataset: { key: `access-role-${device.id}` } },
    ...ROLES.map((value) => h("option", { value, selected: value === device.role }, roleLabel(value)))
  );
  role.addEventListener("change", () => changeRole(device, role.value));
  return h(
    "li",
    { class: "access-item", dataset: { key: `access-device-${device.id}` } },
    h(
      "div",
      { class: "access-main" },
      h("span", { class: "access-name", dir: "auto" }, device.name, device.current ? h("span", { class: "access-badge" }, t("access.thisDevice")) : null),
      h("span", { class: "access-sub", dir: "auto" }, [owner ? owner.name || owner.email : t("access.homeNetworkOnly"), lastUsed(device)].join(" · "))
    ),
    h(
      "div",
      { class: "access-actions" },
      role,
      device.current
        ? null
        : h("button", { type: "button", class: "button button-small button-danger", disabled: busy, dataset: { key: `access-revoke-${device.id}` }, onclick: () => revokeDevice(device) }, t("access.revoke"))
    )
  );
}

function personRow(person, devices) {
  const names = person.key_ids.map((id) => devices.find((device) => device.id === id)?.name).filter(Boolean);
  return h(
    "li",
    { class: "access-item", dataset: { key: `access-person-${person.user_id}` } },
    h(
      "div",
      { class: "access-main" },
      h("span", { class: "access-name", dir: "auto" }, person.name || person.email, person.owner ? h("span", { class: "access-badge" }, t("access.owner")) : null),
      h("span", { class: "access-sub", dir: "auto" }, [person.name ? person.email : null, names.length ? names.join(", ") : t("access.noDevices")].filter(Boolean).join(" · "))
    ),
    person.owner
      ? null
      : h(
          "div",
          { class: "access-actions" },
          h("button", { type: "button", class: "button button-small button-danger", disabled: Boolean(ui.access.busy), dataset: { key: `access-remove-${person.user_id}` }, onclick: () => removePerson(person) }, t("access.remove"))
        )
  );
}

function invitationRow(invitation, devices) {
  const maker = devices.find((device) => device.id === invitation.created_by)?.name;
  return h(
    "li",
    { class: "access-item", dataset: { key: `access-invitation-${invitation.id}` } },
    h(
      "div",
      { class: "access-main" },
      h("span", { class: "access-name" }, roleLabel(invitation.role)),
      h("span", { class: "access-sub", dir: "auto" }, [t("access.expires", { time: formatDateTime(new Date(invitation.expires_at)) }), maker ? t("access.madeBy", { name: maker }) : null].filter(Boolean).join(" · "))
    ),
    h(
      "div",
      { class: "access-actions" },
      h("button", { type: "button", class: "button button-small button-secondary", disabled: Boolean(ui.access.busy), dataset: { key: `access-revoke-invitation-${invitation.id}` }, onclick: () => revokeInvitation(invitation) }, t("access.revoke"))
    )
  );
}

export function accessView() {
  const header = pageHeader({ title: t("access.title"), back: "#/settings" });
  if (!state.loaded) {
    return [header, notReadyState()];
  }
  if (!can("admin")) {
    return [header, h("div", { class: "settings" }, h("p", { class: "notice notice-info" }, t("access.adminOnly", { role: roleLabel(state.role) })))];
  }
  const access = ui.access;
  if (!access?.at || Date.now() - access.at > REFRESH_MS) {
    loadAccess();
  }
  if (!access?.at) {
    return [header, h("div", { class: "settings" }, h("p", { class: "field-help", role: "status" }, t("common.loading")))];
  }
  const devices = Array.isArray(access.devices) ? access.devices : [];
  const people = Array.isArray(access.people) ? access.people : null;
  // Which account uses which key (the owner's view only).
  const owners = new Map();
  for (const person of people || []) {
    for (const id of person.key_ids || []) owners.set(id, person);
  }
  const invitations = Array.isArray(access.invitations) ? access.invitations : [];
  return [
    header,
    offlineBanner(),
    h(
      "div",
      { class: "settings" },
      access.message ? h("p", { class: `notice notice-${access.message.kind}`, role: access.message.kind === "error" ? "alert" : "status" }, access.message.text) : null,
      people
        ? section("people", t("access.people"), t("access.peopleHelp"), h("ul", { class: "access-list" }, people.map((person) => personRow(person, devices))))
        : access.home && state.account.status === "signed-in"
          ? problemNote(access.people) || h("p", { class: "field-help" }, t("access.ownerOnly"))
          : null,
      section(
        "devices",
        t("access.devices"),
        t("access.devicesHelp"),
        problemNote(access.devices) || h("ul", { class: "access-list" }, devices.map((device) => deviceRow(device, owners)))
      ),
      section(
        "invitations",
        t("access.invitations"),
        invitations.length ? null : t("access.noInvitations"),
        problemNote(access.invitations) || (invitations.length ? h("ul", { class: "access-list" }, invitations.map((invitation) => invitationRow(invitation, devices))) : null)
      )
    ),
  ];
}
