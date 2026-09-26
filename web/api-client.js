// Shared client for the C4Bridge LAN API (see api/openapi.yaml).

export const API_PORT = 41999;

const HOST_STORAGE_KEY = "c4bridge.directorHost";
const API_KEY_STORAGE_KEY = "c4bridge.apiKey";

export class ApiError extends Error {
  constructor(message, { status, code, problem } = {}) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.problem = problem;
  }
}

// Accepts an IP address or local hostname, with or without http:// and a trailing slash.
export function normalizeHost(value) {
  const host = String(value || "")
    .trim()
    .replace(/^https?:\/\//i, "")
    .replace(/\/$/, "");
  if (!host || /[\s/]/.test(host) || host.includes(":")) {
    return null;
  }
  return host;
}

export function savedHost() {
  return localStorage.getItem(HOST_STORAGE_KEY) || "";
}

export function saveHost(host) {
  localStorage.setItem(HOST_STORAGE_KEY, host);
}

export function savedApiKey() {
  return localStorage.getItem(API_KEY_STORAGE_KEY) || "";
}

export function saveApiKey(key) {
  localStorage.setItem(API_KEY_STORAGE_KEY, key);
}

export function clearApiKey() {
  localStorage.removeItem(API_KEY_STORAGE_KEY);
}

export function apiUrl(host, path) {
  return `http://${host}:${API_PORT}${path}`;
}

// Sends a request and returns { status, ok, data, text, durationMs } without throwing on HTTP errors.
export async function apiRequest(host, path, { method = "GET", apiKey, body, timeoutMs = 8000 } = {}) {
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeoutMs);
  const headers = {};
  let payload;

  if (apiKey) {
    headers.Authorization = `Bearer ${apiKey}`;
  }
  if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = typeof body === "string" ? body : JSON.stringify(body);
  }

  const started = performance.now();
  try {
    const response = await fetch(apiUrl(host, path), {
      method,
      headers,
      body: payload,
      cache: "no-store",
      signal: controller.signal,
      targetAddressSpace: "local",
    });
    const text = await response.text();
    let data = null;
    if (text) {
      try {
        data = JSON.parse(text);
      } catch {
        data = text;
      }
    }
    return {
      status: response.status,
      ok: response.ok,
      data,
      text,
      durationMs: Math.round(performance.now() - started),
    };
  } finally {
    window.clearTimeout(timer);
  }
}

// Like apiRequest, but returns only the data and throws ApiError for non-2xx responses.
export async function apiCall(host, path, options) {
  const result = await apiRequest(host, path, options);
  if (!result.ok) {
    const problem = result.data && typeof result.data === "object" ? result.data : null;
    throw new ApiError(problem?.detail || problem?.title || `C4Bridge returned HTTP ${result.status}`, {
      status: result.status,
      code: problem?.code,
      problem,
    });
  }
  return result.data;
}
