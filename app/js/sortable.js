// Moving the items of a list by their handle: dragged with a mouse at once, or with a finger or a
// pen once held (a swipe that starts on the handle still scrolls the page), or with the keyboard
// (Space or Enter picks it up, the arrow keys, Home and End move it, Space or Enter puts it down,
// Escape puts it back). The others make room, the item glides into its place, and a screen reader
// hears where it is. Settings → Rooms (the home's room order) and the Cameras tab's Order (the
// home's camera order, 1.12.1) use it; the rules themselves are in reorder.js.

import { h } from "./dom.js";
import { t } from "./i18n.js";
import { dropIndex, edgeScroll, keyTarget, moveItem, sameOrder, shiftOf, slotOffset } from "./reorder.js";
import { notify, ui } from "./state.js";

// Touch and pen: the handle is held this long, moving less than HOLD_SLOP pixels, before the item
// lifts; a swipe that starts on it scrolls the page.
const HOLD_MS = 250;
const HOLD_SLOP = 10;
// The item gliding into its place when it is let go (at once with reduced motion).
const SETTLE_MS = 150;

// A list whose rows (`.room-order-row`, one per item, in a list of their own) can be moved:
// `items()` is the list as shown, `label(item)` its name in the announcements, `onDrop(order)` gets
// the new order once an item is put down somewhere else, and `words` is where the announcements are
// in the dictionaries ("settings.rooms": lifted, position, dropped, cancelled). Returns the handle's
// event handlers (`handle`) and whether an item is being moved (`busy()`).
export function sortable({ items, label, onDrop, words }) {
  // The item being moved: its handle, row and list, where each row is (tops and heights, without
  // the shifts) and the place it is shown at (`to`). `pointerId` is null when it moves with the
  // keyboard.
  let moving = null;
  let holding = null; // touch and pen: { handle, pointerId, x, y, lastY, timer } until the item lifts

  // The moving item's name and a place in the list, for the announcements.
  const placeText = (index) => ({ name: label(moving.items[moving.from]), position: index + 1, count: moving.rows.length });

  function lift(handle, pointer = null) {
    const list = items();
    const row = handle.closest(".room-order-row");
    const parent = row?.parentElement;
    const rows = parent ? [...parent.children] : [];
    const from = rows.indexOf(row);
    if (from < 0 || rows.length !== list.length) return;
    const tops = rows.map((item) => item.offsetTop);
    const heights = rows.map((item) => item.offsetHeight);
    const listTop = parent.getBoundingClientRect().top;
    moving = {
      handle,
      row,
      list: parent,
      rows,
      items: list,
      from,
      to: from,
      tops,
      heights,
      middles: tops.map((top, index) => top + heights[index] / 2),
      pointerId: pointer ? pointer.pointerId : null,
      // Where the pointer holds the item, from the top of the list, and where the list was then.
      grabbed: pointer ? pointer.clientY - listTop : 0,
      listTop,
      y: pointer ? pointer.clientY : 0,
      frame: pointer ? requestAnimationFrame(autoScroll) : 0,
      timer: 0,
      settling: false,
      placed: false,
    };
    ui.reordering = true;
    parent.classList.add("is-sorting");
    row.classList.add("is-moving");
    if (pointer) row.classList.add("is-following");
    document.addEventListener("keydown", escapeKey);
    window.addEventListener("blur", cancelMove);
    // Before app.js redraws the new screen.
    window.addEventListener("hashchange", cancelMove, true);
    announce(t(`${words}.lifted`, placeText(from)));
  }

  // Shows the moving item at `to`: the items in between make room for it.
  function place(to) {
    const { rows, row, from, heights } = moving;
    if (to === moving.to) return;
    moving.to = to;
    rows.forEach((item, index) => {
      const shift = shiftOf(index, from, to);
      if (item !== row) item.style.transform = shift ? `translateY(${shift * heights[from]}px)` : "";
    });
    announce(t(`${words}.position`, placeText(to)));
  }

  // The pointer at `y` (in the viewport): the item follows it, within the list.
  function follow(y) {
    const { list, row, from, tops, heights } = moving;
    const last = tops.length - 1;
    moving.y = y;
    moving.listTop = list.getBoundingClientRect().top;
    const offset = Math.min(
      Math.max(y - moving.listTop - moving.grabbed, tops[0] - tops[from]),
      tops[last] + heights[last] - tops[from] - heights[from]
    );
    row.style.transform = `translateY(${offset}px)`;
    place(dropIndex(moving.middles, from, tops[from] + offset, tops[from] + heights[from] + offset));
  }

  // While dragged near the top or the bottom of the screen, the page scrolls as far as the list goes
  // on past it. The item stays under the pointer when the page scrolls otherwise too (a mouse wheel).
  function autoScroll() {
    if (!moving) return;
    moving.frame = requestAnimationFrame(autoScroll);
    const bottom = visibleBottom();
    const box = moving.list.getBoundingClientRect();
    const step = edgeScroll(moving.y, 0, bottom);
    const by = step < 0 ? Math.max(step, Math.min(0, box.top)) : Math.min(step, Math.max(0, box.bottom - bottom));
    if (Math.abs(by) >= 1) window.scrollBy(0, by);
    if (Math.abs(by) >= 1 || box.top !== moving.listTop) follow(moving.y);
  }

  // Keyboard: the moving item stays on screen.
  function reveal() {
    const { list, from, to, tops, heights } = moving;
    const top = list.getBoundingClientRect().top + tops[from] + slotOffset(heights, from, to);
    const bottom = visibleBottom();
    if (top < 0) window.scrollBy(0, top - 8);
    else if (top + heights[from] > bottom) window.scrollBy(0, top + heights[from] - bottom + 8);
  }

  // Let go: the item glides into its place and `onDrop` gets the new order (nothing when it is where
  // it was). Redraws wait until it is there.
  function drop() {
    const { row, items: list, from, to, heights } = moving;
    const order = moveItem(list, from, to);
    cancelAnimationFrame(moving.frame);
    moving.settling = true;
    moving.placed = !sameOrder(order, list);
    row.classList.remove("is-following");
    row.style.transform = moving.placed ? `translateY(${slotOffset(heights, from, to)}px)` : "";
    announce(t(`${words}.dropped`, placeText(to)));
    if (moving.placed) onDrop(order);
    if (moving.pointerId === null || window.matchMedia?.("(prefers-reduced-motion: reduce)").matches) {
      finish(moving.placed);
    } else {
      moving.timer = window.setTimeout(() => finish(moving.placed), SETTLE_MS);
    }
  }

  // Escape, a cancelled touch, leaving the screen: the item goes back to where it was.
  function cancelMove() {
    if (!moving) return;
    if (moving.settling) {
      finish(moving.placed);
      return;
    }
    announce(t(`${words}.cancelled`, placeText(moving.from)));
    finish(false);
  }

  // The move is over and redraws go on. `placed`: the rows stay as they are until the redraw draws
  // the new order; otherwise they glide back.
  function finish(placed) {
    const { list, rows, row, frame, timer } = moving;
    cancelAnimationFrame(frame);
    window.clearTimeout(timer);
    moving = null;
    ui.reordering = false;
    document.removeEventListener("keydown", escapeKey);
    window.removeEventListener("blur", cancelMove);
    window.removeEventListener("hashchange", cancelMove, true);
    if (!placed) {
      row.classList.remove("is-moving", "is-following");
      for (const item of rows) item.style.transform = "";
      window.setTimeout(() => {
        if (moving?.list !== list) list.classList.remove("is-sorting");
      }, SETTLE_MS);
    }
    notify();
  }

  function pressHandle(event) {
    if (moving || holding || !event.isPrimary || event.button !== 0) return;
    const handle = event.currentTarget;
    if (event.pointerType === "mouse") {
      event.preventDefault(); // no text selection while the item is dragged
      handle.setPointerCapture(event.pointerId);
      lift(handle, event);
      return;
    }
    // Touch and pen: held first, so that a swipe that starts on the handle still scrolls the page.
    holding = {
      handle,
      pointerId: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      lastY: event.clientY,
      timer: window.setTimeout(() => {
        const held = holding;
        holding = null;
        if (!held.handle.isConnected) return;
        try {
          held.handle.setPointerCapture(held.pointerId);
        } catch {
          return; // the finger is gone
        }
        lift(held.handle, { pointerId: held.pointerId, clientY: held.lastY });
      }, HOLD_MS),
    };
  }

  function stopHolding() {
    window.clearTimeout(holding.timer);
    holding = null;
  }

  const dragging = (event) => moving && !moving.settling && moving.pointerId === event.pointerId;

  function movePointer(event) {
    if (holding?.pointerId === event.pointerId) {
      holding.lastY = event.clientY;
      // Moved first: scrolling, not a drag.
      if (Math.hypot(event.clientX - holding.x, event.clientY - holding.y) > HOLD_SLOP) stopHolding();
    } else if (dragging(event)) {
      follow(event.clientY);
    }
  }

  function releasePointer(event) {
    if (holding?.pointerId === event.pointerId) stopHolding();
    else if (dragging(event)) drop();
  }

  function cancelPointer(event) {
    if (holding?.pointerId === event.pointerId) stopHolding();
    else if (dragging(event)) cancelMove();
  }

  function escapeKey(event) {
    if (event.key === "Escape" && moving && !moving.settling) {
      event.preventDefault();
      cancelMove();
    }
  }

  // Keyboard: Space or Enter picks the item up and puts it down, the arrows (Home, End) move it.
  function handleKey(event) {
    const handle = event.currentTarget;
    if (moving && (moving.pointerId !== null || moving.settling)) return;
    if (event.key === " " || event.key === "Enter") {
      event.preventDefault();
      if (event.repeat) return;
      if (!moving) lift(handle);
      else if (moving.handle === handle) drop();
      return;
    }
    const to = moving?.handle === handle ? keyTarget(moving.to, event.key, moving.rows.length) : null;
    if (to === null) return;
    event.preventDefault();
    place(to);
    moving.row.style.transform = `translateY(${slotOffset(moving.heights, moving.from, to)}px)`;
    reveal();
  }

  // Keyboard: focus going elsewhere puts the item back.
  function leaveHandle(event) {
    if (moving?.handle === event.currentTarget && moving.pointerId === null) cancelMove();
  }

  return {
    busy: () => moving !== null,
    // The handle's events (with iconButton's props).
    handle: {
      onpointerdown: pressHandle,
      onpointermove: movePointer,
      onpointerup: releasePointer,
      onpointercancel: cancelPointer,
      onkeydown: handleKey,
      onblur: leaveHandle,
      // Touch: once the item is lifted, the finger moves it instead of scrolling the page, and
      // holding it does not open a menu.
      ontouchmove: (event) => {
        if (moving?.handle === event.currentTarget) event.preventDefault();
      },
      oncontextmenu: (event) => {
        if (moving || holding) event.preventDefault();
      },
    },
  };
}

// Where the screen ends: above the tab bar on phones (on wide screens it is a rail at the side).
function visibleBottom() {
  const bar = document.querySelector("#tabbar")?.getBoundingClientRect();
  return bar && bar.top > window.innerHeight / 2 ? bar.top : window.innerHeight;
}

// Screen readers hear where the moving item is: one polite region, outside the view so that
// redraws keep it; its text goes after a while. Made by a list that can be moved before its first
// move, so that it is on the page when the first announcement comes.
let liveRegion = null;
let liveTimer = 0;

export function orderStatus() {
  if (!liveRegion) {
    liveRegion = h("p", { class: "visually-hidden", role: "status" });
    document.body.append(liveRegion);
  }
  return liveRegion;
}

function announce(text) {
  orderStatus().textContent = text;
  window.clearTimeout(liveTimer);
  liveTimer = window.setTimeout(() => {
    liveRegion.textContent = "";
  }, 10000);
}
