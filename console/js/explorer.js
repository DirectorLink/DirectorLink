// API tab: every operation from the running bridge's API description (GET /v1/openapi.json),
// grouped by tag, with parameters, an example body, the role it needs, and "Copy as curl".

import { append, byId, copyWithFeedback, h, prettyJson, setMessage } from "./dom.js";
import { baseUrl, can, image, send, state } from "./session.js";

const METHODS = ["get", "post", "put", "patch", "delete"];

const filterInput = byId("op-filter");
const list = byId("op-list");
const detail = byId("op-detail");
const message = byId("api-message");
const summary = byId("api-summary");

let spec = null;
let operations = [];
let selectedId = null;
const drafts = new Map(); // operation id → { params: {name: value}, body }
const results = new Map(); // operation id → last response view
let imageUrl = null;

function resolveRef(node) {
  if (!node?.$ref || !spec) return node;
  return node.$ref
    .replace(/^#\//, "")
    .split("/")
    .reduce((value, part) => value?.[part], spec);
}

function collectOperations(document) {
  const found = [];
  for (const [path, item] of Object.entries(document.paths || {})) {
    const shared = (item.parameters || []).map(resolveRef);
    for (const method of METHODS) {
      const operation = item[method];
      if (!operation) continue;
      const json = operation.requestBody?.content?.["application/json"];
      const success = Object.entries(operation.responses || {}).find(([code]) => /^2/.test(code));
      const successTypes = Object.keys(resolveRef(success?.[1])?.content || {});
      const isPublic = Array.isArray(operation.security) && operation.security.length === 0;
      found.push({
        id: operation.operationId || `${method}-${path}`,
        method: method.toUpperCase(),
        path,
        summary: operation.summary || "",
        description: operation.description || "",
        tag: operation.tags?.[0] || "Other",
        parameters: [...shared, ...(operation.parameters || []).map(resolveRef)].filter(Boolean),
        hasBody: Boolean(operation.requestBody),
        bodyRequired: Boolean(operation.requestBody?.required),
        example: json?.example ?? exampleFromSchema(resolveRef(json?.schema)),
        role: isPublic ? null : operation["x-directorlink-role"] || "viewer",
        isPublic,
        binary: successTypes.some((type) => type.startsWith("image/")),
      });
    }
  }
  return found;
}

function exampleFromSchema(schema) {
  if (!schema) return {};
  if (schema.example !== undefined) return schema.example;
  return {};
}

// `code` and **bold** in descriptions; everything else is plain text.
function richText(text) {
  const parts = String(text || "").split(/(`[^`]+`|\*\*[^*]+\*\*)/g);
  return parts.filter(Boolean).map((part) => {
    if (part.startsWith("`")) return h("code", {}, part.slice(1, -1));
    if (part.startsWith("**")) return h("strong", {}, part.slice(2, -2));
    return part;
  });
}

function roleBadge(operation) {
  if (operation.isPublic) return h("span", { class: "role-badge role-public", title: "No API key needed" }, "public");
  const allowed = can(operation.role);
  return h(
    "span",
    { class: `role-badge role-${operation.role}${allowed ? "" : " is-locked"}`, title: allowed ? `Needs ${operation.role}` : `Needs ${operation.role}; this key is ${state.role}` },
    allowed ? operation.role : `${operation.role} · locked`
  );
}

function methodBadge(method) {
  return h("span", { class: `method method-${method.toLowerCase()}` }, method);
}

