// Find my controller, under the address field of the pairing screen (js/find.js): looks for
// DirectorLink at the addresses homes use most and puts the one it finds in the field. The person
// still types the pairing code and taps Connect. Not shown where pairing at home cannot work.

import { normalizeHost } from "../../api-client.js";
import { findControllers, findSupported, scanSettings } from "../find.js";
import { h } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { notify, state, subscribe, ui } from "../state.js";

const LOOKING = ["asking", "network", "range"];

let search = null; // the AbortController of the search under way

// What the address field shows (views/connect.js): what was typed, or the address used before.
const inField = () => ui.drafts.host ?? state.host;

// Once paired, what was found is done with: a later pairing screen (Pair again) starts afresh.
subscribe(() => {
  if (state.apiKey && ui.find && !search) ui.find = null;
});

function focusCode() {
  // After the redraw: the button that was pressed may be gone, and the code is what comes next.
  requestAnimationFrame(() => {
    const active = document.activeElement;
    if (!active || active === document.body || active.dataset?.key?.startsWith("find")) {
      document.getElementById("pairing-code")?.focus();
    }
  });
}

// Another address in the field (typed, or found): what was said about the one before (an error,
// or the warning that it cannot pair safely, views/connect.js) is not about this one.
export function addressChanged(value) {
  const stale = Boolean(state.pairingUnprotected) && state.pairingUnprotected.host !== normalizeHost(value);
  if (!state.notice && !stale) return;
  state.notice = null;
  if (stale) state.pairingUnprotected = null;
  notify();
}

function use(controller) {
  ui.drafts.host = controller.host;
  // Drafts are not part of what a redraw compares (app.js): this is.
  ui.find = { ...ui.find, chosen: controller.host };
  addressChanged(controller.host);
  notify();
  focusCode();
}

export function cancelFind() {
  search?.abort();
  search = null;
  ui.find = null;
  notify();
}

export async function startFind() {
  search?.abort();
  const mine = new AbortController();
  search = mine;
  const before = inField();
  ui.find = { stage: "network" };
  notify();
  const { outcome, controllers } = await findControllers({
    previous: state.host,
    ranges: scanSettings.ranges,
    port: scanSettings.port,
    signal: mine.signal,
    onProgress: (progress) => {
      // Paired meanwhile (the address was typed): there is nothing left to find.
      if (state.apiKey) mine.abort();
      if (search !== mine || mine.signal.aborted) return;
      ui.find = progress;
      notify();
    },
  });
  if (search !== mine) return;
  search = null;
  if (outcome === "cancelled" || state.apiKey) {
    ui.find = null;
  } else if (outcome === "blocked" || !controllers.length) {
    ui.find = { stage: outcome === "blocked" ? "blocked" : "none" };
  } else {
    ui.find = { stage: "found", controllers };
    // One found, and the field left as it was: it goes in. Otherwise the person picks.
    if (controllers.length === 1 && inField() === before) use(controllers[0]);
  }
  notify();
}

function describe(controller) {
  return controller.version ? t("connect.find.product", { version: controller.version }) : "DirectorLink";
}

function status(find) {
  if (LOOKING.includes(find.stage)) {
    const text = find.stage === "range" ? t("connect.find.range", { range: `${find.range}.x` }) : t(`connect.find.${find.stage}`);
    return h("p", { class: "field-help connect-find-progress", role: "status" }, text);
  }
  if (find.stage === "blocked" || find.stage === "none") {
    return h("p", { class: "notice notice-error", role: "status", id: "find-result" }, t(`connect.find.${find.stage}`));
  }
  const [only] = find.controllers;
  if (find.controllers.length === 1 && inField() === only.host) {
    return h("p", { class: "notice notice-success", role: "status", id: "find-result" }, t("connect.find.found", { name: describe(only), host: only.host }));
  }
  return h(
    "div",
    { class: "connect-find-results", id: "find-result" },
    h("p", { class: "field-help", role: "status" }, t("connect.find.several", { count: find.controllers.length })),
    h(
      "ul",
      { class: "connect-find-list" },
      find.controllers.map((controller) => {
        const chosen = inField() === controller.host;
        return h(
          "li",
          {},
          h(
            "button",
            {
              type: "button",
              class: "button button-secondary button-wide connect-find-choice",
              "aria-pressed": chosen ? "true" : "false",
              dataset: { key: `find-use-${controller.host}` },
              onclick: () => use(controller),
            },
            chosen ? icon("check") : null,
            h("span", { dir: "ltr" }, controller.host),
            h("span", { class: "connect-find-version" }, describe(controller))
          )
        );
      })
    )
  );
}

// The button, what the search is doing, and what it found. null where it cannot work.
export function findController({ busy = false } = {}) {
  if (!findSupported()) return null;
  const find = ui.find;
  const looking = Boolean(find && LOOKING.includes(find.stage));
  return h(
    "div",
    { class: "connect-find" },
    h(
      "button",
      {
        type: "button",
        class: "button button-secondary",
        id: "find-controller",
        disabled: busy && !looking,
        // One button, so focus stays on it: Find my controller, then Cancel while looking.
        dataset: { key: "find-controller" },
        onclick: looking ? cancelFind : startFind,
      },
      looking ? t("connect.find.cancel") : t("connect.find.button")
    ),
    find ? status(find) : null
  );
}
