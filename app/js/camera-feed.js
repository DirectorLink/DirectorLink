// Camera pictures, fetched as blobs with the API key (an <img src> cannot send it).
// Thumbnails on screen refresh one after another about every 3 s; live pictures (data-live: the
// doorbell banner) and the full view about every second. Only tiles that are visible refresh,
// and nothing refreshes while the page is hidden.
//
// Markup: <div class="cam" data-state="loading|ok|busy|none"><img data-camera-id data-width [data-live]></div>

import { formatTime, t } from "./i18n.js";
import { handleUnauthorized, image } from "./session.js";
import { findDevice, state } from "./state.js";

// Through the account every picture is sealed and relayed, so it refreshes less often.
const remote = () => state.transport === "remote";
const GRID_REFRESH_MS = () => (remote() ? 10000 : 3000);
const FULL_REFRESH_MS = () => (remote() ? 3000 : 1000);
const LIVE_REFRESH_MS = () => (remote() ? 2000 : 1000);
const pictures = new Map(); // "cameraId:width" -> { url, at }
const visible = new WeakSet();
const observed = new Set();
// One loop each; a redraw while a loop waits for a picture must not start a second one.
let gridTimer = null;
let gridRunning = false;
let liveRunning = false;
let full = null; // { camera, image, status, timer }

// A camera by id: from /v1/cameras, or a doorbell's own camera.
function cameraById(id) {
  const camera = findDevice("camera", id);
  if (camera) return camera;
  const doorbell = state.doorbells.find((item) => item.camera?.id === Number(id));
  return doorbell ? { id: doorbell.camera.id, name: doorbell.name, snapshot_href: doorbell.camera.snapshot_href } : null;
}

const observer =
  "IntersectionObserver" in window
    ? new IntersectionObserver((entries) => {
        for (const entry of entries) {
          if (entry.isIntersecting) visible.add(entry.target);
          else visible.delete(entry.target);
        }
      })
    : null;

async function fetchPicture(camera, width) {
  const blob = await image(`${camera.snapshot_href}?width=${width}`);
  const key = `${camera.id}:${width}`;
  const previous = pictures.get(key);
  const url = URL.createObjectURL(blob);
  pictures.set(key, { url, at: new Date() });
  // Revoke after the new picture had time to replace the old one everywhere.
  if (previous) window.setTimeout(() => URL.revokeObjectURL(previous.url), 2000);
  return url;
}

function bestPicture(cameraId, width) {
  const exact = pictures.get(`${cameraId}:${width}`);
  if (exact) return exact;
  let best = null;
  for (const [key, value] of pictures) {
    const [id, size] = key.split(":").map(Number);
    if (id === Number(cameraId) && (!best || size > best.size)) best = { ...value, size };
  }
  return best;
}

function setTileState(image, tileState) {
  const tile = image.closest(".cam");
  if (tile && tile.dataset.state !== tileState) tile.dataset.state = tileState;
}

// Call after every render: shows the last picture at once and watches visibility.
// A picture the browser cannot decode counts as "No picture".
function watchDecoding(image) {
  if (image.dataset.watched) return;
  image.dataset.watched = "1";
  image.addEventListener("error", () => setTileState(image, "none"));
  image.addEventListener("load", () => setTileState(image, "ok"));
}

export function attachCameraImages(root) {
  for (const image of root.querySelectorAll("img[data-camera-id]")) {
    watchDecoding(image);
    const picture = bestPicture(image.dataset.cameraId, Number(image.dataset.width));
    if (picture) {
      image.src = picture.url;
    }
    if (observer && !observed.has(image)) {
      observer.observe(image);
      observed.add(image);
    }
  }
  forgetRemoved();
  scheduleGrid(picturesPending(root) ? 400 : GRID_REFRESH_MS());
  if (!liveRunning && root.querySelector("img[data-camera-id][data-live]")) {
    liveRunning = true;
    window.setTimeout(refreshLive, 250);
  }
}

function scheduleGrid(delay) {
  if (gridRunning || gridTimer) return;
  gridTimer = window.setTimeout(refreshGrid, delay);
}

