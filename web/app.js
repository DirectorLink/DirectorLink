import {
  ApiError,
  apiCall,
  apiImage,
  clearApiKey,
  normalizeHost,
  saveApiKey,
  saveHost,
  savedApiKey,
  savedHost,
} from "./api-client.js";

const directorForm = document.querySelector("#director-form");
const directorInput = document.querySelector("#director-host");
const pairingCodeInput = document.querySelector("#pairing-code");
const connectButton = document.querySelector("#connect-button");
const cancelAccessButton = document.querySelector("#cancel-access-button");
const directorMessage = document.querySelector("#director-message");
const savedDirector = document.querySelector("#saved-director");
const secureContext = document.querySelector("#secure-context");
const serviceWorkerStatus = document.querySelector("#service-worker-status");
const offlineStatus = document.querySelector("#offline-status");
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
const cameraGrid = document.querySelector("#camera-grid");
const cameraMessage = document.querySelector("#camera-message");
const cameraDialog = document.querySelector("#camera-dialog");
const cameraDialogTitle = document.querySelector("#camera-dialog-title");
const cameraDialogImage = document.querySelector("#camera-dialog-image");
const cameraDialogStatus = document.querySelector("#camera-dialog-status");
const cameraDialogClose = document.querySelector("#camera-dialog-close");
const blindList = document.querySelector("#blind-list");
const blindActionMessage = document.querySelector("#blind-action-message");
const refreshBlindsButton = document.querySelector("#refresh-blinds-button");
const thermostatList = document.querySelector("#thermostat-list");
const thermostatActionMessage = document.querySelector("#thermostat-action-message");
const refreshThermostatsButton = document.querySelector("#refresh-thermostats-button");

let installPrompt = null;
let activeSession = null;
let pendingAccess = null;

function setMessage(element, message, type = "") {
  element.textContent = message;
  element.className = "form-message";
  if (type) {
    element.classList.add(type);
  }
}

function setConnectionState(title, detail, status) {
  bridgeStatusTitle.textContent = title;
  bridgeStatusText.textContent = detail;
  apiConnectionStatus.textContent = status;
}

function refreshSavedSetup() {
  const host = savedHost();
  const apiKey = savedApiKey();
  if (host) {
    directorInput.value = host;
  }
  savedDirector.textContent = host || "Not set";
  savedPairing.textContent = apiKey ? "Paired in this browser" : "Not paired";
  connectButton.textContent = apiKey ? "Connect" : "Request access";
}

function saveSetup() {
  const host = normalizeHost(directorInput.value);
  if (!host) {
    throw new Error("Enter a private IPv4 address or .local hostname without a port.");
  }
  saveHost(host);
  refreshSavedSetup();
  return host;
}

function api(path, options = {}) {
  return apiCall(activeSession.host, path, { apiKey: activeSession.apiKey, ...options });
}

function clientName() {
  const platform = navigator.userAgentData?.platform || navigator.platform || "browser";
  return `C4Bridge web app (${platform})`.slice(0, 64);
}

async function pairBrowser(host, pairingCode) {
  const code = String(pairingCode || "").trim();
  if (!/^\d{8}$/.test(code)) {
    throw new ApiError("Enter the 8-digit Pairing Code shown in Composer.", { code: "PAIRING_REQUIRED" });
  }
  const created = await apiCall(host, "/v1/auth/pair", {
    method: "POST",
    body: { pairing_code: code, name: clientName() },
  });
  if (!created?.key) {
    throw new Error("C4Bridge paired, but no API key was returned.");
  }
  saveApiKey(created.key);
  pairingCodeInput.value = "";
  refreshSavedSetup();
  return created.key;
}

const sleep = (milliseconds) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));

