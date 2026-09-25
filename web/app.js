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
const lightList = document.querySelector("#light-list");
const lightActionMessage = document.querySelector("#light-action-message");
const refreshLightsButton = document.querySelector("#refresh-lights-button");

let installPrompt = null;
let activeSession = null;

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

function setLightMessage(message, type = "") {
  lightActionMessage.textContent = message;
  lightActionMessage.className = "form-message";
  if (type) {
    lightActionMessage.classList.add(type);
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

async function apiRequest(host, token, path, options = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 8000);

  try {
    const response = await fetch(apiUrl(host, path), {
      method: options.method || "GET",
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
      error.code = body?.error?.code;
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
    ["Lights", info.discovery?.supported_lights],
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
    badge.className = `kind-badge ${device.supported ? "supported" : device.recognized ? "recognized" : ""}`;
    badge.textContent = device.supported ? "supported" : text(device.kind, "unsupported");

    main.append(name, meta);
    item.append(main, badge);
    deviceList.append(item);
  }
}

function lightStateLabel(light) {
  const power = light.state?.power === true;
  const brightness = Number(light.state?.brightness);

  if (light.capabilities?.brightness && Number.isFinite(brightness)) {
    return `${power ? "On" : "Off"} · ${brightness}%`;
  }

  return power ? "On" : "Off";
}

async function refreshLights(showMessage = false) {
  if (!activeSession) {
    return [];
  }

  const response = await apiRequest(
    activeSession.host,
    activeSession.token,
    "/v1/lights"
  );
  const lights = Array.isArray(response.lights) ? response.lights : [];
  renderLights(lights);

  if (showMessage) {
    setLightMessage(`Refreshed ${lights.length} light states.`, "success");
  }

  return lights;
}

function lightActionConfirmed(light, action, value) {
  if (!light?.state) {
    return false;
  }

  if (action === "on") {
    return light.state.power === true;
  }

  if (action === "off") {
    return light.state.power === false;
  }

  if (action === "set_brightness") {
    const actual = Number(light.state.brightness);
    const expected = Number(value);
    return Number.isFinite(actual) &&
      Number.isFinite(expected) &&
      Math.abs(actual - expected) <= 3;
  }

  return false;
}

async function waitForLightConfirmation(lightId, action, value) {
  const deadline = Date.now() + 5000;

  while (Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 500));
    const lights = await refreshLights(false);
    const updated = lights.find((candidate) => Number(candidate.id) === Number(lightId));

    if (updated && lightActionConfirmed(updated, action, value)) {
      return updated;
    }
  }

  return null;
}

async function runLightAction(light, action, value, control) {
  if (!activeSession) {
    setLightMessage("Connect to Director first.", "error");
    return;
  }

  const previousDisabled = control?.disabled;
  if (control) {
    control.disabled = true;
  }

  const suffix =
    action === "set_brightness"
      ? `?value=${encodeURIComponent(value)}`
      : "";

  setLightMessage(
    action === "set_brightness"
      ? `Setting ${light.name} to ${value}%…`
      : `Turning ${light.name} ${action}…`
  );

  try {
    await apiRequest(
      activeSession.host,
      activeSession.token,
      `/v1/devices/${light.id}/actions/${action}${suffix}`,
      { method: "POST" }
    );

    setLightMessage(`Command sent to ${light.name}; waiting for Director state…`);

    const confirmed = await waitForLightConfirmation(light.id, action, value);

    if (confirmed) {
      setLightMessage(
        `${light.name}: ${lightStateLabel(confirmed)} confirmed by Director.`,
        "success"
      );
    } else {
      setLightMessage(
        `${light.name}: command was sent, but Director did not confirm the requested state within 5 seconds.`,
        "error"
      );
    }
  } catch (error) {
    setLightMessage(
      `${light.name}: ${error.message || "light command failed"}`,
      "error"
    );
  } finally {
    if (control) {
      control.disabled = previousDisabled || false;
    }
  }
}

function renderLights(lights) {
  lightList.replaceChildren();

  if (!lights.length) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No supported Light V2 devices were initialized.";
    lightList.append(empty);
    return;
  }

  for (const light of lights) {
    const item = document.createElement("div");
    item.className = "light-row";

    const identity = document.createElement("div");
    identity.className = "light-identity";

    const name = document.createElement("strong");
    const meta = document.createElement("small");
    const state = document.createElement("span");

    name.textContent = text(light.name, `Light ${light.id}`);
    meta.textContent = [
      light.room_name || (light.room_id ? `Room ${light.room_id}` : null),
      `ID ${light.id}`,
    ]
      .filter(Boolean)
      .join(" · ");
    state.className = `light-state ${light.state?.power ? "is-on" : ""}`;
    state.textContent = lightStateLabel(light);

    identity.append(name, meta, state);

    const controls = document.createElement("div");
    controls.className = "light-controls";

    const offButton = document.createElement("button");
    offButton.type = "button";
    offButton.className = "button light-button";
    offButton.textContent = "Off";
    offButton.addEventListener("click", () =>
      runLightAction(light, "off", null, offButton)
    );

    const onButton = document.createElement("button");
    onButton.type = "button";
    onButton.className = "button light-button light-button-on";
    onButton.textContent = "On";
    onButton.addEventListener("click", () =>
      runLightAction(light, "on", null, onButton)
    );

    controls.append(offButton, onButton);

    if (light.capabilities?.brightness) {
      const brightnessWrap = document.createElement("label");
      brightnessWrap.className = "brightness-control";

      const slider = document.createElement("input");
      slider.type = "range";
      slider.min = "0";
      slider.max = "100";
      slider.step = "1";
      slider.value = String(
        Number.isFinite(Number(light.state?.brightness))
          ? Number(light.state.brightness)
          : light.state?.power
            ? 100
            : 0
      );
      slider.setAttribute("aria-label", `${light.name} brightness`);

      const output = document.createElement("output");
      output.textContent = `${slider.value}%`;

      slider.addEventListener("input", () => {
        output.textContent = `${slider.value}%`;
      });
      slider.addEventListener("change", () =>
        runLightAction(light, "set_brightness", slider.value, slider)
      );

      brightnessWrap.append(slider, output);
      controls.append(brightnessWrap);
    }

    item.append(identity, controls);
    lightList.append(item);
  }
}

