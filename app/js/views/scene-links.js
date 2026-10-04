// Scene links (ADR-051, docs/SCENES.md; js/scene-links.js), for admins: a private link per scene for
// the phone's own automations. The scene editor has a section for it (sceneLinkSection); the scene's
// link screen (#/scene/<id>/link) makes, replaces and removes it, and shows a new link's secret once,
// with Copy buttons, a QR code and short steps for iPhone Shortcuts, Android and an NFC tag; the
// list of linked scenes is #/links, from the Scenes list, with the doors' ask-before-opening links
// below (views/ask-links.js, 1.8.0). A scene that opens doors or gates has no link: the editor warns
// before a change that adds one removes it. A new link's screen also says how to run it by voice:
// Siri, and Google Assistant (1.8.0). Shown only when the controller has them (features.scene_links,
// 1.7.0).

import { emptyState } from "../components.js";
import { h, name } from "../dom.js";
import { formatDateTime, t } from "../i18n.js";
import { icon } from "../icons.js";
import { IS_IOS } from "../platform.js";
import { qrCanvas } from "../qr.js";
import { savedRemote } from "../remote.js";
import { findScene, isolate } from "../scenes.js";
import { roleLabel } from "../session.js";
import { can, notify, state } from "../state.js";
import { notReadyState, offlineBanner, pageHeader } from "./common.js";
import { askLinksSection } from "./ask-links.js";
import {
  ensureLinks,
  forgetMade,
  linkAddress,
  linkable,
  linkOf,
  linksState,
  linksSupported,
  linkUrl,
  madeLink,
  makeLink,
  removeLink,
} from "../scene-links.js";

export const LINKS_HASH = "#/links";
const IS_ANDROID = /Android/i.test(globalThis.navigator?.userAgent || "");

// The label being typed for a scene's next link: kept here, so typing is never redrawn.
const labels = {};

const date = (iso) => (iso ? formatDateTime(new Date(iso)) : "");

function notice(kind, text, key) {
  return h("p", { class: `notice notice-${kind}`, role: kind === "error" ? "alert" : "status", dataset: key ? { key } : undefined }, text);
}

// "Arriving home · made 3 Oct, 08:00 · last ran 4 Oct, 07:30"
function linkSummary(link) {
  return [
    link.label ? t("sceneLinks.labelled", { label: isolate(link.label) }) : null,
    t("sceneLinks.madeOn", { date: date(link.created_at) }),
    link.last_used_at ? t("sceneLinks.lastRun", { date: date(link.last_used_at) }) : t("sceneLinks.neverRun"),
  ]
    .filter(Boolean)
    .join(" · ");
}

// What a link needs before it works: Remote Access on, and the home linked to an account.
function requirements(links) {
  const notes = [];
  if (!links.remoteAccess) notes.push(notice("error", t("sceneLinks.errors.remoteOff"), "scene-link-remote-off"));
  else if (!links.homeLinked) notes.push(notice("error", t("sceneLinks.errors.notLinked"), "scene-link-not-linked"));
  else if (!savedRemote()) notes.push(h("p", { class: "field-help", dataset: { key: "scene-link-account" } }, t("sceneLinks.accountNote")));
  return notes;
}

// ---- the scene editor -------------------------------------------------------------------------