function countdown(expiresAt) {
  const seconds = Math.max(0, Math.round((Date.parse(expiresAt) - Date.now()) / 1000));
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

// Asks for a key and waits until C4Bridge Access is pressed in the Control4 app.
async function requestAccess(host) {
  const request = await apiCall(host, "/v1/auth/requests", {
    method: "POST",
    body: { name: clientName() },
  });
  pendingAccess = { host, id: request.id, cancelled: false };
  cancelAccessButton.classList.remove("hidden");

  try {
    let expiresAt = request.expires_at;
    while (!pendingAccess.cancelled) {
      setConnectionState(
        "Waiting for approval…",
        `Press C4Bridge Access in your Control4 app (${countdown(expiresAt)} left).`,
        "Waiting for approval"
      );
      setMessage(directorMessage, `Press C4Bridge Access in your Control4 app — ${countdown(expiresAt)} left.`);
      await sleep(2000);
      if (pendingAccess.cancelled) {
        break;
      }
      let current;
      try {
        current = await apiCall(host, `/v1/auth/requests/${request.id}`);
      } catch (error) {
        if (error.status === 404) {
          throw new ApiError("The request expired before it was approved. Click Request access to try again.", {
            code: "REQUEST_EXPIRED",
          });
        }
        throw error;
      }
      if (current.status === "approved" && current.api_key?.key) {
        saveApiKey(current.api_key.key);
        refreshSavedSetup();
        return current.api_key.key;
      }
      expiresAt = current.expires_at;
    }
    throw new ApiError("Access request cancelled.", { code: "REQUEST_CANCELLED" });
  } finally {
    pendingAccess = null;
    cancelAccessButton.classList.add("hidden");
  }
}

async function cancelAccessRequest() {
  if (!pendingAccess) {
    return;
  }
  pendingAccess.cancelled = true;
  try {
    await apiCall(pendingAccess.host, `/v1/auth/requests/${pendingAccess.id}`, { method: "DELETE" });
  } catch {
    // Already expired or approved; nothing to undo.
  }
}

function text(value, fallback = "—") {
  if (value === null || value === undefined || value === "") {
    return fallback;
  }
  return String(value);
}

function capitalize(value) {
  const textValue = String(value || "");
  return textValue.charAt(0).toUpperCase() + textValue.slice(1);
}

function emptyState(container, message) {
  const empty = document.createElement("p");
  empty.className = "empty-state";
  empty.textContent = message;
  container.replaceChildren(empty);
}

function renderSummary(system) {
  const items = [
    ["Bridge", system.bridge?.version],
    ["Controller OS", system.controller?.os_version],
    ["Rooms", system.inventory?.rooms],
    ["Devices", system.inventory?.devices],
    ["Lights", system.inventory?.lights],
    ["Thermostats", system.inventory?.thermostats],
    ["Blinds", system.inventory?.blinds],
    ["Cameras", system.inventory?.cameras],
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
  if (!rooms.length) {
    emptyState(roomList, "No rooms returned.");
    return;
  }
  roomList.replaceChildren(
    ...rooms.map((room) => {
      const item = document.createElement("div");
      item.className = "entity-row";
      const main = document.createElement("div");
      const name = document.createElement("strong");
      const meta = document.createElement("small");
      name.textContent = text(room.name, `Room ${room.id}`);
      meta.textContent = [room.floor?.name, `${room.device_count} devices`, `ID ${room.id}`]
        .filter(Boolean)
        .join(" · ");
      main.append(name, meta);
      item.append(main);
      return item;
    })
  );
}

function renderDevices(devices) {
  if (!devices.length) {
    emptyState(deviceList, "No devices returned.");
    return;
  }
  deviceList.replaceChildren(
    ...devices.map((device) => {
      const item = document.createElement("div");
      item.className = "entity-row device-row";
      const main = document.createElement("div");
      const name = document.createElement("strong");
      const meta = document.createElement("small");
      name.textContent = text(device.name, `Device ${device.id}`);
      meta.textContent = [device.room?.name, `ID ${device.id}`].filter(Boolean).join(" · ");
      const badge = document.createElement("span");
      badge.className = `kind-badge ${device.supported ? "supported" : device.type !== "other" ? "recognized" : ""}`;
      badge.textContent = device.supported ? "supported" : device.type;
      main.append(name, meta);
      item.append(main, badge);
      return item;
    })
  );
}

function lightStateLabel(light) {
  const power = light.on ? "On" : "Off";
  if (light.dimmable && !light.brightness_reported) {
    return `${power} · level not reported`;
  }
  if (light.dimmable && Number.isFinite(light.brightness)) {
    return `${power} · ${light.brightness}%`;
  }
  return power;
}

function lightChangeConfirmed(light, change) {
  if ("brightness" in change) {
    return Number.isFinite(light.brightness) && Math.abs(light.brightness - change.brightness) <= 3;
  }
  return light.on === change.on;
}

async function waitForLightConfirmation(lightId, change) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    await new Promise((resolve) => window.setTimeout(resolve, 500));
    const light = await api(`/v1/lights/${lightId}`);
    if (lightChangeConfirmed(light, change)) {
      return light;
    }
  }
  return null;
}

