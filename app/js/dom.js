// Tiny DOM helpers. No innerHTML with data: names from Control4 are always set as text.

import { icon } from "./icons.js";

// h("button", { class: "x", onclick: fn, dataset: { key: "a" } }, "text", child, …)
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
    } else if (name === "style") {
      // CSSOM only: the CSP forbids style attributes.
      for (const [property, propertyValue] of Object.entries(value)) {
        element.style.setProperty(property, propertyValue);
      }
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

function append(element, children) {
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) {
      continue;
    }
    element.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
}

// A name that came from Control4 (often Hebrew inside an English interface, or the other way).
export function name(text, tag = "span", className = "") {
  return h(tag, { class: className || undefined, dir: "auto" }, text);
}

// A button that only shows an icon; label is required for screen readers.
export function iconButton(iconName, label, props = {}) {
  return h(
    "button",
    { type: "button", "aria-label": label, title: label, ...props, class: `icon-button ${props.class || ""}`.trim() },
    icon(iconName)
  );
}

export function clear(element) {
  element.replaceChildren();
}
