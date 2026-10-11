// Cameras: one large picture and a grid of the others, in the home's camera order (1.12.1, the
// controller lists them so). Tapping a small one makes it the large one; tapping the large one opens
// the full view. Admins set the order for everyone with Order: every camera (doorbell cameras too)
// with its room, moved by its handle or with the arrows as the rooms are in Settings → Rooms
// (sortable.js), then Save (PUT /v1/cameras/order) or Cancel.

import { cameraTile, emptyState, skeletonCards } from "../components.js";
import { h, iconButton, name } from "../dom.js";
import { t } from "../i18n.js";
import { icon } from "../icons.js";
import { roomName } from "../model.js";
import { moveItem } from "../reorder.js";
import { api, errorText, noteForbidden } from "../session.js";
import { orderStatus, sortable } from "../sortable.js";
import { can, findDevice, notify, state, ui } from "../state.js";
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
  const ordering = canOrder();
  if (ordering && ui.cameraOrder) return [header, offlineBanner(), staleBanner(), orderEditor(ui.cameraOrder)];
  const featured = findDevice("camera", ui.featuredCamera) || state.cameras[0];
  const others = state.cameras.filter((camera) => camera.id !== featured.id);
  return [
    header,
    ordering && state.cameras.length > 1 ? h("div", { class: "toolbar" }, orderButton()) : null,
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

// ---- the home's camera order (1.12.1) -----------------------------------------------------------

// Admins, with a controller that keeps a camera order (`features.camera_order`); members see the
// order and no button.
export function canOrder() {
  return can("admin") && state.system?.features?.camera_order === true;
}

// `cameras` in the order of `ids`: those still listed first, then the others (one added meanwhile)
// in the order they come; an id no longer listed is passed over.
export function orderedCameras(ids, cameras = state.cameras) {
  const byId = new Map(cameras.map((camera) => [camera.id, camera]));
  const listed = ids.map((id) => byId.get(id)).filter(Boolean);
  const placed = new Set(listed.map((camera) => camera.id));
  return [...listed, ...cameras.filter((camera) => !placed.has(camera.id))];
}

// Its data-key is the list's title's too: as the list opens, the focus goes to its title (app.js
// keeps it on the same data-key over a redraw); as it closes, back here (focusOrderButton).
function orderButton() {
  return h(
    "button",
    { type: "button", class: "button button-secondary button-small", dataset: { key: "camera-order" }, onclick: startOrder },
    icon("grip"),
    t("cameras.order.button")
  );
}

export function startOrder() {
  ui.cameraOrder = { ids: state.cameras.map((camera) => camera.id), busy: false, message: null };
  notify();
}

export function cancelOrder() {
  ui.cameraOrder = null;
  notify();
  focusOrderButton();
}

// Once the list closes, the focus is back on Order (after the redraw, which notify asked for first).
function focusOrderButton() {
  requestAnimationFrame(() => document.querySelector('[data-key="camera-order"]')?.focus());
}

const cameraSorter = sortable({
  items: () => (ui.cameraOrder ? orderedCameras(ui.cameraOrder.ids) : state.cameras),
  label: (camera) => camera.name,
  onDrop: (order) => setDraft(order),
  words: "cameras.order",
});

function setDraft(cameras) {
  if (!ui.cameraOrder || ui.cameraOrder.busy) return;
  ui.cameraOrder.ids = cameras.map((camera) => camera.id);
  ui.cameraOrder.message = null;
  notify();
}

// The arrows: one place up or down.
function moveCamera(index, offset) {
  const draft = ui.cameraOrder;
  if (!draft || draft.busy || cameraSorter.busy()) return;
  const cameras = orderedCameras(draft.ids);
  const target = index + offset;
  if (target < 0 || target >= cameras.length) return;
  setDraft(moveItem(cameras, index, target));
}

// Why the camera order was not saved: a controller without one (404, 405) needs a newer DirectorLink.
export function cameraOrderErrorText(error) {
  return error?.status === 404 || error?.status === 405 ? t("cameras.order.updateDriver") : errorText(error);
}

// Save: the order goes in one PUT /v1/cameras/order, for everyone; the controller answers the
// cameras in it, and the first one is the large picture.
export async function saveOrder() {
  const draft = ui.cameraOrder;
  if (!draft || draft.busy) return;
  const cameras = orderedCameras(draft.ids);
  draft.busy = true;
  draft.message = null;
  notify();
  try {
    const answer = await api("/v1/cameras/order", { method: "PUT", body: { camera_ids: cameras.map((camera) => camera.id) } });
    state.cameras = Array.isArray(answer?.items) ? answer.items : cameras;
    ui.featuredCamera = null;
  } catch (error) {
    noteForbidden(error);
    draft.busy = false;
    draft.message = { kind: "error", text: cameraOrderErrorText(error) };
    notify();
    return;
  }
  // Saved: the list closes (unless the tab was left meanwhile, which closed it).
  const open = ui.cameraOrder === draft;
  if (open) ui.cameraOrder = null;
  notify();
  if (open) focusOrderButton();
}

// Every camera with its room, as Settings → Rooms lists the rooms: moved by its handle (on a touch
// screen, held first) or with the keyboard, or one place at a time with the arrows. The arrows at the
// ends stay focusable (aria-disabled), so focus stays with a camera moved to the top or the bottom.
function orderEditor(draft) {
  const cameras = orderedCameras(draft.ids);
  // Made now, so that it is on the page before the first camera moves.
  orderStatus();
  return h(
    "section",
    { class: "card settings-card camera-order", "aria-labelledby": "camera-order-title" },
    h("h2", { class: "settings-title", id: "camera-order-title", tabindex: "-1", dataset: { key: "camera-order" } }, icon("camera"), t("cameras.order.title")),
    h("p", { class: "field-help" }, t("cameras.order.help")),
    h("p", { class: "visually-hidden", id: "camera-order-keys" }, t("cameras.order.moveKeys")),
    draft.message ? h("p", { class: `notice notice-${draft.message.kind}`, role: "alert" }, draft.message.text) : null,
    h(
      "ul",
      { class: "room-order-list camera-order-list" },
      cameras.map((camera, index) => orderRow(camera, index, cameras.length, draft.busy))
    ),
    h(
      "div",
      { class: "button-row" },
      h(
        "button",
        { type: "button", class: "button button-primary", disabled: draft.busy, dataset: { key: "camera-order-save" }, onclick: saveOrder },
        draft.busy ? t("common.saving") : t("common.save")
      ),
      h("button", { type: "button", class: "button button-secondary", dataset: { key: "camera-order-cancel" }, onclick: cancelOrder }, t("common.cancel"))
    )
  );
}

function orderRow(camera, index, count, busy) {
  const label = camera.name;
  return h(
    "li",
    { class: "room-order-row", dataset: { key: `camera-row:${camera.id}` } },
    h("span", { class: "room-order-name" }, name(label, "span"), name(roomName(camera.room), "span", "camera-order-room")),
    h(
      "span",
      { class: "room-order-moves" },
      iconButton("arrowUp", t("cameras.order.moveUp", { name: label }), {
        class: "room-order-step",
        "aria-disabled": index === 0 || busy ? "true" : null,
        dataset: { key: `camera-up:${camera.id}` },
        onclick: () => moveCamera(index, -1),
      }),
      iconButton("arrowDown", t("cameras.order.moveDown", { name: label }), {
        class: "room-order-step",
        "aria-disabled": index === count - 1 || busy ? "true" : null,
        dataset: { key: `camera-down:${camera.id}` },
        onclick: () => moveCamera(index, 1),
      }),
      iconButton("grip", t("cameras.order.move", { name: label }), {
        class: "room-order-handle",
        "aria-describedby": "camera-order-keys",
        disabled: busy,
        dataset: { key: `camera-move:${camera.id}` },
        ...cameraSorter.handle,
      })
    )
  );
}