async function refreshLights(showMessage = false) {
  const response = await api("/v1/lights");
  const lights = response?.items || [];
  renderLights(lights);
  if (showMessage) {
    setMessage(lightActionMessage, `Refreshed ${lights.length} lights.`, "success");
  }
  return lights;
}

async function changeLight(light, change, control) {
  if (!activeSession) {
    setMessage(lightActionMessage, "Connect to the controller first.", "error");
    return;
  }
  if (control) {
    control.disabled = true;
  }
  const description = "brightness" in change ? `to ${change.brightness}%` : change.on ? "on" : "off";
  setMessage(lightActionMessage, `Turning ${light.name} ${description}…`);

  try {
    await api(`/v1/lights/${light.id}`, { method: "PATCH", body: change });
    if ("brightness" in change && !light.brightness_reported) {
      setMessage(lightActionMessage, `${light.name}: brightness sent (${change.brightness}%). This light does not report its level.`, "success");
    } else {
      setMessage(lightActionMessage, `Command sent to ${light.name}; waiting for the controller…`);
      const confirmed = await waitForLightConfirmation(light.id, change);
      if (confirmed) {
        setMessage(lightActionMessage, `${light.name}: ${lightStateLabel(confirmed)} confirmed.`, "success");
      } else {
        setMessage(lightActionMessage, `${light.name}: command sent, but the controller did not confirm it within 5 seconds.`, "error");
      }
    }
    await refreshLights(false);
  } catch (error) {
    setMessage(lightActionMessage, `${light.name}: ${error.message || "command failed"}`, "error");
  } finally {
    if (control) {
      control.disabled = false;
    }
  }
}

function renderLights(lights) {
  if (!lights.length) {
    emptyState(lightList, "No controllable lights were found.");
    return;
  }
  lightList.replaceChildren(
    ...lights.map((light) => {
      const item = document.createElement("div");
      item.className = "light-row";

      const identity = document.createElement("div");
      identity.className = "light-identity";
      const name = document.createElement("strong");
      const meta = document.createElement("small");
      const state = document.createElement("span");
      name.textContent = text(light.name, `Light ${light.id}`);
      meta.textContent = [light.room?.name, `ID ${light.id}`].filter(Boolean).join(" · ");
      state.className = `light-state ${light.on ? "is-on" : ""}`;
      state.textContent = lightStateLabel(light);
      identity.append(name, meta, state);

      const controls = document.createElement("div");
      controls.className = "light-controls";

      const offButton = document.createElement("button");
      offButton.type = "button";
      offButton.className = "button light-button";
      offButton.textContent = "Off";
      offButton.addEventListener("click", () => changeLight(light, { on: false }, offButton));

      const onButton = document.createElement("button");
      onButton.type = "button";
      onButton.className = "button light-button light-button-on";
      onButton.textContent = "On";
      onButton.addEventListener("click", () => changeLight(light, { on: true }, onButton));

      controls.append(offButton, onButton);

      if (light.dimmable) {
        const brightnessWrap = document.createElement("label");
        brightnessWrap.className = "brightness-control";
        const slider = document.createElement("input");
        slider.type = "range";
        slider.min = "0";
        slider.max = "100";
        slider.step = "1";
        slider.value = String(Number.isFinite(light.brightness) ? light.brightness : light.on ? 100 : 0);
        slider.setAttribute("aria-label", `${light.name} brightness`);
        const output = document.createElement("output");
        output.textContent = `${slider.value}%`;
        slider.addEventListener("input", () => {
          output.textContent = `${slider.value}%`;
        });
        slider.addEventListener("change", () =>
          changeLight(light, { brightness: Number(slider.value) }, slider)
        );
        brightnessWrap.append(slider, output);
        controls.append(brightnessWrap);
      }

      item.append(identity, controls);
      return item;
    })
  );
}

// Camera pictures: grid tiles refresh one after another (visible tiles only, about every 3 s);
// the opened camera refreshes about once a second. Nothing refreshes while the page is hidden.
const GRID_REFRESH_MS = 3000;
const LARGE_REFRESH_MS = 1000;
let cameraTiles = [];
let cameraTimer = null;
let openCamera = null;
let openCameraTimer = null;

