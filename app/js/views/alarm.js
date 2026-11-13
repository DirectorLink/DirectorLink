// The alarm's status on Home and in Settings → Controller (js/alarm.js), for members and admins, and
// only when an installer turned it on in Composer. Since 1.15.0 (ADR-091) Home's rows also have Arm
// and Disarm for the partitions the controller says this person may arm and disarm
// (views/alarm-control.js, which alone sends the alarm anything); otherwise the alarm is read only.

import { h, name } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { roomName } from "../model.js";
import { alarmDetails, alarmPartitions, alarmStateText, alarmSummary, alarmTone, delaySecondsLeft } from "../alarm.js";
import { controlAllowed } from "../alarm-control.js";
import { alarmControls } from "./alarm-control.js";

// An entry or exit delay's seconds, counted down in place every second (1.16.1), never by a redraw:
// a redraw replaces the row's buttons, and one under a finger loses its tap (app.js redraws after
// every tap when anything shown changed). The timer stops once no countdown is in the page.
let ticker = null;

// Each countdown in the page ([data-alarm-delay] = the partition's id) set to the seconds left now.
// Returns how many still count.
export function tickAlarmDelays(now = Date.now()) {
  const partitions = alarmPartitions() || [];
  let counting = 0;
  for (const element of document.querySelectorAll?.("[data-alarm-delay]") || []) {
    const partition = partitions.find((item) => String(item.id) === element.dataset.alarmDelay);
    const left = partition ? delaySecondsLeft(partition, now) : null;
    const text = left && left > 0 ? t("alarm.delayLeft", { count: left }) : "";
    if (text) counting += 1;
    if (element.textContent !== text) element.textContent = text;
  }
  return counting;
}

function keepCounting() {
  if (ticker !== null || typeof window === "undefined" || !window.setInterval) return;
  ticker = window.setInterval(() => {
    if (tickAlarmDelays() === 0) {
      window.clearInterval(ticker);
      ticker = null;
    }
  }, 1000);
}

function partitionRow(partition, now) {
  const tone = alarmTone(partition);
  const details = alarmDetails(partition, now);
  // alarmDetails puts a delay that still counts first.
  const left = partition.delay ? delaySecondsLeft(partition, now) : null;
  const counting = left !== null && left > 0;
  const rest = counting ? details.slice(1) : details;
  if (counting) keepCounting();
  return h(
    "li",
    { class: `device alarm-partition is-${tone}` },
    h(
      "div",
      { class: "device-main" },
      h("span", { class: "device-icon" }, icon(tone === "alarm" ? "siren" : "shield")),
      h(
        "div",
        { class: "device-text" },
        name(partition.name, "span", "device-name"),
        partition.room ? name(roomName(partition.room), "span", "device-meta") : null
      ),
      h("span", { class: "alarm-state", dir: "auto" }, alarmStateText(partition))
    ),
    details.length
      ? h(
          "p",
          { class: "alarm-details" },
          counting ? h("span", { dataset: { alarmDelay: String(partition.id) } }, details[0]) : null,
          counting && rest.length ? " · " : null,
          rest.length ? rest.join(" · ") : null
        )
      : null,
    // Arm, Disarm, "Arming…", or why it can't now (1.15.0).
    alarmControls(partition)
  );
}

// Home: the partitions, under the banners.
export function alarmSection(now = Date.now()) {
  const partitions = alarmPartitions();
  if (!partitions) return null;
  return h(
    "section",
    { class: "home-section alarm-section", "aria-labelledby": "home-alarm-title" },
    h(
      "div",
      { class: "section-head" },
      h("h2", { id: "home-alarm-title", class: "section-title" }, icon("shield"), t("alarm.title")),
      // Read only, unless this person may arm or disarm a partition (1.15.0).
      partitions.some(controlAllowed) ? null : h("span", { class: "alarm-read-only" }, t("alarm.readOnly"))
    ),
    h("ul", { class: "device-list alarm-list" }, partitions.map((partition) => partitionRow(partition, now)))
  );
}

// Settings → Controller: the "Alarm" line as [label, value], or null.
export function alarmFact() {
  const partitions = alarmPartitions();
  return partitions ? [t("alarm.title"), alarmSummary(partitions)] : null;
}