// The scene's link, in its editor (saved scenes only): what it is, and where to change it.
export function sceneLinkSection(draft) {
  if (!draft?.id || !linksSupported() || !can("admin")) return null;
  const links = ensureLinks();
  const link = linkOf(draft.id);
  const doors = !linkable(draft.steps);
  const content = [];
  if (!links.loaded) {
    content.push(h("p", { class: "field-help", role: "status" }, t("common.loading")));
  } else if (doors && link) {
    content.push(notice("error", t("sceneLinks.doorsWarning"), "scene-link-doors-warning"));
  } else if (doors) {
    content.push(h("p", { class: "field-help", dataset: { key: "scene-link-doors" } }, t("sceneLinks.noDoors")));
  } else {
    content.push(h("p", { class: "field-help" }, link ? linkSummary(link) : t("sceneLinks.sectionHelp")));
    content.push(
      h(
        "a",
        {
          class: `button ${link ? "button-secondary" : "button-primary"}`,
          href: `#/scene/${draft.id}/link`,
          dataset: { key: "scene-link-open" },
          // The link's screen is another screen: changes not saved yet would be left.
          onclick: (event) => {
            if (draft.dirty && !window.confirm(t("scenes.editor.discard"))) event.preventDefault();
          },
        },
        icon("link"),
        link ? t("sceneLinks.manage") : t("sceneLinks.make")
      )
    );
  }
  return h(
    "section",
    { class: "card scene-section scene-link-section", dataset: { key: "scene-link-section" } },
    h("h2", { class: "section-title" }, t("sceneLinks.title")),
    content
  );
}

// Add an action, doors and gates, in a linked scene: saving would remove its link.
export function doorLinkWarning(draft) {
  if (!draft?.id || !linksSupported() || !linkOf(draft.id)) return null;
  return notice("error", t("sceneLinks.doorsWarning"), "scene-link-doors-warning");
}

// Before saving `steps`: a linked scene that would open doors or gates loses its link, so the admin
// is asked first. True to go on.
export function confirmLinkLoss(draft, steps) {
  if (!draft?.id || !linksSupported() || !linkOf(draft.id) || linkable(steps)) return true;
  return window.confirm(t("sceneLinks.saveConfirm"));
}

// The question before deleting a scene: its link stops working with it.
export function deleteQuestion(draft) {
  return draft?.id && linksSupported() && linkOf(draft.id) ? t("sceneLinks.deleteConfirm", { name: draft.name }) : t("scenes.editor.deleteConfirm", { name: draft.name });
}

// ---- the scene's link screen (#/scene/<id>/link) -----------------------------------------------

// A Copy button; `holder` keeps which was copied (this screen's state, or an ask link's).
export function copyButton(text, key, label, holder = linksState()) {
  return h(
    "button",
    {
      type: "button",
      class: "button button-secondary button-small",
      dataset: { key },
      onclick: async () => {
        try {
          await navigator.clipboard.writeText(text);
          holder.copied = key;
        } catch {
          holder.copied = `${key}:failed`;
        }
        notify();
      },
    },
    icon(holder.copied === key ? "check" : "copy"),
    holder.copied === key ? t("sceneLinks.copied") : label
  );
}

function step(text, ...extra) {
  return h("li", {}, h("span", {}, text), extra.length ? h("div", { class: "button-row scene-link-copies" }, extra) : null);
}

// How to use a link just made, on iPhone (Shortcuts) and Android: `iphone`, the steps' words, four
// or more (the address and the secret get their Copy buttons on the second and third).
export function freshSteps({ key, copyAddress, copySecret, iphone, iphoneTitle }) {
  return [
    h(
      "details",
      { class: "card scene-section scene-link-how", open: IS_IOS || !IS_ANDROID, dataset: { key: `${key}-iphone` } },
      h("summary", {}, iphoneTitle),
      h(
        "ol",
        { class: "scene-link-steps" },
        step(iphone[0]),
        step(iphone[1], copyAddress(`${key}-iphone-address`)),
        step(iphone[2], copySecret(`${key}-iphone-secret`)),
        ...iphone.slice(3).map((text) => step(text))
      )
    ),
    h(
      "details",
      { class: "card scene-section scene-link-how", open: IS_ANDROID, dataset: { key: `${key}-android` } },
      h("summary", {}, t("sceneLinks.android.title")),
      h(
        "ol",
        { class: "scene-link-steps" },
        step(t("sceneLinks.android.request"), copyAddress(`${key}-android-address`)),
        step(t("sceneLinks.android.body"), copySecret(`${key}-android-secret`))
      )
    ),
  ];
}

