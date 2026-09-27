// Small DOM helpers. Text from the controller is always set as text, never as HTML.

// h("button", { class: "x", onclick: fn, dataset: { id: "a" } }, "text", child, …)
export function h(tag, props = {}, ...children) {
  const element = document.createElement(tag);
  for (const [name, value] of Object.entries(props || {})) {
    if (value === undefined || value === null || value === false) {
      continue;
    }
    if (name === "class") {
      element.className = value;
    } else if (name === "dataset") {
      Object.assign(element.dataset, value);
    } else if (name.startsWith("on") && typeof value === "function") {
      element.addEventListener(name.slice(2), value);
    } else if (name in element && typeof value !== "string") {
      element[name] = value;
    } else if (value === true) {
      element.setAttribute(name, "");
    } else {
      element.setAttribute(name, value);
    }
  }
  append(element, children);
  return element;
}

export function append(element, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) {
      continue;
    }
    element.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return element;
}

// Elements that are part of index.html (scripts/check_sites.py checks that each id exists).
export function byId(id) {
  const element = document.getElementById(id);
  if (!element) {
    throw new Error(`index.html is missing #${id}`);
  }
  return element;
}

// A status line: kind is "", "info", "success", "warn" or "error".
export function setMessage(element, text, kind = "") {
  element.textContent = text || "";
  element.className = `message${kind ? ` message-${kind}` : ""}`;
  element.hidden = !text;
}

export function formatTime(value) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return String(value);
  return date.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "medium" });
}

export function prettyJson(value) {
  return JSON.stringify(value, null, 2);
}

export async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    // Older browsers or a denied permission: copy through a temporary text area.
    const area = h("textarea", { class: "copy-buffer", readonly: true });
    area.value = text;
    document.body.append(area);
    area.select();
    let copied = false;
    try {
      copied = document.execCommand("copy");
    } catch {
      copied = false;
    }
    area.remove();
    return copied;
  }
}

// Shows "Copied" on a button for a moment.
export async function copyWithFeedback(button, text) {
  const label = button.dataset.label || button.textContent;
  button.dataset.label = label;
  const copied = await copyText(text);
  button.textContent = copied ? "Copied" : "Copy failed";
  window.setTimeout(() => {
    button.textContent = label;
  }, 1600);
  return copied;
}

export function downloadText(filename, text, type = "text/plain") {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const link = h("a", { href: url, download: filename, class: "copy-buffer" });
  document.body.append(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 1000);
}
