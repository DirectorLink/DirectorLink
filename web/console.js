import { apiRequest, normalizeHost, saveHost, savedApiKey, savedHost } from "./api-client.js";

const connectionForm = document.querySelector("#connection-form");
const hostInput = document.querySelector("#console-host");
const keyInput = document.querySelector("#console-key");
const connectionMessage = document.querySelector("#connection-message");
const operationSelect = document.querySelector("#operation-select");
const operationDescription = document.querySelector("#operation-description");
const parameterFields = document.querySelector("#parameter-fields");
const bodyLabel = document.querySelector("#body-label");
const bodyInput = document.querySelector("#request-body");
const sendButton = document.querySelector("#send-button");
const responseStatus = document.querySelector("#response-status");
const responseBody = document.querySelector("#response-body");
const logLevel = document.querySelector("#log-level");
const logCategory = document.querySelector("#log-category");
const logFollow = document.querySelector("#log-follow");
const logClear = document.querySelector("#log-clear");
const logMessage = document.querySelector("#log-message");
const logList = document.querySelector("#log-list");

const METHODS = ["get", "post", "put", "patch", "delete"];
const MAX_LOG_LINES = 1000;

let spec = null;
let operations = [];
let current = null;
let host = "";
let followTimer = null;
let lastSeq = 0;

function setMessage(element, message, type = "") {
  element.textContent = message;
  element.className = "form-message";
  if (type) {
    element.classList.add(type);
  }
}