function renderList() {
  const query = filterInput.value.trim().toLowerCase();
  const groups = new Map();
  for (const operation of operations) {
    const haystack = `${operation.method} ${operation.path} ${operation.summary} ${operation.tag} ${operation.role || "public"}`.toLowerCase();
    if (query && !haystack.includes(query)) continue;
    if (!groups.has(operation.tag)) groups.set(operation.tag, []);
    groups.get(operation.tag).push(operation);
  }
  if (!groups.size) {
    list.replaceChildren(h("p", { class: "help op-empty" }, operations.length ? "No operation matches." : "No API description loaded."));
    return;
  }
  list.replaceChildren(
    ...[...groups].map(([tag, items]) =>
      h(
        "div",
        { class: "op-group" },
        h("h2", { class: "op-group-title" }, tag),
        h(
          "ul",
          { class: "op-items" },
          items.map((operation) =>
            h(
              "li",
              {},
              h(
                "a",
                {
                  class: `op-link${operation.id === selectedId ? " is-selected" : ""}${!operation.isPublic && !can(operation.role) ? " is-locked" : ""}`,
                  href: `#/api/${encodeURIComponent(operation.id)}`,
                  "aria-current": operation.id === selectedId ? "true" : null,
                  title: operation.summary,
                },
                methodBadge(operation.method),
                h("span", { class: "op-path" }, operation.path),
                !operation.isPublic && !can(operation.role) ? h("span", { class: "op-lock", title: `Needs ${operation.role}` }, operation.role) : null
              )
            )
          )
        )
      )
    )
  );
}

function draftFor(operation) {
  if (!drafts.has(operation.id)) {
    drafts.set(operation.id, {
      params: {},
      body: operation.hasBody ? prettyJson(operation.example ?? {}) : "",
    });
  }
  return drafts.get(operation.id);
}

function parameterField(operation, parameter, draft) {
  const id = `param-${parameter.in}-${parameter.name}`;
  const schema = resolveRef(parameter.schema) || {};
  const options = schema.enum || (schema.type === "boolean" ? [true, false] : null);
  const hints = [parameter.in, schema.type, parameter.required ? "required" : "", schema.default !== undefined ? `default ${schema.default}` : ""]
    .filter(Boolean)
    .join(" · ");
  let input;
  if (options) {
    input = h(
      "select",
      { id },
      h("option", { value: "" }, parameter.required ? "Choose…" : "(not set)"),
      options.map((value) => h("option", { value: String(value) }, String(value)))
    );
  } else {
    input = h("input", {
      id,
      type: "text",
      autocomplete: "off",
      spellcheck: "false",
      placeholder: schema.pattern ? `pattern ${schema.pattern}` : schema.minimum !== undefined ? `≥ ${schema.minimum}` : "",
    });
  }
  input.value = draft.params[parameter.name] ?? "";
  input.dataset.name = parameter.name;
  input.dataset.location = parameter.in;
  input.addEventListener("input", () => {
    draft.params[parameter.name] = input.value;
  });
  input.addEventListener("change", () => {
    draft.params[parameter.name] = input.value;
  });
  return h(
    "div",
    { class: "param" },
    h("label", { class: "field-label", for: id }, parameter.name, h("span", { class: "param-hints" }, hints)),
    input,
    parameter.description ? h("p", { class: "help" }, richText(parameter.description)) : null
  );
}

function buildPath(operation, draft) {
  let path = operation.path;
  const query = new URLSearchParams();
  for (const parameter of operation.parameters) {
    const value = String(draft.params[parameter.name] ?? "").trim();
    if (parameter.in === "path") {
      if (!value) throw new Error(`Fill in ${parameter.name}.`);
      path = path.replace(`{${parameter.name}}`, encodeURIComponent(value));
    } else if (parameter.in === "query") {
      if (value) query.set(parameter.name, value);
      else if (parameter.required) throw new Error(`Fill in ${parameter.name}.`);
    }
  }
  const search = query.toString();
  return search ? `${path}?${search}` : path;
}

function readBody(operation, draft) {
  if (!operation.hasBody) return undefined;
  const text = draft.body.trim();
  if (!text) {
    if (operation.bodyRequired) throw new Error("This operation needs a JSON body.");
    return undefined;
  }
  try {
    JSON.parse(text);
  } catch (error) {
    throw new Error(`The body is not valid JSON: ${error.message}`);
  }
  return text;
}

