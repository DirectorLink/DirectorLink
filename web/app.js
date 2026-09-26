import {
  ApiError,
  apiCall,
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
const thermostatList = document.querySelector("#thermostat-list");
const thermostatActionMessage = document.querySelector("#thermostat-action-message");
const refreshThermostatsButton = document.querySelector("#refresh-thermostats-button");

let installPrompt = null;
let activeSession = null;

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
  connectButton.textContent = apiKey ? "Connect" : "Pair & connect";
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
    return "The saved API key was rejected. Pair again with the current code from Composer.";
  }
  if (error instanceof ApiError && error.code?.startsWith("PAIRING")) {
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
  setConnectionState("Connecting…", "Chrome may ask for Local Network Access permission.", "Connecting…");

  try {
    const host = saveSetup();
    const pairingCode = pairingCodeInput.value.trim();
    let apiKey = savedApiKey();

    if (pairingCode) {
      setConnectionState("Pairing this browser…", "Checking the code directly with C4Bridge on your LAN.", "Pairing…");
      apiKey = await pairBrowser(host, pairingCode);
    }
    if (!apiKey) {
      throw new ApiError("Enter the Pairing Code shown in the C4Bridge properties in Composer.", {
        code: "PAIRING_REQUIRED",
      });
    }

    activeSession = { host, apiKey };
    const system = await api("/v1/system");
    const [rooms, devices, lights, thermostats] = await Promise.all([
      api("/v1/rooms"),
      api("/v1/devices"),
      api("/v1/lights"),
      api("/v1/thermostats"),
    ]);

    connectedVersion.textContent = `v${text(system.bridge?.version, "?")}`;
    renderSummary(system);
    renderLights(lights.items);
    renderThermostats(thermostats.items);
    renderRooms(rooms.items);
    renderDevices(devices.items);
    projectResult.classList.remove("hidden");

    setConnectionState(
      "Connected to C4Bridge",
      `${rooms.items.length} rooms, ${devices.items.length} devices, ${lights.items.length} lights and ${thermostats.items.length} thermostats.`,
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
