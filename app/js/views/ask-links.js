// Ask before opening (ADR-058, docs/SCENES.md; js/ask-links.js): a door's link for the phone's own
// automations that asks its person before the door opens. Its screen (#/door/<id>/ask, from the
// door's row in its room, or from Scenes → Links for automations) makes, replaces and removes this
// device's link for the door and shows a new link's secret once, with Copy buttons and short steps
// for iPhone Shortcuts (Arrive), Siri, Android and Google Assistant. The question itself
// (#/open/<door>/<request>/<until>) is what an alert's tap opens: "Open the main gate?", with Open
// and Cancel. Shown when the controller has them (features.ask_links, 1.8.0), to keys that may
// open doors; the controller checks every step again.

import { emptyState } from "../components.js";
import { h, name } from "../dom.js";
import { formatClock, formatDateTime, t } from "../i18n.js";
import { icon } from "../icons.js";
import { alertsOn } from "../alerts.js";
import { roomName } from "../model.js";
import { isolate } from "../scenes.js";
import { roleLabel } from "../session.js";
import { can, findDevice, notify, state, ui } from "../state.js";
import { notReadyState, offlineBanner, pageHeader } from "./common.js";
import { copyButton, freshSteps, voiceHelp } from "./scene-links.js";
import {
  answerRequest,
  askAddress,
  askLinkOf,
  askLinksSupported,
  askState,
  askUrl,
  ensureAskLinks,
  forgetAskMade,
  madeAskLink,
  makeAskLink,
  openRequestState,
  removeAskLink,
  requestOver,
} from "../ask-links.js";

export const askHash = (relayId) => `#/door/${relayId}/ask`;

// The label being typed for a door's next link: kept here, so typing is never redrawn.
const labels = {};

const date = (iso) => (iso ? formatDateTime(new Date(iso)) : "");

function notice(kind, text, key) {
  return h("p", { class: `notice notice-${kind}`, role: kind === "error" ? "alert" : "status", dataset: key ? { key } : undefined }, text);
}

function relayOf(relayId) {
  return findDevice("relay", relayId);
}

// What the phone says to Siri for a door: "Open Main gate".
function phraseOf(relay) {
  return t("askLinks.phrase", { name: relay?.name || t("askLinks.theDoor") });
}

// ---- what a link needs ------------------------------------------------------------------------------

function requirements(links) {
  const notes = [];
  if (!links.remoteAccess) notes.push(notice("error", t("askLinks.errors.remoteOff"), "ask-link-remote-off"));
  else if (!links.homeLinked) notes.push(notice("error", t("askLinks.errors.notLinked"), "ask-link-not-linked"));
  if (!links.doorControl) notes.push(notice("error", t("askLinks.errors.doorsOff"), "ask-link-doors-off"));
  // The question comes as an alert: this device must have them on.
  if (!alertsOn()) {
    notes.push(
      h(
        "p",
        { class: "notice notice-info", dataset: { key: "ask-link-alerts" } },
        t("askLinks.alertsNeeded"),
        " ",
        h("a", { href: "#/settings/controller" }, t("askLinks.alertsLink"))
      )
    );
  }
  return notes;
}

// ---- the door's link screen (#/door/<id>/ask) ------------------------------------------------------