async function loadSnapshot(camera, width, image) {
  const blob = await apiImage(activeSession.host, `${camera.snapshot_href}?width=${width}`, {
    apiKey: activeSession.apiKey,
  });
  const previous = image.dataset.objectUrl;
  const url = URL.createObjectURL(blob);
  image.src = url;
  image.dataset.objectUrl = url;
  if (previous) {
    URL.revokeObjectURL(previous);
  }
}

async function refreshCameraGrid() {
  cameraTimer = null;
  if (!activeSession || document.hidden || openCamera) {
    scheduleCameraGrid();
    return;
  }
  const visible = cameraTiles.filter((tile) => tile.visible);
  for (const tile of visible) {
    try {
      await loadSnapshot(tile.camera, 320, tile.image);
      tile.status.textContent = tile.camera.room?.name || "";
    } catch (error) {
      tile.status.textContent = error.status === 503 ? "Busy, retrying…" : "No picture";
    }
    if (!activeSession || openCamera) {
      break;
    }
  }
  scheduleCameraGrid();
}

function scheduleCameraGrid() {
  if (cameraTiles.length && !cameraTimer) {
    cameraTimer = window.setTimeout(refreshCameraGrid, GRID_REFRESH_MS);
  }
}

async function refreshOpenCamera() {
  openCameraTimer = null;
  if (!openCamera || !activeSession) {
    return;
  }
  if (!document.hidden) {
    try {
      await loadSnapshot(openCamera, 1280, cameraDialogImage);
      cameraDialogStatus.textContent = `Updated ${new Date().toLocaleTimeString()}`;
    } catch (error) {
      cameraDialogStatus.textContent = error.message || "The camera did not return a picture.";
    }
  }
  if (openCamera) {
    openCameraTimer = window.setTimeout(refreshOpenCamera, LARGE_REFRESH_MS);
  }
}

function showCamera(camera) {
  openCamera = camera;
  cameraDialogTitle.textContent = camera.name;
  cameraDialogStatus.textContent = "Loading…";
  cameraDialog.showModal();
  refreshOpenCamera();
}

function closeCamera() {
  openCamera = null;
  window.clearTimeout(openCameraTimer);
  openCameraTimer = null;
  if (cameraDialog.open) {
    cameraDialog.close();
  }
}

const cameraObserver =
  "IntersectionObserver" in window
    ? new IntersectionObserver((entries) => {
        for (const entry of entries) {
          const tile = cameraTiles.find((item) => item.element === entry.target);
          if (tile) {
            tile.visible = entry.isIntersecting;
          }
        }
      })
    : null;

function renderCameras(cameras) {
  cameraObserver?.disconnect();
  window.clearTimeout(cameraTimer);
  cameraTimer = null;
  cameraTiles = [];
  if (!cameras.length) {
    emptyState(cameraGrid, "No cameras were found.");
    return;
  }
  cameraGrid.replaceChildren(
    ...cameras.map((camera) => {
      const element = document.createElement("button");
      element.type = "button";
      element.className = "camera-tile";
      const image = document.createElement("img");
      image.alt = `${camera.name} camera`;
      const label = document.createElement("span");
      const name = document.createElement("strong");
      const status = document.createElement("small");
      name.textContent = text(camera.name, `Camera ${camera.id}`);
      status.textContent = "Loading…";
      label.append(name, status);
      element.append(image, label);
      element.addEventListener("click", () => showCamera(camera));
      const tile = { camera, element, image, status, visible: !cameraObserver };
      cameraTiles.push(tile);
      cameraObserver?.observe(element);
      return element;
    })
  );
  window.setTimeout(refreshCameraGrid, 300);
}

function blindStateLabel(blind) {
  if (!Number.isFinite(blind.position)) {
    return "Position unknown";
  }
  if (blind.position === 0) {
    return "Closed";
  }
  return blind.position === 100 ? "Open" : `${blind.position}% open`;
}

async function refreshBlinds(showMessage = false) {
  const response = await api("/v1/blinds");
  const blinds = response?.items || [];
  renderBlinds(blinds);
  if (showMessage) {
    setMessage(blindActionMessage, `Refreshed ${blinds.length} blinds.`, "success");
  }
  return blinds;
}

