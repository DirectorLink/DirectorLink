// Responses and secret checks shared by the Worker (index.js) and the Durable Object
// (home-relay.js).

const TITLES = {
  400: "Bad Request",
  401: "Unauthorized",
  404: "Not Found",
  405: "Method Not Allowed",
  500: "Internal Server Error",
  502: "Bad Gateway",
  503: "Service Unavailable",
  504: "Gateway Timeout",
};

export function json(value, status = 200, headers = {}) {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}

// RFC 9457 Problem Details with a stable machine-readable `code`, like the driver's own API
// (driver/src/api/problem.lua).
export function problem(status, code, detail, headers = {}) {
  const body = { type: "about:blank", title: TITLES[status] ?? "Error", status, detail, code };
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/problem+json", "cache-control": "no-store", ...headers },
  });
}

export function methodNotAllowed() {
  return problem(405, "METHOD_NOT_ALLOWED", "Only GET is allowed here", { Allow: "GET" });
}

// The token of `Authorization: Bearer <token>`, or null.
export function bearerToken(request) {
  const match = /^Bearer +(\S+)$/i.exec((request.headers.get("Authorization") ?? "").trim());
  return match ? match[1] : null;
}

const encoder = new TextEncoder();

function sha256(text) {
  return crypto.subtle.digest("SHA-256", encoder.encode(text));
}

export async function sha256Hex(text) {
  const bytes = new Uint8Array(await sha256(text));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

// Compares two secrets in constant time. Both are hashed first, so the comparison always covers
// 32 bytes and reveals neither the content nor the length of either.
export async function sameSecret(a, b) {
  const [x, y] = await Promise.all([sha256(a), sha256(b)]);
  return crypto.subtle.timingSafeEqual(x, y);
}