function freshLink(relay, link) {
  const address = askAddress(link);
  const url = askUrl(link);
  const links = askState();
  const copy = (text, key, label) => copyButton(text, key, label, links);
  const failed = String(links.copied || "").endsWith(":failed");
  return h(
    "div",
    { class: "scene-link-fresh", dataset: { key: "ask-link-fresh" } },
    notice("success", link.replaced ? t("askLinks.replacedOnce") : t("askLinks.madeOnce"), "ask-link-made"),
    failed ? notice("error", t("sceneLinks.copyFailed")) : null,
    h("p", { class: "field-help" }, t("askLinks.privacy", { name: isolate(relay.name) })),
    ...freshSteps({
      key: "ask-link",
      copyAddress: (key) => copy(address, key, t("sceneLinks.copyAddress")),
      copySecret: (key) => copy(link.secret, key, t("sceneLinks.copySecret")),
      iphone: [t("askLinks.iphone.action"), t("sceneLinks.iphone.url"), t("sceneLinks.iphone.body"), t("askLinks.iphone.immediately", { name: isolate(relay.name) })],
      iphoneTitle: t("askLinks.iphone.title"),
    }),
    ...voiceHelp({ phrase: phraseOf(relay), key: "ask-link", ask: true }),
    h(
      "details",
      { class: "card scene-section scene-link-how", dataset: { key: "ask-link-browser" } },
      h("summary", {}, t("askLinks.browser.title")),
      h("p", {}, t("askLinks.browser.text")),
      h("input", { class: "invitation-link", type: "text", readonly: true, dir: "ltr", value: url, "aria-label": t("sceneLinks.linkTitle"), dataset: { key: "ask-link-url" }, onfocus: (event) => event.target.select() }),
      h("div", { class: "button-row" }, copy(url, "ask-link-copy-url", t("sceneLinks.copyLink")))
    ),
    h("p", { class: "field-help scene-link-address", dir: "ltr" }, address),
    h(
      "div",
      { class: "scene-actions" },
      h(
        "button",
        {
          type: "button",
          class: "button button-primary",
          dataset: { key: "ask-link-done" },
          onclick: () => {
            forgetAskMade(relay.id);
            askState().copied = null;
            notify();
          },
        },
        t("common.done")
      )
    )
  );
}

function labelField(relayId, current = "") {
  return h(
    "div",
    { class: "field" },
    h("label", { class: "field-label", for: "ask-link-label" }, t("sceneLinks.label")),
    h("input", {
      id: "ask-link-label",
      type: "text",
      maxlength: "64",
      dir: "auto",
      autocomplete: "off",
      value: labels[relayId] ?? current,
      placeholder: t("sceneLinks.labelPlaceholder"),
      dataset: { key: "ask-link-label" },
      oninput: (event) => {
        labels[relayId] = event.target.value;
      },
    }),
    h("p", { class: "field-help" }, t("askLinks.labelHelp"))
  );
}

async function make(relayId, replacing) {
  if (replacing && !window.confirm(t("askLinks.replaceConfirm"))) return;
  askState().copied = null;
  const link = await makeAskLink(relayId, labels[relayId] ?? (replacing ? askLinkOf(relayId)?.label || "" : ""));
  if (link) delete labels[relayId];
}

async function remove(relayId, link) {
  if (!window.confirm(t("askLinks.removeConfirm"))) return;
  forgetAskMade(relayId);
  await removeAskLink(link.link_id, relayId);
}