async function connectAndTest() {
  projectResult.classList.add("hidden");
  connectButton.disabled = true;
  setDirectorMessage("");
  setLightMessage("");
  setConnectionState(
    "Connecting to Director…",
    "Chrome may ask for Local Network Access permission.",
    "Connecting…"
  );

  try {
    const { host, token } = saveSetup();
    activeSession = { host, token };

    const info = await apiRequest(host, token, "/v1/system/info");

    const [roomsResponse, devicesResponse, lightsResponse] = await Promise.all([
      apiRequest(host, token, "/v1/rooms"),
      apiRequest(host, token, "/v1/devices"),
      apiRequest(host, token, "/v1/lights"),
    ]);

    const rooms = Array.isArray(roomsResponse.rooms) ? roomsResponse.rooms : [];
    const devices = Array.isArray(devicesResponse.devices)
      ? devicesResponse.devices
      : [];
    const lights = Array.isArray(lightsResponse.lights)
      ? lightsResponse.lights
      : [];

    connectedVersion.textContent = `v${text(info.bridge?.version, "?")}`;
    renderSummary(info);
    renderLights(lights);
    renderRooms(rooms);
    renderDevices(devices);
    projectResult.classList.remove("hidden");

    setConnectionState(
      "Connected to C4Bridge",
      `${rooms.length} rooms, ${devices.length} normalized devices, and ${lights.length} controllable lights returned directly from Director.`,
      "Connected"
    );
    setDirectorMessage("Director connection succeeded.", "success");
  } catch (error) {
    activeSession = null;

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

refreshLightsButton.addEventListener("click", async () => {
  refreshLightsButton.disabled = true;
  setLightMessage("Refreshing light states…");
  try {
    await refreshLights(true);
  } catch (error) {
    setLightMessage(error.message || "Unable to refresh light states.", "error");
  } finally {
    refreshLightsButton.disabled = false;
  }
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
