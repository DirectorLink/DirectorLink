// Offline copy (service worker), online/offline notice and the install prompt.

import { notify, state } from "./state.js";

let installPrompt = null;

async function refreshOfflineStatus() {
  if (!("caches" in window)) {
    state.offlineCopy = "unsupported";
  } else {
    const saved = await caches.match("/");
    state.offlineCopy = saved ? (navigator.onLine ? "ready" : "inUse") : navigator.onLine ? "saving" : "missing";
  }
  notify();
}

export function startPwa() {
  if ("serviceWorker" in navigator) {
    navigator.serviceWorker
      .register("/sw.js", { scope: "/" })
      .then(() => navigator.serviceWorker.ready)
      .then(refreshOfflineStatus)
      .catch(() => {
        state.offlineCopy = "failed";
        notify();
      });
  } else {
    state.offlineCopy = "unsupported";
  }

  const onlineChanged = () => {
    state.online = navigator.onLine;
    refreshOfflineStatus().catch(() => {});
    notify();
  };
  window.addEventListener("online", onlineChanged);
  window.addEventListener("offline", onlineChanged);

  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    installPrompt = event;
    state.canInstall = true;
    notify();
  });
  window.addEventListener("appinstalled", () => {
    installPrompt = null;
    state.canInstall = false;
    notify();
  });
}

export async function installApp() {
  if (!installPrompt) return;
  installPrompt.prompt();
  await installPrompt.userChoice;
  installPrompt = null;
  state.canInstall = false;
  notify();
}
