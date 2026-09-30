// Moving one item of a list to another place: the rooms in Settings → Rooms, dragged by their
// handle or moved with the keyboard. No imports, so the rules can be tested under Node
// (tests/app/room-order.test.mjs).

// A copy of `list` with the item at `from` moved to `to`; the others keep their order.
export function moveItem(list, from, to) {
  const moved = [...list];
  if (!(from >= 0 && from < moved.length)) return moved;
  const [item] = moved.splice(from, 1);
  moved.splice(Math.min(Math.max(to, 0), moved.length), 0, item);
  return moved;
}

// Whether two lists hold the same items, by `key`, in the same order: then there is nothing to save.
export function sameOrder(a, b, key = (item) => item.id) {
  return a.length === b.length && a.every((item, index) => key(item) === key(b[index]));
}

// Where a key takes the item at `index` of `count`: Arrow Up and Down one place, Home and End to
// the first and the last place. Null for any other key.
export function keyTarget(index, key, count) {
  let target;
  if (key === "ArrowUp") target = index - 1;
  else if (key === "ArrowDown") target = index + 1;
  else if (key === "Home") target = 0;
  else if (key === "End") target = count - 1;
  else return null;
  return Math.min(Math.max(target, 0), count - 1);
}

// Where the item at `from` lands while dragged to `top`…`bottom`: past every item whose middle
// (`middles`, top to bottom, where the items are before the drag) its leading edge has crossed. So
// half over its neighbour it takes its place, and at either end of the list it reaches the end,
// whatever the heights.
export function dropIndex(middles, from, top, bottom) {
  let index = from;
  middles.forEach((middle, other) => {
    if (other < from && top < middle) index -= 1;
    if (other > from && bottom > middle) index += 1;
  });
  return index;
}

// How the item at `index` makes room while the one at `from` is shown at `to`: -1 moves it up by
// the dragged item's height, 1 down, 0 leaves it where it is.
export function shiftOf(index, from, to) {
  if (index > from && index <= to) return -1;
  if (index < from && index >= to) return 1;
  return 0;
}

// How far the item at `from` moves to be shown at `to`: the heights of the items it passes.
export function slotOffset(heights, from, to) {
  let offset = 0;
  for (let index = Math.min(from, to); index <= Math.max(from, to); index += 1) {
    if (index !== from) offset += heights[index];
  }
  return to >= from ? offset : -offset;
}

// Pixels to scroll, in one frame, for a pointer at `y` near the top or the bottom of the visible
// area (`top` to `bottom`): within `edge` of it, faster closer to it, and at most `max`. 0 elsewhere.
export function edgeScroll(y, top, bottom, edge = 56, max = 16) {
  if (y < top + edge) return -Math.ceil(max * Math.min(1, (top + edge - y) / edge));
  if (y > bottom - edge) return Math.ceil(max * Math.min(1, (y - bottom + edge) / edge));
  return 0;
}