function resolveRef(node) {
  if (!node?.$ref) {
    return node;
  }
  return node.$ref
    .replace(/^#\//, "")
    .split("/")
    .reduce((value, part) => value?.[part], spec);
}

function collectOperations(document) {
  const list = [];
  for (const [path, item] of Object.entries(document.paths || {})) {
    const shared = (item.parameters || []).map(resolveRef);
    for (const method of METHODS) {
      const operation = item[method];
      if (!operation) {
        continue;
      }
      const json = operation.requestBody?.content?.["application/json"];
      list.push({
        id: operation.operationId,
        method: method.toUpperCase(),
        path,
        summary: operation.summary || "",
        description: operation.description || "",
        parameters: [...shared, ...(operation.parameters || []).map(resolveRef)],
        hasBody: Boolean(operation.requestBody),
        example: json?.example,
        isPublic: Array.isArray(operation.security) && operation.security.length === 0,
        tag: operation.tags?.[0] || "Other",
      });
    }
  }
  return list;
}

function renderOperations() {
  const groups = new Map();
  for (const operation of operations) {
    if (!groups.has(operation.tag)) {
      groups.set(operation.tag, []);
    }
    groups.get(operation.tag).push(operation);
  }
  operationSelect.replaceChildren(
    ...[...groups].map(([tag, items]) => {
      const group = document.createElement("optgroup");
      group.label = tag;
      for (const operation of items) {
        const option = document.createElement("option");
        option.value = operation.id;
        option.textContent = `${operation.method} ${operation.path} — ${operation.summary}`;
        group.append(option);
      }
      return group;
    })
  );
  operationSelect.disabled = false;
  sendButton.disabled = false;
  selectOperation(operationSelect.value);
}

function selectOperation(id) {
  current = operations.find((operation) => operation.id === id) || null;
  parameterFields.replaceChildren();
  if (!current) {
    return;
  }

  operationDescription.textContent = [
    current.description || current.summary,
    current.isPublic ? "No API key needed." : "",
  ]
    .filter(Boolean)
    .join(" ");

  for (const parameter of current.parameters) {
    const fieldId = `param-${parameter.in}-${parameter.name}`;
    const label = document.createElement("label");
    label.htmlFor = fieldId;
    label.textContent = `${parameter.name}${parameter.required ? " (required)" : ""} — ${parameter.in}`;
    const input = document.createElement("input");
    input.id = fieldId;
    input.type = "text";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.dataset.name = parameter.name;
    input.dataset.location = parameter.in;
    input.placeholder = parameter.description || parameter.schema?.type || "";
    parameterFields.append(label, input);
  }

  bodyLabel.classList.toggle("hidden", !current.hasBody);
  bodyInput.classList.toggle("hidden", !current.hasBody);
  bodyInput.value = current.hasBody ? JSON.stringify(current.example ?? {}, null, 2) : "";
}

function requestPath() {
  let path = current.path;
  const query = new URLSearchParams();
  for (const input of parameterFields.querySelectorAll("input")) {
    const value = input.value.trim();
    if (input.dataset.location === "path") {
      if (!value) {
        throw new Error(`${input.dataset.name} is required.`);
      }
      path = path.replace(`{${input.dataset.name}}`, encodeURIComponent(value));
    } else if (value) {
      query.set(input.dataset.name, value);
    }
  }
  const search = query.toString();
  return search ? `${path}?${search}` : path;
}

function showResponse(result) {
  responseStatus.textContent = `${result.status} · ${result.durationMs} ms`;
  responseStatus.className = `response-status ${result.ok ? "success" : "error"}`;
  responseBody.textContent =
    result.data && typeof result.data === "object" ? JSON.stringify(result.data, null, 2) : result.text || "(empty body)";
}

async function sendRequest() {
  if (!current) {
    return;
  }
  let path;
  let body;
  try {
    path = requestPath();
    if (current.hasBody && bodyInput.value.trim()) {
      JSON.parse(bodyInput.value);
      body = bodyInput.value;
    }
  } catch (error) {
    responseStatus.textContent = error instanceof SyntaxError ? `Body is not valid JSON: ${error.message}` : error.message;
    responseStatus.className = "response-status error";
    return;
  }

  sendButton.disabled = true;
  responseStatus.textContent = `${current.method} ${path}…`;
  responseStatus.className = "response-status";
  try {
    const result = await apiRequest(host, path, {
      method: current.method,
      apiKey: current.isPublic ? undefined : keyInput.value.trim(),
      body,
    });
    showResponse(result);
  } catch (error) {
    responseStatus.textContent =
      error.name === "AbortError" ? "Timed out waiting for the controller." : "Could not reach the controller.";
    responseStatus.className = "response-status error";
    responseBody.textContent = "";
  } finally {
    sendButton.disabled = false;
  }
}

async function loadSpec(event) {
  event.preventDefault();
  const normalized = normalizeHost(hostInput.value);
  if (!normalized) {
    setMessage(connectionMessage, "Enter a private IPv4 address or .local hostname without a port.", "error");
    return;
  }
  host = normalized;
  saveHost(host);
  setMessage(connectionMessage, "Loading the API description…");
  try {
    const result = await apiRequest(host, "/v1/openapi.json");
    if (!result.ok || typeof result.data !== "object") {
      throw new Error(`HTTP ${result.status}`);
    }
    spec = result.data;
    operations = collectOperations(spec);
    renderOperations();
    logFollow.disabled = false;
    setMessage(
      connectionMessage,
      `${spec.info?.title || "API"} ${spec.info?.version || ""}: ${operations.length} endpoints.`,
      "success"
    );
  } catch {
    setMessage(
      connectionMessage,
      "Could not load the API. Allow Local Network Access and check the controller IP and API port 41999.",
      "error"
    );
  }
}

function appendLogEntry(entry) {
  const line = document.createElement("div");
  line.className = `log-line log-${entry.level}`;
  const time = document.createElement("span");
  time.className = "log-time";
  time.textContent = entry.time.replace("T", " ").replace("Z", "");
  const level = document.createElement("span");
  level.className = "log-level";
  level.textContent = entry.level;
  const category = document.createElement("span");
  category.className = "log-category";
  category.textContent = entry.category;
  const message = document.createElement("span");
  message.className = "log-text";
  message.textContent = entry.data ? `${entry.message} ${JSON.stringify(entry.data)}` : entry.message;
  line.append(time, level, category, message);
  logList.append(line);
  while (logList.childElementCount > MAX_LOG_LINES) {
    logList.firstElementChild.remove();
  }
}

async function pollLogs() {
  const params = new URLSearchParams({ after: String(lastSeq), limit: "200" });
  if (logLevel.value) {
    params.set("level", logLevel.value);
  }
  if (logCategory.value.trim()) {
    params.set("category", logCategory.value.trim());
  }
  try {
    const result = await apiRequest(host, `/v1/logs?${params}`, { apiKey: keyInput.value.trim() });
    if (!result.ok) {
      stopFollowing();
      setMessage(logMessage, result.data?.detail || `HTTP ${result.status}`, "error");
      return;
    }
    const nearBottom = logList.scrollTop + logList.clientHeight >= logList.scrollHeight - 40;
    for (const entry of result.data.items) {
      appendLogEntry(entry);
    }
    lastSeq = result.data.last_seq;
    if (nearBottom) {
      logList.scrollTop = logList.scrollHeight;
    }
    setMessage(logMessage, `Following · recording level ${result.data.level}`);
  } catch {
    setMessage(logMessage, "Could not reach the controller; still trying…", "error");
  }
}

function stopFollowing() {
  window.clearInterval(followTimer);
  followTimer = null;
  logFollow.textContent = "Follow";
}

function toggleFollowing() {
  if (followTimer) {
    stopFollowing();
    setMessage(logMessage, "Stopped.");
    return;
  }
  logFollow.textContent = "Stop";
  pollLogs();
  followTimer = window.setInterval(pollLogs, 2000);
}

// New filters reload the matching history; "Clear view" keeps following from here.
function applyLogFilters() {
  logList.replaceChildren();
  lastSeq = 0;
}

connectionForm.addEventListener("submit", loadSpec);
operationSelect.addEventListener("change", () => selectOperation(operationSelect.value));
sendButton.addEventListener("click", sendRequest);
logFollow.addEventListener("click", toggleFollowing);
logClear.addEventListener("click", () => logList.replaceChildren());
logLevel.addEventListener("change", applyLogFilters);
logCategory.addEventListener("change", applyLogFilters);

hostInput.value = savedHost();
keyInput.value = savedApiKey();