// By voice (1.8.0): Siri runs a shortcut named like the scene ("Good night"); on Android, a Google
// Assistant routine starts the automation app's request. `phrase`: what to say; `ask`: an
// ask-to-open link's words (the phone then asks before the door opens).
export function voiceHelp({ phrase, key, ask = false }) {
  const words = ask ? "askLinks" : "sceneLinks";
  const said = { phrase: isolate(phrase) };
  return [
    h(
      "details",
      { class: "card scene-section scene-link-how", open: IS_IOS, dataset: { key: `${key}-siri` } },
      h("summary", {}, t("sceneLinks.siri.title")),
      h(
        "ol",
        { class: "scene-link-steps" },
        step(t(`${words}.siri.name`, said)),
        step(t(`${words}.siri.say`, said)),
        // An ask link's run that asked nobody shows nothing by itself (1.8.0): Siri can say so.
        ask ? step(t("askLinks.siri.show")) : null
      )
    ),
    h(
      "details",
      { class: "card scene-section scene-link-how", open: IS_ANDROID, dataset: { key: `${key}-google` } },
      h("summary", {}, t("sceneLinks.google.title")),
      h("ol", { class: "scene-link-steps" }, step(t(`${words}.google.name`, said)), step(t("sceneLinks.google.say", said)))
    ),
  ];
}

// A link just made: its secret, once, and how to use it.
function freshLink(scene, link) {
  const address = linkAddress(link);
  const url = linkUrl(link);
  const copyAddress = (key) => copyButton(address, key, t("sceneLinks.copyAddress"));
  const copySecret = (key) => copyButton(link.secret, key, t("sceneLinks.copySecret"));
  const failed = String(linksState().copied || "").endsWith(":failed");
  return h(
    "div",
    { class: "scene-link-fresh", dataset: { key: "scene-link-fresh" } },
    notice("success", link.replaced ? t("sceneLinks.replacedOnce") : t("sceneLinks.madeOnce"), "scene-link-made"),
    failed ? notice("error", t("sceneLinks.copyFailed")) : null,
    h("p", { class: "field-help" }, t("sceneLinks.privacy", { name: isolate(scene.name) })),
    h(
      "div",
      { class: "card scene-section scene-link-card" },
      h("h2", { class: "section-title" }, t("sceneLinks.linkTitle")),
      h("p", { class: "field-help" }, t("sceneLinks.linkHelp")),
      qrCanvas(url, { label: t("sceneLinks.qrLabel") }),
      h("input", { class: "invitation-link", type: "text", readonly: true, dir: "ltr", value: url, "aria-label": t("sceneLinks.linkTitle"), dataset: { key: "scene-link-url" }, onfocus: (event) => event.target.select() }),
      h("div", { class: "button-row" }, copyButton(url, "scene-link-copy-url", t("sceneLinks.copyLink")))
    ),
    ...freshSteps({
      key: "scene-link",
      copyAddress,
      copySecret,
      iphone: [t("sceneLinks.iphone.action"), t("sceneLinks.iphone.url"), t("sceneLinks.iphone.body"), t("sceneLinks.iphone.immediately")],
      iphoneTitle: t("sceneLinks.iphone.title"),
    }),
    // Siri and Google Assistant (1.8.0): the same request, named like the scene.
    ...voiceHelp({ phrase: scene.name, key: "scene-link" }),
    h(
      "details",
      { class: "card scene-section scene-link-how", dataset: { key: "scene-link-nfc" } },
      h("summary", {}, t("sceneLinks.nfc.title")),
      h("p", {}, t("sceneLinks.nfc.text"))
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
          dataset: { key: "scene-link-done" },
          onclick: () => {
            forgetMade(scene.id);
            linksState().copied = null;
            notify();
          },
        },
        t("common.done")
      )
    )
  );
}

// `current`: the label of the link it replaces, kept unless changed.
function labelField(sceneId, current = "") {
  return h(
    "div",
    { class: "field" },
    h("label", { class: "field-label", for: "scene-link-label" }, t("sceneLinks.label")),
    h("input", {
      id: "scene-link-label",
      type: "text",
      maxlength: "64",
      dir: "auto",
      autocomplete: "off",
      value: labels[sceneId] ?? current,
      placeholder: t("sceneLinks.labelPlaceholder"),
      dataset: { key: "scene-link-label" },
      // Not redrawn while typing: the label is kept here, outside the screen's signature.
      oninput: (event) => {
        labels[sceneId] = event.target.value;
      },
    }),
    h("p", { class: "field-help" }, t("sceneLinks.labelHelp"))
  );
}

