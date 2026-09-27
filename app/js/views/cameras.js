// Cameras: one large picture and a grid of the others. Tapping a small one makes it the large
// one; tapping the large one opens the full view.

import { cameraTile, emptyState, skeletonCards } from "../components.js";
import { h } from "../dom.js";
import { t } from "../i18n.js";
import { findDevice, notify, state, ui } from "../state.js";
import { isLoading, notReadyState, offlineBanner, pageHeader, staleBanner } from "./common.js";

export function camerasView({ openCamera }) {
  const header = pageHeader({ title: t("cameras.title") });
  const notReady = notReadyState();
  if (notReady) return [header, notReady];
  if (isLoading()) {
    return [header, h("div", { class: "cameras-layout", "aria-busy": "true" }, skeletonCards(1, "skeleton-camera-large"), h("div", { class: "camera-grid" }, skeletonCards(4, "skeleton-camera")))];
  }
  if (!state.cameras.length) {
    return [header, emptyState("camera", t("cameras.emptyTitle"), t("cameras.emptyText"))];
  }
  const featured = findDevice("camera", ui.featuredCamera) || state.cameras[0];
  const others = state.cameras.filter((camera) => camera.id !== featured.id);
  return [
    header,
    offlineBanner(),
    staleBanner(),
    h(
      "div",
      { class: "cameras-layout" },
      h(
        "div",
        { class: "camera-featured" },
        cameraTile(featured, { width: 640, onOpen: openCamera, large: true }),
        h("p", { class: "muted-note" }, t("cameras.fullHint"))
      ),
      others.length
        ? h(
            "div",
            { class: "camera-grid" },
            others.map((camera) =>
              cameraTile(camera, {
                width: 320,
                onOpen: (picked) => {
                  ui.featuredCamera = picked.id;
                  notify();
                  window.scrollTo({ top: 0, behavior: "smooth" });
                },
              })
            )
          )
        : null
    ),
  ];
}