// action is a position (0 closed … 100 open) or "stop".
async function controlBlind(blind, action, control) {
  if (!activeSession) {
    setMessage(blindActionMessage, "Connect to the controller first.", "error");
    return;
  }
  if (control) {
    control.disabled = true;
  }
  try {
    if (action === "stop") {
      await api(`/v1/blinds/${blind.id}/stop`, { method: "POST" });
      setMessage(blindActionMessage, `${blind.name}: stop sent.`, "success");
    } else {
      await api(`/v1/blinds/${blind.id}`, { method: "PATCH", body: { position: action } });
      const label = action === 0 ? "closing" : action === 100 ? "opening" : `moving to ${action}%`;
      setMessage(blindActionMessage, `${blind.name}: ${label}.`, "success");
    }
    await refreshBlinds(false);
  } catch (error) {
    setMessage(blindActionMessage, `${blind.name}: ${error.message || "command failed"}`, "error");
  } finally {
    if (control) {
      control.disabled = false;
    }
  }
}

function renderBlinds(blinds) {
  if (!blinds.length) {
    emptyState(blindList, "No controllable blinds were found.");
    return;
  }
  blindList.replaceChildren(
    ...blinds.map((blind) => {
      const item = document.createElement("div");
      item.className = "light-row";

      const identity = document.createElement("div");
      identity.className = "light-identity";
      const name = document.createElement("strong");
      const meta = document.createElement("small");
      const state = document.createElement("span");
      name.textContent = text(blind.name, `Blind ${blind.id}`);
      meta.textContent = [blind.room?.name, `ID ${blind.id}`].filter(Boolean).join(" · ");
      state.className = `light-state ${blind.position > 0 ? "is-on" : ""}`;
      state.textContent = blindStateLabel(blind);
      identity.append(name, meta, state);

      const controls = document.createElement("div");
      controls.className = "light-controls";
      const button = (label, action, extraClass = "") => {
        const element = document.createElement("button");
        element.type = "button";
        element.className = `button light-button ${extraClass}`.trim();
        element.textContent = label;
        element.addEventListener("click", () => controlBlind(blind, action, element));
        return element;
      };
      controls.append(button("Close", 0), button("Stop", "stop"), button("Open", 100, "light-button-on"));

      const positionWrap = document.createElement("label");
      positionWrap.className = "brightness-control";
      const slider = document.createElement("input");
      slider.type = "range";
      slider.min = "0";
      slider.max = "100";
      slider.step = "1";
      slider.value = String(Number.isFinite(blind.position) ? blind.position : 0);
      slider.setAttribute("aria-label", `${blind.name} position`);
      const output = document.createElement("output");
      output.textContent = `${slider.value}%`;
      slider.addEventListener("input", () => {
        output.textContent = `${slider.value}%`;
      });
      slider.addEventListener("change", () => controlBlind(blind, Number(slider.value), slider));
      positionWrap.append(slider, output);
      controls.append(positionWrap);

      item.append(identity, controls);
      return item;
    })
  );
}

function thermostatStateLabel(thermostat) {
  const parts = [];
  if (Number.isFinite(thermostat.current_temperature)) parts.push(`Now ${thermostat.current_temperature}°C`);
  if (Number.isFinite(thermostat.target_temperature)) parts.push(`Target ${thermostat.target_temperature}°C`);
  if (thermostat.mode) parts.push(capitalize(thermostat.mode));
  if (thermostat.activity && thermostat.activity !== "idle") parts.push(thermostat.activity);
  if (thermostat.fan_speed) parts.push(`fan ${thermostat.fan_speed}`);
  return parts.join(" · ") || "State unavailable";
}

async function refreshThermostats(showMessage = false) {
  const response = await api("/v1/thermostats");
  const thermostats = response?.items || [];
  renderThermostats(thermostats);
  if (showMessage) {
    setMessage(thermostatActionMessage, `Refreshed ${thermostats.length} thermostats.`, "success");
  }
  return thermostats;
}

async function changeThermostat(thermostat, change, control) {
  if (!activeSession) {
    setMessage(thermostatActionMessage, "Connect to the controller first.", "error");
    return;
  }
  if (control) {
    control.disabled = true;
  }
  setMessage(thermostatActionMessage, `Sending to ${thermostat.name}…`);
  try {
    await api(`/v1/thermostats/${thermostat.id}`, { method: "PATCH", body: change });
    await new Promise((resolve) => window.setTimeout(resolve, 800));
    await refreshThermostats(false);
    setMessage(thermostatActionMessage, `${thermostat.name}: command sent.`, "success");
  } catch (error) {
    setMessage(thermostatActionMessage, `${thermostat.name}: ${error.message || "command failed"}`, "error");
  } finally {
    if (control) {
      control.disabled = false;
    }
  }
}