export function askLinkView(relayId) {
  const relay = relayOf(relayId);
  const back = relay?.room?.id ?? relay?.room_id;
  const header = pageHeader({ title: t("askLinks.screenTitle"), back: back ? `#/room/${back}` : "#/" });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (!state.loaded) return [header, h("p", { class: "field-help", role: "status" }, t("common.loading"))];
  if (!askLinksSupported()) return [header, emptyState("door", t("askLinks.title"), t("askLinks.updateDriver"))];
  if (!relay) return [header, emptyState("door", t("askLinks.notFound"), "", h("a", { class: "button button-primary", href: "#/" }, t("nav.home")))];
  if (!can("doors")) return [header, notice("info", t("askLinks.noAccess", { name: relay.name, role: roleLabel(state.role) }))];
  const links = ensureAskLinks();
  const fresh = madeAskLink(relay.id);
  const link = askLinkOf(relay.id);
  const busy = links.busy === relay.id || (link && links.busy === link.link_id);
  const message = links.message?.at === relay.id ? links.message : null;
  const body = [
    h("p", { class: "scene-link-scene" }, h("span", { class: "scene-icon", "aria-hidden": "true" }, icon("door")), name(relay.name, "strong"), relay.room ? h("span", { class: "field-help" }, ` · ${roomName(relay.room)}`) : null),
    message ? notice(message.kind, message.text, "ask-link-message") : null,
  ];
  if (fresh) {
    body.push(freshLink(relay, fresh));
  } else if (!links.loaded) {
    body.push(h("p", { class: "field-help", role: "status" }, t("common.loading")));
  } else if (links.error) {
    body.push(notice("error", links.error));
  } else if (link) {
    body.push(
      h(
        "div",
        { class: "card scene-section" },
        h(
          "dl",
          { class: "facts", dataset: { key: "ask-link-facts" } },
          h("div", { class: "fact" }, h("dt", {}, t("sceneLinks.nameTitle")), h("dd", { dir: "auto" }, link.label || t("sceneLinks.noLabel"))),
          h("div", { class: "fact" }, h("dt", {}, t("sceneLinks.made")), h("dd", {}, date(link.created_at))),
          h("div", { class: "fact" }, h("dt", {}, t("sceneLinks.lastRunTitle")), h("dd", {}, link.last_used_at ? date(link.last_used_at) : t("sceneLinks.never")))
        )
      ),
      h("p", { class: "field-help" }, t("sceneLinks.lostSecret")),
      h("p", { class: "field-help", dataset: { key: "ask-link-voice" } }, t("askLinks.voiceHint", { phrase: isolate(phraseOf(relay)) })),
      ...requirements(links),
      labelField(relay.id, link.label || ""),
      h(
        "div",
        { class: "scene-actions" },
        h("button", { type: "button", class: "button button-secondary", disabled: busy || !links.remoteAccess || !links.homeLinked || !links.doorControl, dataset: { key: "ask-link-replace" }, onclick: () => make(relay.id, true) }, icon("refresh"), t("sceneLinks.replace")),
        h("button", { type: "button", class: "button button-danger", disabled: busy, dataset: { key: "ask-link-remove" }, onclick: () => remove(relay.id, link) }, t("sceneLinks.remove"))
      )
    );
  } else {
    const blocked = !links.remoteAccess || !links.homeLinked || !links.doorControl;
    body.push(
      h("p", {}, t("askLinks.intro", { name: isolate(relay.name) })),
      h("p", { class: "field-help" }, t("askLinks.introSafety")),
      ...requirements(links),
      labelField(relay.id),
      h(
        "div",
        { class: "scene-actions" },
        h("button", { type: "button", class: "button button-primary", disabled: busy || blocked, dataset: { key: "ask-link-make" }, onclick: () => make(relay.id, false) }, icon("link"), busy ? t("sceneLinks.making") : t("sceneLinks.make"))
      )
    );
  }
  return [header, offlineBanner(), h("div", { class: "scene-editor scene-link" }, body)];
}

// ---- on the list of links (#/links) ---------------------------------------------------------------

// Every ask-to-open link (admins see everyone's), each with its door and person, and Remove.
export function askLinksSection() {
  if (!askLinksSupported() || !can("doors")) return null;
  const links = ensureAskLinks();
  const message = links.message?.at === "list" ? links.message : null;
  let content;
  if (!links.loaded) {
    content = h("p", { class: "field-help", role: "status" }, t("common.loading"));
  } else if (links.error) {
    content = notice("error", links.error);
  } else if (!links.items.length) {
    content = h("p", { class: "field-help", dataset: { key: "ask-links-empty" } }, t("askLinks.listEmpty"));
  } else {
    content = h(
      "ul",
      { class: "card settings-rows", dataset: { key: "ask-links-list" } },
      links.items.map((link) => {
        const door = relayOf(link.relay_id)?.name || link.relay_name || t("askLinks.doorGone");
        const facts = [
          link.person ? t("askLinks.forPerson", { person: isolate(link.person) }) : null,
          link.label ? t("sceneLinks.labelled", { label: isolate(link.label) }) : null,
          link.last_used_at ? t("sceneLinks.lastRun", { date: date(link.last_used_at) }) : t("sceneLinks.neverRun"),
        ].filter(Boolean);
        return h(
          "li",
          { class: "ask-links-item" },
          h(
            link.this_device ? "a" : "div",
            { class: "settings-row", href: link.this_device ? askHash(link.relay_id) : undefined, dataset: { key: `ask-links-item:${link.link_id}` } },
            h("span", { class: "settings-row-icon", "aria-hidden": "true" }, icon("door")),
            h("span", { class: "settings-row-text" }, name(door, "span", "settings-row-title"), h("span", { class: "settings-row-status" }, facts.join(" · "))),
            link.this_device ? icon("chevronForward", "settings-row-chevron") : null
          ),
          link.this_device
            ? null
            : h(
                "button",
                {
                  type: "button",
                  class: "button button-quiet button-small",
                  disabled: links.busy === link.link_id,
                  dataset: { key: `ask-links-remove:${link.link_id}` },
                  onclick: async () => {
                    if (!window.confirm(t("askLinks.removeOtherConfirm", { person: link.person || t("askLinks.someone"), name: door }))) return;
                    await removeAskLink(link.link_id, "list");
                  },
                },
                t("sceneLinks.remove")
              )
        );
      })
    );
  }
  return h(
    "section",
    { class: "scene-links ask-links", dataset: { key: "ask-links-section" } },
    h("h2", { class: "section-title" }, t("askLinks.listTitle")),
    h("p", { class: "field-help" }, t("askLinks.listHelp")),
    message ? notice(message.kind, message.text, "ask-links-message") : null,
    content
  );
}

