// The update notice for admin keys (docs/DECISIONS.md, ADR-035): Settings → Controller says whether
// a newer DirectorLink is out, with its download, What's new and the steps in Composer; Home shows a
// short notice until it is dismissed for that version. Nothing GitHub writes is shown as markup:
// only the version, the date and links into the project's releases (checked in js/updates.js).

import { h, iconButton } from "../dom.js";
import { formatDate, t } from "../i18n.js";
import { icon } from "../icons.js";
import {
  PACKAGE_NAME,
  checkForUpdate,
  dismissUpdate,
  dismissedVersion,
  manualCheckWait,
  parseVersion,
  savedCheck,
  updateStatus,
} from "../updates.js";
import { notify, state } from "../state.js";

// Set when the notice on Home is followed: Settings then brings the steps into view.
let revealSteps = false;
// True while Check now waits for GitHub.
let checking = false;

function driverVersion() {
  return state.system?.bridge?.version;
}

// Admins with a driver of a known version: the only ones who ask GitHub.
function canCheck() {
  return state.role === "admin" && Boolean(parseVersion(driverVersion()));
}

// For an admin key with a driver of a known version: { release } (a newer one), { upToDate } or
// { answeredAt } (the check did not work), from js/updates.js. null: nothing is said at all.
function knownUpdate() {
  return updateStatus({ role: state.role, driverVersion: driverVersion(), check: savedCheck() });
}

// After connecting and with each rooms refresh (app.js); js/updates.js decides whether it is time.
export async function checkUpdates() {
  if (await checkForUpdate({ role: state.role, driverVersion: driverVersion() })) notify();
}

// Check now in Settings: asks GitHub at once, at most once a minute (js/updates.js).
export async function checkNow() {
  if (checking || !canCheck() || manualCheckWait({ check: savedCheck() }) > 0) return;
  checking = true;
  notify();
  try {
    await checkForUpdate({ role: state.role, driverVersion: driverVersion(), force: true });
  } finally {
    checking = false;
    notify();
  }
}

// What these screens show, for the renderer's signature (app.js): the last check is kept in
// localStorage, "Up to date" ends 3 days after GitHub's last answer, and Check now waits a minute.
export function updatesSignature() {
  return [knownUpdate(), dismissedVersion(), checking, manualCheckWait({ check: savedCheck() }) > 0];
}

// A day, kept on one line when the text wraps.
function dayText(time) {
  return formatDate(new Date(time)).replace(/ /g, "\u00a0");
}

function availableText(release) {
  if (!release.publishedAt) return t("updates.availableUndated", { version: release.version });
  return t("updates.available", { version: release.version, date: dayText(release.publishedAt) });
}

function statusText(known) {
  if (known.release) return availableText(known.release);
  if (known.upToDate) return t("updates.upToDate");
  // GitHub has not answered for 3 days (a rate limit, no connection), or never has.
  return known.answeredAt ? t("updates.checkFailed", { date: dayText(known.answeredAt) }) : t("updates.checkFailedUndated");
}

// Settings → Controller: the "Updates" line as [label, value], or null.
export function updateFact() {
  if (checking && canCheck()) return [t("updates.label"), t("updates.checking")];
  const known = knownUpdate();
  return known ? [t("updates.label"), statusText(known)] : null;
}

// Settings → Controller, under the facts: Check now, for admins with a driver of a known version.
// While a minute has not passed since the last try it says so and does nothing; it stays
// focusable (aria-disabled), so the keyboard is not lost when it is pressed.
export function updateCheckButton() {
  if (!canCheck()) return null;
  const waiting = checking || manualCheckWait({ check: savedCheck() }) > 0;
  return h(
    "div",
    { class: "button-row update-check" },
    h(
      "button",
      {
        type: "button",
        class: "button button-secondary button-small",
        "aria-disabled": waiting ? "true" : "false",
        title: waiting && !checking ? t("updates.checkWait") : undefined,
        dataset: { key: "update-check-now" },
        onclick: () => checkNow(),
      },
      icon("refresh"),
      checking ? t("updates.checking") : t("updates.checkNow")
    )
  );
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
    // The data-key keeps focus here when the next poll redraws Settings (app.js restoreUi).
    { class: "update-panel", id: "settings-update", tabindex: "-1", "aria-labelledby": "settings-update-title", dataset: { key: "settings-update" } },
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
