const DIRECTOR_STORAGE_KEY = "c4bridge.directorHost";

const directorForm = document.querySelector("#director-form");
const directorInput = document.querySelector("#director-host");
const directorMessage = document.querySelector("#director-message");
const savedDirector = document.querySelector("#saved-director");
const secureContext = document.querySelector("#secure-context");
const serviceWorkerStatus = document.querySelector("#service-worker-status");
const installButton = document.querySelector("#install-button");

let installPrompt = null;

function normalizeDirectorHost(value) {
  let host = value.trim();

  host = host.replace(/^https?:\/\//i, "");
  host = host.replace(/\/$/, "");

  if (!host || /[\s/]/.test(host)) {
    return null;
  }

  return host;
}

function setDirectorMessage(message, type = "") {
  directorMessage.textContent = message;
  directorMessage.className = "form-message";
  if (type) {
    directorMessage.classList.add(type);
  }
}

function refreshSavedDirector() {
  const host = localStorage.getItem(DIRECTOR_STORAGE_KEY);

  if (host) {
    directorInput.value = host;
    savedDirector.textContent = host;
  } else {
    savedDirector.textContent = "Not set";
  }
}

directorForm.addEventListener("submit", (event) => {
  event.preventDefault();

  const host = normalizeDirectorHost(directorInput.value);
  if (!host) {
    setDirectorMessage("Enter an IP address or local hostname without a path.", "error");
    return;
  }

  localStorage.setItem(DIRECTOR_STORAGE_KEY, host);
  refreshSavedDirector();
  setDirectorMessage("Saved locally in this browser.", "success");
});

secureContext.textContent = window.isSecureContext ? "Ready (HTTPS)" : "HTTPS required";

if ("serviceWorker" in navigator) {
  navigator.serviceWorker
    .register("/sw.js", { scope: "/" })
    .then(() => {
      serviceWorkerStatus.textContent = "Registered";
    })
    .catch(() => {
      serviceWorkerStatus.textContent = "Registration failed";
    });
} else {
  serviceWorkerStatus.textContent = "Not supported";
}

window.addEventListener("beforeinstallprompt", (event) => {
  event.preventDefault();
  installPrompt = event;
  installButton.classList.remove("hidden");
});

installButton.addEventListener("click", async () => {
  if (!installPrompt) {
    return;
  }

  installPrompt.prompt();
  await installPrompt.userChoice;
  installPrompt = null;
  installButton.classList.add("hidden");
});

window.addEventListener("appinstalled", () => {
  installPrompt = null;
  installButton.classList.add("hidden");
});

refreshSavedDirector();