async function make(sceneId, replacing) {
  if (replacing && !window.confirm(t("sceneLinks.replaceConfirm"))) return;
  linksState().copied = null;
  const link = await makeLink(sceneId, labels[sceneId] ?? (replacing ? linkOf(sceneId)?.label || "" : ""));
  if (link) delete labels[sceneId];
}

async function remove(sceneId) {
  if (!window.confirm(t("sceneLinks.removeConfirm"))) return;
  await removeLink(sceneId);
}

export function sceneLinkView(sceneId) {
  const scene = findScene(sceneId);
  const header = pageHeader({ title: t("sceneLinks.screenTitle"), back: `#/scene/${sceneId}` });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (state.scenes === null) return [header, h("p", { class: "field-help", role: "status" }, t("common.loading"))];
  if (!linksSupported()) return [header, emptyState("scene", t("sceneLinks.title"), t("sceneLinks.updateDriver"))];
  if (!can("admin")) return [header, notice("info", t("sceneLinks.adminOnly", { role: roleLabel(state.role) }))];
  if (!scene) return [header, emptyState("scene", t("scenes.editor.notFound"), "", h("a", { class: "button button-primary", href: "#/scenes" }, t("scenes.title")))];
  const links = ensureLinks();
  const fresh = madeLink(sceneId);
  const link = linkOf(sceneId);
  const busy = links.busy === sceneId;
  const message = links.message?.sceneId === sceneId ? links.message : null;
  const body = [
    h("p", { class: "scene-link-scene" }, h("span", { class: "scene-icon", "aria-hidden": "true" }, icon(scene.icon || "bulb")), name(scene.name, "strong")),
    message ? notice(message.kind, message.text, "scene-link-message") : null,
  ];
  if (fresh) {
    body.push(freshLink(scene, fresh));
  } else if (!links.loaded) {
    body.push(h("p", { class: "field-help", role: "status" }, t("common.loading")));
  } else if (links.error) {
    body.push(notice("error", links.error));
  } else if (!linkable(scene.steps)) {
    body.push(notice("info", t("sceneLinks.noDoors"), "scene-link-doors"));
  } else if (link) {
    body.push(
      h(
        "div",
        { class: "card scene-section" },
        h(
          "dl",
          { class: "facts", dataset: { key: "scene-link-facts" } },
          h("div", { class: "fact" }, h("dt", {}, t("sceneLinks.nameTitle")), h("dd", { dir: "auto" }, link.label || t("sceneLinks.noLabel"))),
          h("div", { class: "fact" }, h("dt", {}, t("sceneLinks.made")), h("dd", {}, date(link.created_at))),
          h("div", { class: "fact" }, h("dt", {}, t("sceneLinks.lastRunTitle")), h("dd", {}, link.last_used_at ? date(link.last_used_at) : t("sceneLinks.never")))
        )
      ),
      h("p", { class: "field-help" }, t("sceneLinks.lostSecret")),
      h("p", { class: "field-help", dataset: { key: "scene-link-voice" } }, t("sceneLinks.voiceHint", { phrase: isolate(scene.name) })),
      ...requirements(links),
      labelField(sceneId, link.label || ""),
      h(
        "div",
        { class: "scene-actions" },
        h("button", { type: "button", class: "button button-secondary", disabled: busy || !links.remoteAccess || !links.homeLinked, dataset: { key: "scene-link-replace" }, onclick: () => make(sceneId, true) }, icon("refresh"), t("sceneLinks.replace")),
        h("button", { type: "button", class: "button button-danger", disabled: busy, dataset: { key: "scene-link-remove" }, onclick: () => remove(sceneId) }, t("sceneLinks.remove"))
      )
    );
  } else {
    const blocked = !links.remoteAccess || !links.homeLinked;
    body.push(
      h("p", {}, t("sceneLinks.intro")),
      h("p", { class: "field-help" }, t("sceneLinks.introSafety")),
      ...requirements(links),
      labelField(sceneId),
      h(
        "div",
        { class: "scene-actions" },
        h("button", { type: "button", class: "button button-primary", disabled: busy || blocked, dataset: { key: "scene-link-make" }, onclick: () => make(sceneId, false) }, icon("link"), busy ? t("sceneLinks.making") : t("sceneLinks.make"))
      )
    );
  }
  return [header, offlineBanner(), h("div", { class: "scene-editor scene-link" }, body)];
}