// Images replaced by a redraw are no longer watched.
function forgetRemoved() {
  for (const image of observed) {
    if (!image.isConnected) {
      observer.unobserve(image);
      observed.delete(image);
    }
  }
}

function picturesPending(root) {
  return [...root.querySelectorAll("img[data-camera-id]")].some((image) => !image.getAttribute("src"));
}

function isVisible(image) {
  return image.isConnected && (!observer || visible.has(image));
}

// One request per camera and size, however many tiles show it.
async function refreshImages(images, stillWanted) {
  const jobs = new Map();
  for (const image of images.filter(isVisible)) {
    const key = `${image.dataset.cameraId}:${image.dataset.width}`;
    if (!jobs.has(key)) jobs.set(key, []);
    jobs.get(key).push(image);
  }
  for (const [key, targets] of jobs) {
    const [id, width] = key.split(":").map(Number);
    if (!stillWanted()) break;
    const camera = cameraById(id);
    if (!camera) continue;
    try {
      const url = await fetchPicture(camera, width);
      for (const image of targets) {
        image.src = url;
      }
    } catch (error) {
      if (error?.status === 401) {
        handleUnauthorized();
        return false;
      }
      for (const image of targets) {
        // 503: the camera proxy is busy; keep the last picture and try again next round.
        if (error?.status !== 503) setTileState(image, "none");
        else if (!image.getAttribute("src")) setTileState(image, "busy");
      }
    }
  }
  return true;
}

const canRefresh = () => !document.hidden && !full && state.apiKey && state.status === "connected";

// Live pictures (the doorbell banner), about every second while one is on screen.
async function refreshLive() {
  const images = [...document.querySelectorAll("img[data-camera-id][data-live]")].filter((image) => !image.closest("dialog"));
  if (!images.length || (canRefresh() && !(await refreshImages(images, canRefresh)))) {
    liveRunning = false;
    return;
  }
  window.setTimeout(refreshLive, LIVE_REFRESH_MS());
}

async function refreshGrid() {
  gridTimer = null;
  const images = [...document.querySelectorAll("img[data-camera-id]:not([data-live])")].filter((image) => !image.closest("dialog"));
  if (!images.length) return;
  gridRunning = true;
  try {
    if (canRefresh() && !(await refreshImages(images, canRefresh))) return;
  } finally {
    gridRunning = false;
  }
  scheduleGrid(GRID_REFRESH_MS());
}

// Full view in a <dialog>; the picture size follows the screen.
export function openFullView(dialog, camera, { titleElement, image, status }) {
  closeFullView();
  titleElement.textContent = camera.name;
  image.alt = t("cameras.pictureOf", { name: camera.name });
  watchDecoding(image);
  image.removeAttribute("src");
  const cached = bestPicture(camera.id, 1280);
  if (cached) image.src = cached.url;
  status.textContent = t("common.loading");
  setTileState(image, "loading");
  const width = window.innerWidth * (window.devicePixelRatio || 1) > 1400 ? 1920 : 1280;
  full = { camera, image, status, dialog, width, timer: null };
  if (!dialog.open) dialog.showModal();
  refreshFull();
}

async function refreshFull() {
  if (!full) return;
  const current = full;
  current.timer = null;
  if (!document.hidden) {
    try {
      current.image.src = await fetchPicture(current.camera, current.width);
      if (full !== current) return;
      current.status.textContent = t("cameras.updated", { time: formatTime(new Date()) });
    } catch (error) {
      if (full !== current) return;
      if (error?.status === 401) {
        closeFullView();
        handleUnauthorized();
        return;
      }
      if (error?.status === 503) {
        current.status.textContent = t("cameras.busy");
      } else {
        current.status.textContent = t("cameras.noPicture");
        if (!current.image.getAttribute("src")) setTileState(current.image, "none");
      }
    }
  }
  if (full === current) current.timer = window.setTimeout(refreshFull, FULL_REFRESH_MS());
}

export function closeFullView() {
  if (!full) return;
  window.clearTimeout(full.timer);
  const dialog = full.dialog;
  full = null;
  if (dialog.open) dialog.close();
  scheduleGrid(300);
}

export function fullViewCamera() {
  return full?.camera || null;
}