function optionSelect(values, current, label) {
  const select = document.createElement("select");
  select.className = "climate-select";
  select.setAttribute("aria-label", label);
  for (const value of values) {
    const option = document.createElement("option");
    option.value = value;
    option.textContent = capitalize(value);
    option.selected = value === current;
    select.append(option);
  }
  return select;
}

function renderThermostats(thermostats) {
  if (!thermostats.length) {
    emptyState(thermostatList, "No controllable thermostats were found.");
    return;
  }
  thermostatList.replaceChildren(
    ...thermostats.map((thermostat) => {
      const row = document.createElement("div");
      row.className = "climate-row";

      const identity = document.createElement("div");
      identity.className = "light-identity";
      const name = document.createElement("strong");
      const meta = document.createElement("small");
      const state = document.createElement("span");
      name.textContent = text(thermostat.name, `Thermostat ${thermostat.id}`);
      meta.textContent = [thermostat.room?.name, `ID ${thermostat.id}`, thermostat.online ? "online" : "offline"]
        .filter(Boolean)
        .join(" · ");
      state.className = "light-state";
      state.textContent = thermostatStateLabel(thermostat);
      identity.append(name, meta, state);

      const controls = document.createElement("div");
      controls.className = "climate-controls";

      const modeSelect = optionSelect(thermostat.modes, thermostat.mode, `${thermostat.name} mode`);
      modeSelect.addEventListener("change", () =>
        changeThermostat(thermostat, { mode: modeSelect.value }, modeSelect)
      );
      controls.append(modeSelect);

      if (thermostat.fan_speeds.length) {
        const fanSelect = optionSelect(thermostat.fan_speeds, thermostat.fan_speed, `${thermostat.name} fan speed`);
        fanSelect.addEventListener("change", () =>
          changeThermostat(thermostat, { fan_speed: fanSelect.value }, fanSelect)
        );
        controls.append(fanSelect);
      }

      const temperature = document.createElement("input");
      temperature.className = "climate-temp";
      temperature.type = "number";
      temperature.min = String(thermostat.target_temperature_min);
      temperature.max = String(thermostat.target_temperature_max);
      temperature.step = "1";
      temperature.value = String(Number.isFinite(thermostat.target_temperature) ? thermostat.target_temperature : 22);
      temperature.setAttribute("aria-label", `${thermostat.name} target temperature`);

      const setButton = document.createElement("button");
      setButton.type = "button";
      setButton.className = "button light-button";
      setButton.textContent = "Set °C";
      setButton.addEventListener("click", () =>
        changeThermostat(thermostat, { target_temperature: Number(temperature.value) }, setButton)
      );

      controls.append(temperature, setButton);
      row.append(identity, controls);
      return row;
    })
  );
}

function connectionErrorMessage(error) {
  if (error.status === 401) {
    clearApiKey();
    refreshSavedSetup();
    return "The saved API key is no longer valid (it was revoked, or C4Bridge was re-added). Press Request access to get a new one.";
  }
  if (error instanceof ApiError && /^(PAIRING|REQUEST)/.test(error.code || "")) {
    if (error.code === "REQUEST_PENDING") {
      return "Another device is already waiting for approval. Try again in a minute.";
    }
    return error.message;
  }
  if (error.name === "AbortError") {
    return "Connection timed out. Check the controller IP, the API status in Composer and the LAN.";
  }
  return "Could not reach C4Bridge. Allow Local Network Access and check the controller IP and API port 41999.";
}