// ---- the list of linked scenes (#/links) ------------------------------------------------------

// On the Scenes list, for admins: how many scenes have a link, and the way to them.
export function linksRow() {
  if (!linksSupported() || !can("admin")) return null;
  const links = ensureLinks();
  const count = links.items.length;
  return h(
    "nav",
    { class: "scene-links-row", "aria-label": t("sceneLinks.listTitle") },
    h(
      "ul",
      { class: "card settings-rows" },
      h(
        "li",
        {},
        h(
          "a",
          { class: "settings-row", href: LINKS_HASH, dataset: { key: "scene-links-row" } },
          h("span", { class: "settings-row-icon", "aria-hidden": "true" }, icon("link")),
          h(
            "span",
            { class: "settings-row-text" },
            h("span", { class: "settings-row-title" }, t("sceneLinks.listTitle")),
            h("span", { class: "settings-row-status" }, links.loaded ? t("sceneLinks.rowStatus", { count }) : t("common.loading"))
          ),
          icon("chevronForward", "settings-row-chevron")
        )
      )
    )
  );
}

export function sceneLinksView() {
  const header = pageHeader({ title: t("sceneLinks.listTitle"), back: "#/scenes" });
  const notReady = notReadyState();
  if (notReady) return [header, offlineBanner(), notReady];
  if (!linksSupported()) return [header, emptyState("scene", t("sceneLinks.listTitle"), t("sceneLinks.updateDriver"))];
  if (!can("admin")) return [header, notice("info", t("sceneLinks.adminOnly", { role: roleLabel(state.role) }))];
  const links = ensureLinks();
  const body = [h("p", { class: "field-help" }, t("sceneLinks.listHelp"))];
  if (!links.loaded) {
    body.push(h("p", { class: "field-help", role: "status" }, t("common.loading")));
  } else if (links.error) {
    body.push(notice("error", links.error));
  } else {
    body.push(...requirements(links));
    body.push(
      links.items.length
        ? h(
            "ul",
            { class: "card settings-rows", dataset: { key: "scene-links-list" } },
            links.items.map((link) =>
              h(
                "li",
                {},
                h(
                  "a",
                  { class: "settings-row", href: `#/scene/${link.scene_id}/link`, dataset: { key: `scene-links-item:${link.scene_id}` } },
                  h("span", { class: "settings-row-icon", "aria-hidden": "true" }, icon("link")),
                  h(
                    "span",
                    { class: "settings-row-text" },
                    name(findScene(link.scene_id)?.name || link.scene_name || t("history.sceneGone"), "span", "settings-row-title"),
                    h("span", { class: "settings-row-status" }, linkSummary(link))
                  ),
                  icon("chevronForward", "settings-row-chevron")
                )
              )
            )
          )
        : emptyState("link", t("sceneLinks.emptyTitle"), t("sceneLinks.emptyText"))
    );
    body.push(h("p", { class: "field-help" }, t("sceneLinks.composerNote")));
  }
  // Ask before opening (1.8.0, ADR-058): the doors' links, everyone's for an admin.
  body.push(askLinksSection());
  return [header, offlineBanner(), h("div", { class: "scene-links" }, body)];
}

// Leaving a link's screen: the secret shown there is forgotten.
export function leaveSceneLink() {
  forgetMade();
  const links = linksState();
  links.copied = null;
  links.message = null;
}
