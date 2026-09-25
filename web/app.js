const DIRECTOR_STORAGE_KEY = "c4bridge.directorHost";
const TOKEN_STORAGE_KEY = "c4bridge.apiToken";
const API_PORT = 41999;

const directorForm = document.querySelector("#director-form");
const directorInput = document.querySelector("#director-host");
const pairingCodeInput = document.querySelector("#pairing-code");
const connectButton = document.querySelector("#connect-button");
const directorMessage = document.querySelector("#director-message");
const savedDirector = document.querySelector("#saved-director");
const secureContext = document.querySelector("#secure-context");
const serviceWorkerStatus = document.querySelector("#service-worker-status");
const savedPairing = document.querySelector("#saved-pairing");
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
const climateList = document.querySelector("#climate-list");
const climateActionMessage = document.querySelector("#climate-action-message");
const refreshClimateButton = document.querySelector("#refresh-climate-button");

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

  savedPairing.textContent = token ? "Paired in this browser" : "Not paired";
  connectButton.textContent = token ? "Connect" : "Pair & connect";
}

function saveSetup() {
  const host = normalizeDirectorHost(directorInput.value);

  if (!host) {
    throw new Error("Enter a private IPv4 address or .local hostname without a port.");
  }

  localStorage.setItem(DIRECTOR_STORAGE_KEY, host);
  refreshSavedDirector();

  return { host };
}

function apiUrl(host, path) {
  return `http://${host}:${API_PORT}${path}`;
}

