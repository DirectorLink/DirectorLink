// The update notice for admin keys (docs/DECISIONS.md, ADR-035): Settings → Controller says whether
// a newer DirectorLink is out, with its download, What's new and the steps in Composer; Home shows a
// short notice until it is dismissed for that version. Nothing GitHub writes is shown as markup:
// only the version, the date and links into the project's releases (checked in js/updates.js).

import { h, iconButton } from "../dom.js";
import { formatDate, t } from "../i18n.js";
import { icon } from "../icons.js";
import { PACKAGE_NAME, checkForUpdate, dismissUpdate, dismissedVersion, newerRelease, parseVersion, savedCheck } from "../updates.js";
import { notify, state } from "../state.js";

// Set when the notice on Home is followed: Settings then brings the steps into view.
let revealSteps = false;

function driverVersion() {
  return state.system?.bridge?.version;
}

// { release } for an admin key with a driver of a known version once GitHub has answered: the
// newer release, or null when the driver is up to date. null otherwise: nothing is said at all.
function knownUpdate() {
  if (state.role !== "admin" || !parseVersion(driverVersion())) return null;
  const latest = savedCheck()?.release;
  return latest ? { release: newerRelease(driverVersion(), latest) } : null;
}

// After connecting and with each rooms refresh (app.js); js/updates.js decides whether it is time.
export async function checkUpdates() {
  if (await checkForUpdate({ role: state.role, driverVersion: driverVersion() })) notify();
}

// What these screens show, for the renderer's signature (app.js): they are kept in localStorage.
export function updatesSignature() {
  return [savedCheck()?.release || null, dismissedVersion()];
}

function availableText(release) {
  if (!release.publishedAt) return t("updates.availableUndated", { version: release.version });
  // The date stays on one line when the text wraps.
  const date = formatDate(new Date(release.publishedAt)).replace(/ /g, "\u00a0");
  return t("updates.available", { version: release.version, date });
}

// Settings → Controller: the "Updates" line as [label, value], or null.
export function updateFact() {
  const known = knownUpdate();
  if (!known) return null;
  return [t("updates.label"), known.release ? availableText(known.release) : t("updates.upToDate")];
}

// Settings → Controller, under that line: the download, What's new and the steps in Composer.
export function updatePanel() {
  const reveal = revealSteps;
  revealSteps = false;
  const release = knownUpdate()?.release;
  if (!release) return null;
  if (reveal) {
    // After the screen change has scrolled to the top and focused the title (app.js).
    window.setTimeout(() => {
      const panel = document.getElementById("settings-update");
      panel?.scrollIntoView({ block: "center" });
      panel?.focus({ preventScroll: true });
    }, 0);
  }
  return h(
    "section",
    { class: "update-panel", id: "settings-update", tabindex: "-1", "aria-labelledby": "settings-update-title" },
    h("h3", { class: "settings-subtitle", id: "settings-update-title" }, t("updates.howTo")),
    h(
      "div",
      { class: "button-row" },
      // GitHub sends the file as an attachment named DirectorLink.c4z, so the app stays open.
      h(
        "a",
        { class: "button button-primary", href: release.download, download: PACKAGE_NAME, rel: "noreferrer", dataset: { key: "update-download" } },
        icon("download"),
        t("updates.download")
      ),
      h(
        "a",
        { class: "button button-secondary", href: release.url, target: "_blank", rel: "noreferrer", title: release.name || undefined, dataset: { key: "update-whats-new" } },
        t("updates.whatsNew"),
        icon("external")
      )
    ),
    h(
      "ol",
      { class: "update-steps" },
      ["download", "composer", "after"].map((step) => h("li", {}, t(`updates.steps.${step}`)))
    ),
    release.checksums
      ? h("p", { class: "field-help" }, h("a", { href: release.checksums, rel: "noreferrer", dataset: { key: "update-checksums" } }, t("updates.checksums")))
      : null
  );
}

// Home: one line that leads to the steps, until it is dismissed for this version.
export function updateBanner() {
  const release = knownUpdate()?.release;
  if (!release || dismissedVersion() === release.version) return null;
  return h(
    "div",
    { class: "banner banner-info banner-update" },
    icon("download"),
    h(
      "a",
      {
        class: "banner-update-link",
        href: "#/settings",
        dataset: { key: "home-update" },
        onclick: (event) => {
          // Not when it opens in another tab.
          if (!event.ctrlKey && !event.metaKey && !event.shiftKey) revealSteps = true;
        },
      },
      h("span", {}, t("updates.notice", { version: release.version })),
      " ",
      h("span", { class: "banner-action" }, t("updates.noticeAction"))
    ),
    iconButton("close", t("updates.dismiss"), {
      dataset: { key: "home-update-dismiss" },
      onclick: () => {
        dismissUpdate(release.version);
        notify();
        // The button goes with the notice: keep the keyboard on this screen.
        window.requestAnimationFrame(() => document.querySelector(".page-title")?.focus({ preventScroll: true }));
      },
    })
  );
}
