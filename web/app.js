const DIRECTOR_STORAGE_KEY = "c4bridge.directorHost";
const TOKEN_STORAGE_KEY = "c4bridge.apiToken";
const API_PORT = 41999;

const directorForm = document.querySelector("#director-form");
const directorInput = document.querySelector("#director-host");
const apiTokenInput = document.querySelector("#api-token");
const connectButton = document.querySelector("#connect-button");
const directorMessage = document.querySelector("#director-message");
const savedDirector = document.querySelector("#saved-director");
const secureContext = document.querySelector("#secure-context");
const serviceWorkerStatus = document.querySelector("#service-worker-status");
const apiConnectionStatus = document.querySelector("#api-connection-status");
const installButton = document.querySelector("#install-button");
const bridgeStatusTitle = document.querySelector("#bridge-status-title");
const bridgeStatusText = document.querySelector("#bridge-status-text");
const projectResult = document.querySelector("#project-result");
const connectedVersion = document.querySelector("#connected-version");
const resultSummary = document.querySelector("#result-summary");
const roomList = document.querySelector("#room-list");
const deviceList = document.querySelector("#device-list");

let installPrompt = null;

function normalizeDirectorHost(value) {
  let host = value.trim();

  host = host.replace(/^https?:\/\//i, "");
  host = host.replace(/\/$/, "");

  if (!host || /[\s/]/.test(host) || host.includes(":")) {
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

function setConnectionState(title, detail, status) {
  bridgeStatusTitle.textContent = title;
  bridgeStatusText.textContent = detail;
  apiConnectionStatus.textContent = status;
}

function refreshSavedDirector() {
  const host = localStorage.getItem(DIRECTOR_STORAGE_KEY);
  const token = localStorage.getItem(TOKEN_STORAGE_KEY);

  if (host) {
    directorInput.value = host;
    savedDirector.textContent = host;
  } else {
    savedDirector.textContent = "Not set";
  }

  if (token) {
    apiTokenInput.value = token;
  }
}

function saveSetup() {
  const host = normalizeDirectorHost(directorInput.value);
  const token = apiTokenInput.value.trim();

  if (!host) {
    throw new Error("Enter a private IPv4 address or .local hostname without a port.");
  }
  if (!token) {
    throw new Error("Paste the API Token shown in the C4Bridge Composer properties.");
  }

  localStorage.setItem(DIRECTOR_STORAGE_KEY, host);
  localStorage.setItem(TOKEN_STORAGE_KEY, token);
  refreshSavedDirector();

  return { host, token };
}

function apiUrl(host, path) {
  return `http://${host}:${API_PORT}${path}`;
}

async function apiFetch(host, token, path) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 8000);

  try {
    const response = await fetch(apiUrl(host, path), {
      method: "GET",
      headers: {
        Authorization: `Bearer ${token}`,
      },
      cache: "no-store",
      signal: controller.signal,
      targetAddressSpace: "local",
    });

    const body = await response.json().catch(() => null);

    if (!response.ok) {
      const message =
        body?.error?.message || `C4Bridge returned HTTP ${response.status}`;
      const error = new Error(message);
      error.status = response.status;
      throw error;
    }

    return body;
  } finally {
    window.clearTimeout(timeout);
  }
}

function text(value, fallback = "—") {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }
  return String(value);
}

function renderSummary(info) {
  const items = [
    ["Bridge", info.bridge?.version],
    ["Director", info.director?.version],
    ["System", info.director?.system_type],
    ["Rooms", info.discovery?.rooms],
    ["Devices", info.discovery?.devices],
    ["Recognized", info.discovery?.recognized],
  ];

  resultSummary.replaceChildren(
    ...items.map(([label, value]) => {
      const item = document.createElement("div");
      const key = document.createElement("span");
      const val = document.createElement("strong");
      key.textContent = label;
      val.textContent = text(value);
      item.append(key, val);
      return item;
    })
  );
}

function renderRooms(rooms) {
  roomList.replaceChildren();

  if (!rooms.length) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No rooms returned.";
    roomList.append(empty);
    return;
  }

  for (const room of rooms) {
    const item = document.createElement("div");
    item.className = "entity-row";

    const main = document.createElement("div");
    const name = document.createElement("strong");
    const meta = document.createElement("small");
    name.textContent = text(room.name, `Room ${room.id}`);
    meta.textContent = `ID ${room.id}`;

    main.append(name, meta);
    item.append(main);
    roomList.append(item);
  }
}

function renderDevices(devices) {
  deviceList.replaceChildren();

  if (!devices.length) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No devices returned.";
    deviceList.append(empty);
    return;
  }

  for (const device of devices) {
    const item = document.createElement("div");
    item.className = "entity-row device-row";

    const main = document.createElement("div");
    const name = document.createElement("strong");
    const meta = document.createElement("small");

    name.textContent = text(device.name, `Device ${device.id}`);
    meta.textContent = [
      `ID ${device.id}`,
      device.room_name || (device.room_id ? `Room ${device.room_id}` : null),
      device.proxy?.driver || null,
    ]
      .filter(Boolean)
      .join(" · ");

    const badge = document.createElement("span");
    badge.className = `kind-badge ${device.recognized ? "recognized" : ""}`;
    badge.textContent = text(device.kind, "unsupported");

    main.append(name, meta);
    item.append(main, badge);
    deviceList.append(item);
  }
}

async function connectAndTest() {
  projectResult.classList.add("hidden");
  connectButton.disabled = true;
  setDirectorMessage("");
  setConnectionState(
    "Connecting to Director…",
    "Chrome may ask for Local Network Access permission.",
    "Connecting…"
  );

  try {
    const { host, token } = saveSetup();

    // The first fetch intentionally originates from this user click so Chrome can
    // surface its Local Network Access permission prompt.
    const info = await apiFetch(host, token, "/v1/system/info");

    const [roomsResponse, devicesResponse] = await Promise.all([
      apiFetch(host, token, "/v1/rooms"),
      apiFetch(host, token, "/v1/devices"),
    ]);

    const rooms = Array.isArray(roomsResponse.rooms) ? roomsResponse.rooms : [];
    const devices = Array.isArray(devicesResponse.devices)
      ? devicesResponse.devices
      : [];

    connectedVersion.textContent = `v${text(info.bridge?.version, "?")}`;
    renderSummary(info);
    renderRooms(rooms);
    renderDevices(devices);
    projectResult.classList.remove("hidden");

    setConnectionState(
      "Connected to C4Bridge",
      `${rooms.length} rooms and ${devices.length} normalized devices returned directly from Director.`,
      "Connected"
    );
    setDirectorMessage("Read-only Step 2 API test succeeded.", "success");
  } catch (error) {
    const isUnauthorized = error.status === 401;
    const isAbort = error.name === "AbortError";

    let message;
    if (isUnauthorized) {
      message = "Director reached, but the API token was rejected.";
    } else if (isAbort) {
      message = "Connection timed out. Check the Director IP, API status, and LAN.";
    } else {
      message =
        "Could not reach C4Bridge. Allow Local Network Access and verify the Director IP, API port 41999, and token.";
    }

    setConnectionState("Connection failed", message, "Failed");
    setDirectorMessage(message, "error");
    console.error("C4Bridge connection test failed", error);
  } finally {
    connectButton.disabled = false;
  }
}

directorForm.addEventListener("submit", (event) => {
  event.preventDefault();
  try {
    saveSetup();
    setDirectorMessage("Saved locally in this browser.", "success");
  } catch (error) {
    setDirectorMessage(error.message, "error");
  }
});

connectButton.addEventListener("click", connectAndTest);

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