const shellQuote = (value) => `'${String(value).replace(/'/g, `'\\''`)}'`;

// The key is never copied: the command reads it from $DIRECTORLINK_KEY.
export function curlCommand(operation, path, body) {
  const first = ["curl", operation.method !== "GET" ? `-X ${operation.method}` : null, shellQuote(`${baseUrl()}${path}`)];
  const parts = [first.filter(Boolean).join(" ")];
  if (!operation.isPublic) parts.push(`-H "Authorization: Bearer $DIRECTORLINK_KEY"`);
  if (body !== undefined) {
    parts.push(`-H 'Content-Type: application/json'`);
    parts.push(`--data ${shellQuote(JSON.stringify(JSON.parse(body)))}`);
  }
  if (operation.binary) parts.push("-o snapshot.jpg");
  return parts.join(" \\\n  ");
}

function responseView(view) {
  if (!view) return h("p", { class: "help response-empty" }, "No request sent yet.");
  const statusClass = view.error ? "is-error" : view.status >= 400 ? "is-error" : view.status >= 300 ? "is-warn" : "is-ok";
  return h(
    "div",
    { class: "response" },
    h(
      "p",
      { class: `response-status ${statusClass}` },
      view.status ? h("strong", {}, `${view.status}`) : h("strong", {}, "No answer"),
      view.statusText ? ` ${view.statusText}` : "",
      view.durationMs !== undefined ? h("span", { class: "response-meta" }, `${view.durationMs} ms`) : null,
      h("span", { class: "response-meta" }, `${view.method} ${view.path}`)
    ),
    view.error ? h("p", { class: "message message-error" }, view.error) : null,
    view.imageUrl
      ? h("img", {
          class: "response-image",
          src: view.imageUrl,
          alt: `Picture from ${view.path}`,
          onerror: (event) => event.target.replaceWith(h("p", { class: "message message-warn" }, "The answer is not a picture this browser can show.")),
        })
      : null,
    view.imageSize ? h("p", { class: "help" }, view.imageSize) : null,
    view.body !== undefined ? h("pre", { class: "code response-body", tabindex: "0" }, view.body) : null
  );
}

const STATUS_TEXT = { 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 415: "Unsupported Media Type", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable" };

async function sendOperation(operation, draft, parts) {
  let path;
  let body;
  try {
    path = buildPath(operation, draft);
    body = readBody(operation, draft);
  } catch (error) {
    setMessage(parts.inline, error.message, "error");
    return;
  }
  setMessage(parts.inline, "");
  parts.send.disabled = true;
  parts.send.textContent = "Sending…";
  const view = { method: operation.method, path };
  const started = performance.now();
  try {
    if (operation.binary) {
      try {
        const blob = await image(path, { auth: !operation.isPublic });
        if (imageUrl) URL.revokeObjectURL(imageUrl);
        imageUrl = URL.createObjectURL(blob);
        Object.assign(view, { status: 200, statusText: "OK", imageUrl, imageSize: `${blob.type || "image"} · ${Math.round(blob.size / 1024)} KB` });
      } catch (error) {
        if (!error.status) throw error;
        Object.assign(view, {
          status: error.status,
          statusText: STATUS_TEXT[error.status] || "",
          body: error.problem ? prettyJson(error.problem) : error.message,
        });
      }
    } else {
      const result = await send(path, { method: operation.method, body, auth: !operation.isPublic });
      Object.assign(view, {
        status: result.status,
        statusText: STATUS_TEXT[result.status] || "",
        durationMs: result.durationMs,
        body: result.data && typeof result.data === "object" ? prettyJson(result.data) : result.text || "(empty body)",
      });
      if (result.status === 403 && result.data?.detail) view.error = result.data.detail;
    }
  } catch (error) {
    view.error = error.message;
  }
  if (view.durationMs === undefined) view.durationMs = Math.round(performance.now() - started);
  results.set(operation.id, view);
  parts.send.disabled = false;
  parts.send.textContent = "Send";
  if (!parts.response.isConnected) {
    // The panel was redrawn while waiting (e.g. the connection status changed).
    if (selectedId === operation.id) renderDetail();
    return;
  }
  parts.response.replaceChildren(responseView(view));
}

function renderDetail() {
  const operation = operations.find((item) => item.id === selectedId);
  if (!operation) {
    detail.replaceChildren(h("p", { class: "help" }, operations.length ? "Choose an operation on the left." : "Connect to load the API description."));
    return;
  }
  const draft = draftFor(operation);
  const allowed = operation.isPublic || can(operation.role);
  const inline = h("p", { class: "message", role: "status", hidden: true });
  const response = h("div", { class: "response-area" }, responseView(results.get(operation.id)));
  const sendButton = h("button", { type: "button", class: "button button-primary" }, "Send");
  const curlButton = h("button", { type: "button", class: "button button-secondary" }, "Copy as curl");
  const parts = { inline, response, send: sendButton };

  let bodyField = null;
  if (operation.hasBody) {
    const area = h("textarea", { id: "op-body", class: "code body-input", rows: "8", spellcheck: "false" });
    area.value = draft.body;
    area.addEventListener("input", () => {
      draft.body = area.value;
    });
    const reset = h(
      "button",
      {
        type: "button",
        class: "button button-quiet button-small",
        onclick: () => {
          draft.body = prettyJson(operation.example ?? {});
          area.value = draft.body;
        },
      },
      "Reset to example"
    );
    bodyField = h(
      "div",
      { class: "param" },
      h("div", { class: "label-row" }, h("label", { class: "field-label", for: "op-body" }, `Request body (JSON${operation.bodyRequired ? ", required" : ""})`), reset),
      area
    );
  }

  sendButton.addEventListener("click", () => sendOperation(operation, draft, parts));
  curlButton.addEventListener("click", () => {
    try {
      const command = curlCommand(operation, buildPath(operation, draft), readBody(operation, draft));
      setMessage(inline, "");
      copyWithFeedback(curlButton, command);
    } catch (error) {
      setMessage(inline, error.message, "error");
    }
  });

  // append() skips the null parts (replaceChildren would print them).
  detail.replaceChildren();
  append(
    detail,
    [h(
      "div",
      { class: "op-head" },
      h("h2", { class: "op-title" }, methodBadge(operation.method), h("span", { class: "op-path" }, operation.path)),
      h("p", { class: "op-summary" }, operation.summary),
      h(
        "p",
        { class: "op-meta" },
        h("span", {}, operation.tag),
        roleBadge(operation),
        h("span", { class: "op-id" }, operation.id)
      )
    ),
    allowed
      ? null
      : h(
          "p",
          { class: "message message-warn" },
          `Needs the ${operation.role} role; this console's key is ${state.role}. The controller will answer 403. `,
          h("a", { href: "#/connect" }, "Request admin access")
        ),
    operation.description ? h("p", { class: "op-description" }, richText(operation.description)) : null,
    operation.parameters.length ? h("div", { class: "params" }, operation.parameters.map((parameter) => parameterField(operation, parameter, draft))) : null,
    bodyField,
    h("div", { class: "button-row" }, sendButton, curlButton),
    h("p", { class: "help" }, "“Copy as curl” reads the key from ", h("code", {}, "$DIRECTORLINK_KEY"), " — set it in your shell; the console never copies the key."),
    inline,
    response]
  );
}

export function selectOperation(id) {
  if (id && operations.some((operation) => operation.id === id)) {
    selectedId = id;
  } else if (!selectedId && operations.length) {
    selectedId = operations[0].id;
  }
  renderList();
  renderDetail();
}

export function renderExplorer(routeId) {
  if (state.spec !== spec) {
    spec = state.spec;
    operations = spec ? collectOperations(spec) : [];
    drafts.clear();
    results.clear();
  }
  if (!state.apiKey) {
    setMessage(message, "Connect first to load the API description.", "info");
  } else if (!spec) {
    setMessage(message, "This bridge did not serve its API description (GET /v1/openapi.json). Reconnect, or update the driver.", "error");
  } else {
    setMessage(message, "");
  }
  if (spec) {
    const usable = operations.filter((operation) => operation.isPublic || can(operation.role)).length;
    summary.textContent = `${spec.info?.title || "API"} ${spec.info?.version || ""} — ${operations.length} operations; this key (${state.role || "no key"}) can use ${usable}.`;
  }
  selectOperation(routeId);
}

filterInput.addEventListener("input", renderList);