async function apiRequest(host, token, path, options = {}) {
  const controller = new AbortController();
  const timeout = window.setTimeout(() => controller.abort(), 8000);
  const headers = { ...(options.headers || {}) };

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  try {
    const response = await fetch(apiUrl(host, path), {
      method: options.method || "GET",
      headers,
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

async function pairBrowser(host, pairingCode) {
  const code = String(pairingCode || "").trim();
  if (!/^\d{8}$/.test(code)) {
    const error = new Error("Enter the 8-digit Pairing Code shown in Composer.");
    error.code = "PAIRING_REQUIRED";
    throw error;
  }

  const response = await apiRequest(host, null, "/v1/pair", {
    method: "POST",
    headers: {
      "X-C4Bridge-Pairing-Code": code,
    },
  });

  const token = response?.credential?.token;
  if (!token) {
    throw new Error("C4Bridge paired, but no owner credential was returned.");
  }

  localStorage.setItem(TOKEN_STORAGE_KEY, token);
  pairingCodeInput.value = "";
  refreshSavedDirector();
  return token;
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
    ["Climate", info.discovery?.supported_climate],
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

  if (light.capabilities?.brightness_feedback === false) {
    return `${power ? "On" : "Off"} · level feedback unavailable`;
  }

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

    if (action === "set_brightness" && light.capabilities?.brightness_feedback === false) {
      setLightMessage(
        `${light.name}: brightness command sent (${value}%). This KNX driver does not report level feedback to Director.`,
        "success"
      );
    } else {
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


function setClimateMessage(message, type = "") {
  climateActionMessage.textContent = message;
  climateActionMessage.className = "form-message";
  if (type) climateActionMessage.classList.add(type);
}

function climateStateLabel(device) {
  const current = Number(device.state?.current_temperature_c);
  const target = Number(device.state?.target_temperature_c);
  const parts = [];
  if (Number.isFinite(current)) parts.push(`Current ${current}°C`);
  if (Number.isFinite(target)) parts.push(`Target ${target}°C`);
  if (device.state?.hvac_mode) parts.push(String(device.state.hvac_mode));
  if (device.state?.fan_mode) parts.push(`fan ${device.state.fan_mode}`);
  return parts.join(" · ") || "State unavailable";
}

async function refreshClimate(showMessage = false) {
  if (!activeSession) return [];
  const response = await apiRequest(activeSession.host, activeSession.token, "/v1/climate");
  const devices = Array.isArray(response.climate) ? response.climate : [];
  renderClimate(devices);
  if (showMessage) setClimateMessage(`Refreshed ${devices.length} climate devices.`, "success");
  return devices;
}

async function runClimateAction(device, action, value, control) {
  if (!activeSession) {
    setClimateMessage("Connect to Director first.", "error");
    return;
  }
  if (control) control.disabled = true;
  setClimateMessage(`Sending climate command to ${device.name}…`);
  try {
    await apiRequest(
      activeSession.host,
      activeSession.token,
      `/v1/devices/${device.id}/actions/${action}?value=${encodeURIComponent(value)}`,
      { method: "POST" }
    );
    await new Promise((resolve) => window.setTimeout(resolve, 800));
    await refreshClimate(false);
    setClimateMessage(`${device.name}: command sent to Director.`, "success");
  } catch (error) {
    setClimateMessage(`${device.name}: ${error.message || "climate command failed"}`, "error");
  } finally {
    if (control) control.disabled = false;
  }
}

function renderClimate(devices) {
  climateList.replaceChildren();
  if (!devices.length) {
    const empty = document.createElement("p");
    empty.className = "empty-state";
    empty.textContent = "No supported Thermostat V2 devices were initialized.";
    climateList.append(empty);
    return;
  }

  for (const device of devices) {
    const row = document.createElement("div");
    row.className = "climate-row";

    const identity = document.createElement("div");
    identity.className = "light-identity";
    const name = document.createElement("strong");
    name.textContent = text(device.name, `Climate ${device.id}`);
    const meta = document.createElement("small");
    meta.textContent = [
      device.room_name || null,
      `ID ${device.id}`,
      device.state?.connected === false ? "offline" : "online",
    ].filter(Boolean).join(" · ");
    const state = document.createElement("span");
    state.className = "light-state";
    state.textContent = climateStateLabel(device);
    identity.append(name, meta, state);

    const controls = document.createElement("div");
    controls.className = "climate-controls";

    const modeSelect = document.createElement("select");
    modeSelect.className = "climate-select";
    for (const mode of device.capabilities?.hvac_modes || []) {
      const option = document.createElement("option");
      option.value = String(mode).toLowerCase();
      option.textContent = String(mode);
      option.selected = String(device.state?.hvac_mode || "").toLowerCase() === option.value;
      modeSelect.append(option);
    }
    modeSelect.addEventListener("change", () =>
      runClimateAction(device, "set_hvac_mode", modeSelect.value, modeSelect)
    );
    controls.append(modeSelect);

    const fanModes = device.capabilities?.fan_modes || [];
    if (fanModes.length) {
      const fanSelect = document.createElement("select");
      fanSelect.className = "climate-select";
      for (const mode of fanModes) {
        const option = document.createElement("option");
        option.value = String(mode).toLowerCase();
        option.textContent = String(mode);
        option.selected = String(device.state?.fan_mode || "").toLowerCase() === option.value;
        fanSelect.append(option);
      }
      fanSelect.addEventListener("change", () =>
        runClimateAction(device, "set_fan_mode", fanSelect.value, fanSelect)
      );
      controls.append(fanSelect);
    }

    const temp = document.createElement("input");
    temp.className = "climate-temp";
    temp.type = "number";
    temp.min = String(device.capabilities?.target_temperature_min_c ?? 16);
    temp.max = String(device.capabilities?.target_temperature_max_c ?? 32);
    temp.step = "1";
    temp.value = Number.isFinite(Number(device.state?.target_temperature_c))
      ? String(Math.round(Number(device.state.target_temperature_c)))
      : "22";

    const setButton = document.createElement("button");
    setButton.type = "button";
    setButton.className = "button light-button";
    setButton.textContent = "Set °C";
    setButton.addEventListener("click", () =>
      runClimateAction(device, "set_temperature", temp.value, setButton)
    );

    controls.append(temp, setButton);
    row.append(identity, controls);
    climateList.append(row);
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
    const { host } = saveSetup();
    const pairingCode = pairingCodeInput.value.trim();
    let token = localStorage.getItem(TOKEN_STORAGE_KEY);

    if (pairingCode) {
      setConnectionState(
        "Pairing this browser…",
        "Verifying the short code directly with C4Bridge on your LAN.",
        "Pairing…"
      );
      token = await pairBrowser(host, pairingCode);
    }

    if (!token) {
      const error = new Error("Enter the Pairing Code shown in the C4Bridge Composer properties.");
      error.code = "PAIRING_REQUIRED";
      throw error;
    }

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
    const isPairingError =
      error.code === "PAIRING_REQUIRED" ||
      error.code === "PAIRING_CODE_INVALID" ||
      error.code === "PAIRING_CODE_EXPIRED" ||
      error.code === "PAIRING_RATE_LIMITED";

    let message;
    if (isUnauthorized) {
      localStorage.removeItem(TOKEN_STORAGE_KEY);
      refreshSavedDirector();
      message = "Saved owner credential was rejected. Enter the current Pairing Code from Composer.";
    } else if (isPairingError) {
      message = error.message;
    } else if (isAbort) {
      message = "Connection timed out. Check the Director IP, API status, and LAN.";
    } else {
      message =
        "Could not reach C4Bridge. Allow Local Network Access and verify the Director IP and API port 41999.";
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
