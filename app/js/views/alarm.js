// The alarm's status on Home and in Settings → Controller (js/alarm.js): read-only, for members and
// admins, and only when an installer turned it on in Composer. There is nothing to press.

import { h, name } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { roomName } from "../model.js";
import { alarmDetails, alarmPartitions, alarmStateText, alarmSummary, alarmTone } from "../alarm.js";

function partitionRow(partition, now) {
  const tone = alarmTone(partition);
  const details = alarmDetails(partition, now);
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
    details.length ? h("p", { class: "alarm-details" }, details.join(" · ")) : null
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
      h("span", { class: "alarm-read-only" }, t("alarm.readOnly"))
    ),
    h("ul", { class: "device-list alarm-list" }, partitions.map((partition) => partitionRow(partition, now)))
  );
}

// Settings → Controller: the "Alarm" line as [label, value], or null.
export function alarmFact() {
  const partitions = alarmPartitions();
  return partitions ? [t("alarm.title"), alarmSummary(partitions)] : null;
}