async function connectAndLoad() {
  projectResult.classList.add("hidden");
  connectButton.disabled = true;
  setMessage(directorMessage, "");
  setMessage(lightActionMessage, "");
  setMessage(thermostatActionMessage, "");
  setMessage(blindActionMessage, "");
  setConnectionState("Connecting…", "Chrome may ask for Local Network Access permission.", "Connecting…");

  try {
    const host = saveSetup();
    const pairingCode = pairingCodeInput.value.trim();
    let apiKey = savedApiKey();

    if (pairingCode) {
      setConnectionState("Pairing this browser…", "Checking the code directly with C4Bridge on your LAN.", "Pairing…");
      apiKey = await pairBrowser(host, pairingCode);
    } else if (!apiKey) {
      apiKey = await requestAccess(host);
    }

    activeSession = { host, apiKey };
    const system = await api("/v1/system");
    const [rooms, devices, lights, thermostats, blinds, cameras] = await Promise.all([
      api("/v1/rooms"),
      api("/v1/devices"),
      api("/v1/lights"),
      api("/v1/thermostats"),
      api("/v1/blinds"),
      api("/v1/cameras"),
    ]);

    connectedVersion.textContent = `v${text(system.bridge?.version, "?")}`;
    renderSummary(system);
    renderLights(lights.items);
    renderThermostats(thermostats.items);
    renderBlinds(blinds.items);
    renderCameras(cameras.items);
    renderRooms(rooms.items);
    renderDevices(devices.items);
    projectResult.classList.remove("hidden");

    setConnectionState(
      "Connected to C4Bridge",
      `${rooms.items.length} rooms, ${devices.items.length} devices, ${lights.items.length} lights, ${thermostats.items.length} thermostats, ${blinds.items.length} blinds and ${cameras.items.length} cameras.`,
      "Connected"
    );
    setMessage(directorMessage, "Connected.", "success");
  } catch (error) {
    activeSession = null;
    const message = connectionErrorMessage(error);
    setConnectionState("Connection failed", message, "Failed");
    setMessage(directorMessage, message, "error");
    console.error("C4Bridge connection failed", error);
  } finally {
    connectButton.disabled = false;
  }
}

directorForm.addEventListener("submit", (event) => {
  event.preventDefault();
  try {
    saveSetup();
    setMessage(directorMessage, "Saved in this browser.", "success");
  } catch (error) {
    setMessage(directorMessage, error.message, "error");
  }
});

connectButton.addEventListener("click", connectAndLoad);
cancelAccessButton.addEventListener("click", cancelAccessRequest);

refreshLightsButton.addEventListener("click", async () => {
  refreshLightsButton.disabled = true;
  setMessage(lightActionMessage, "Refreshing lights…");
  try {
    await refreshLights(true);
  } catch (error) {
    setMessage(lightActionMessage, error.message || "Unable to refresh lights.", "error");
  } finally {
    refreshLightsButton.disabled = false;
  }
});

cameraDialogClose.addEventListener("click", closeCamera);
cameraDialog.addEventListener("close", closeCamera);

refreshBlindsButton.addEventListener("click", async () => {
  refreshBlindsButton.disabled = true;
  setMessage(blindActionMessage, "Refreshing blinds…");
  try {
    await refreshBlinds(true);
  } catch (error) {
    setMessage(blindActionMessage, error.message || "Unable to refresh blinds.", "error");
  } finally {
    refreshBlindsButton.disabled = false;
  }
});

refreshThermostatsButton.addEventListener("click", async () => {
  refreshThermostatsButton.disabled = true;
  setMessage(thermostatActionMessage, "Refreshing thermostats…");
  try {
    await refreshThermostats(true);
  } catch (error) {
    setMessage(thermostatActionMessage, error.message || "Unable to refresh thermostats.", "error");
  } finally {
    refreshThermostatsButton.disabled = false;
  }
});

async function refreshOfflineStatus() {
  if (!("caches" in window)) {
    offlineStatus.textContent = "Not supported";
    return;
  }
  const saved = await caches.match("/");
  if (!navigator.onLine) {
    offlineStatus.textContent = saved ? "In use (offline)" : "Not saved yet";
  } else {
    offlineStatus.textContent = saved ? "Ready — opens without internet" : "Saving…";
  }
}

secureContext.textContent = window.isSecureContext ? "Ready (HTTPS)" : "HTTPS required";

if ("serviceWorker" in navigator) {
  navigator.serviceWorker
    .register("/sw.js", { scope: "/" })
    .then(() => {
      serviceWorkerStatus.textContent = "Registered";
      return navigator.serviceWorker.ready;
    })
    .then(refreshOfflineStatus)
    .catch(() => {
      serviceWorkerStatus.textContent = "Registration failed";
      offlineStatus.textContent = "Not available";
    });
  window.addEventListener("online", refreshOfflineStatus);
  window.addEventListener("offline", refreshOfflineStatus);
} else {
  serviceWorkerStatus.textContent = "Not supported";
  offlineStatus.textContent = "Not supported";
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

refreshSavedSetup();

// The host and API key are kept in this browser, so a reload reconnects without pairing again.
if (savedHost() && savedApiKey()) {
  connectAndLoad();
}
