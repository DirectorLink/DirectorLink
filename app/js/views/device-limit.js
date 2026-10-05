// "Remove a device first" (DirectorLink 1.9.0, ADR-061): a user has at most five devices, and every
// way of adding one (Add my other device, approving a device that asks to join, a pairing code for
// a user, moving a device, bringing an account's devices together) is refused with
// 409 USER_DEVICE_LIMIT. For a caller who sees that user the problem lists their devices, with when
// each was last used and whether the caller may remove it: this panel shows that list, with
// Remove where the controller says the caller may.

import { h } from "../dom.js";
import { formatRelative, t } from "../i18n.js";

// The problem of a refusal for a user who has five devices, or null.
export function deviceLimitOf(error) {
  return error?.code === "USER_DEVICE_LIMIT" && error.problem && typeof error.problem === "object" ? error.problem : null;
}

function lastUsed(device) {
  return device.last_used_at ? t("access.lastUsed", { time: formatRelative(device.last_used_at) }) : t("access.neverUsed");
}

// `problem`: the refusal's body. `remove(device)`: removes a device (DELETE /v1/api-keys/{id});
// `busy`: while something is being done. `key`: keeps its data-keys apart from another panel's.
export function deviceLimitPanel(problem, { remove, busy = false, key = "limit", dismiss } = {}) {
  if (!problem) return null;
  const name = problem.user?.name || "";
  const limit = Number(problem.limit) || 5;
  const devices = Array.isArray(problem.devices) ? problem.devices : null;
  return h(
    "div",
    { class: "notice notice-error device-limit", role: "alert", dataset: { key } },
    h("p", { class: "device-limit-title" }, name ? t("users.limit.title", { name, count: limit }) : t("users.limit.titleNoName", { count: limit })),
    devices
      ? h(
          "ul",
          { class: "access-list device-limit-list" },
          devices.map((device) =>
            h(
              "li",
              { class: "access-item", dataset: { key: `${key}-device-${device.id}` } },
              h(
                "div",
                { class: "access-main" },
                h("span", { class: "access-name", dir: "auto" }, device.name, device.current ? h("span", { class: "access-badge" }, t("access.thisDevice")) : null),
                h("span", { class: "access-sub" }, lastUsed(device))
              ),
              device.removable && remove
                ? h(
                    "div",
                    { class: "access-actions" },
                    h(
                      "button",
                      { type: "button", class: "button button-small button-danger", disabled: busy, "aria-label": t("users.removeDeviceFor", { name: device.name }), dataset: { key: `${key}-remove-${device.id}` }, onclick: () => remove(device) },
                      t("users.removeDevice")
                    )
                  )
                : null
            )
          )
        )
      : h("p", { class: "field-help" }, t("users.limit.askOnDevice")),
    devices && !devices.some((device) => device.removable) ? h("p", { class: "field-help" }, t("users.limit.askAdmin")) : null,
    dismiss ? h("div", { class: "button-row" }, h("button", { type: "button", class: "button button-quiet", dataset: { key: `${key}-dismiss` }, onclick: dismiss }, t("common.done"))) : null
  );
}