// Leaving a link's screen: the secret shown there is forgotten.
export function leaveAskLink() {
  forgetAskMade();
  const links = askState();
  links.copied = null;
  links.message = null;
}

// ---- the question (#/open/<door>/<request>/<until>) -------------------------------------------------

// Redraws once the request is over by this device's clock (only one wait at a time).
let overTimer = null;
function redrawWhenOver(until) {
  if (overTimer) window.clearTimeout(overTimer);
  overTimer = window.setTimeout(() => {
    overTimer = null;
    ui.tick += 1;
    notify();
  }, Math.max(0, Math.min(until - Date.now() + 50, 10 * 60 * 1000)));
}

// Leaving the question: no redraw is waited for.
export function leaveOpenRequest() {
  if (overTimer) window.clearTimeout(overTimer);
  overTimer = null;
}

export function openRequestView(relayId, requestId, until) {
  const relay = state.loaded ? relayOf(relayId) : null;
  // The door's name above the question, once it is known.
  const header = pageHeader({ title: relay?.name || t("openRequest.title"), back: "#/", titleDir: relay ? "auto" : undefined });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (!state.loaded) return [header, h("p", { class: "field-help", role: "status" }, t("common.loading"))];
  const request = openRequestState(requestId);
  const goToDoor = relay?.room?.id ? h("a", { class: "button button-secondary", href: `#/room/${relay.room.id}`, dataset: { key: "open-request-room" } }, icon("door"), t("openRequest.goToDoor")) : null;
  const home = h("a", { class: "button button-primary", href: "#/", dataset: { key: "open-request-done" } }, t("common.done"));
  const body = [];
  if (!relay) {
    body.push(notice("info", t("openRequest.noDoor"), "open-request-no-door"), h("div", { class: "scene-actions" }, home));
  } else if (!can("doors")) {
    body.push(notice("info", t("openRequest.noAccess"), "open-request-no-access"), h("div", { class: "scene-actions" }, home));
  } else if (request.stage === "opened") {
    body.push(notice("success", t("openRequest.opened", { name: isolate(relay.name) }), "open-request-opened"), h("div", { class: "scene-actions" }, home));
  } else if (request.stage === "answered") {
    body.push(notice("info", t("openRequest.answered"), "open-request-answered"), h("div", { class: "scene-actions" }, home));
  } else if (request.stage === "expired" || (request.stage !== "opening" && requestOver(until))) {
    body.push(notice("info", t("openRequest.expired"), "open-request-expired"), h("div", { class: "scene-actions" }, goToDoor, home));
  } else {
    redrawWhenOver(until);
    const opening = request.stage === "opening";
    body.push(
      h("h2", { class: "open-request-question", dataset: { key: "open-request-question" } }, t("openRequest.question", { name: isolate(relay.name) })),
      relay.room ? h("p", { class: "field-help" }, roomName(relay.room)) : null,
      h("p", { class: "field-help" }, t("openRequest.until", { time: formatClock(new Date(until)) })),
      request.stage === "error" ? notice("error", request.text || t("openRequest.failed"), "open-request-error") : null,
      h(
        "div",
        { class: "scene-actions open-request-actions" },
        h(
          "button",
          { type: "button", class: "button button-primary button-wide", disabled: opening, dataset: { key: "open-request-open" }, onclick: () => answerRequest(relay.id, requestId) },
          icon("door"),
          opening ? t("relays.opening") : t("openRequest.open")
        ),
        h(
          "a",
          {
            class: "button button-secondary button-wide",
            href: "#/",
            dataset: { key: "open-request-cancel" },
            // Nothing is sent: the request ends by itself.
            onclick: () => {
              ui.openRequest = null;
            },
          },
          t("common.cancel")
        )
      )
    );
  }
  return [header, offlineBanner(), h("div", { class: "scene-editor open-request" }, body)];
}
