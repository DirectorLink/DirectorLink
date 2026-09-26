// Interface text. Every string on screen goes through t(key, params).
//
// Adding a language: create web/i18n/<code>.js (copy en.js, translate the values) and add one
// line to LANGUAGES below. Keys missing from a translation fall back to English.

import en from "../i18n/en.js";

export const LANGUAGES = [
  { code: "en", label: "English", dir: "ltr" },
  { code: "he", label: "עברית", dir: "rtl" },
];

const LANGUAGE_KEY = "c4bridge.lang";
const loaded = { en };
let current = "en";
let pluralRules = new Intl.PluralRules("en");

function storedPreference() {
  try {
    return localStorage.getItem(LANGUAGE_KEY) || "auto";
  } catch {
    return "auto";
  }
}

// "auto" follows the browser's preferred languages.
export function languagePreference() {
  const value = storedPreference();
  return value === "auto" || LANGUAGES.some((item) => item.code === value) ? value : "auto";
}

export function resolveLanguage(preference = languagePreference()) {
  if (preference !== "auto") {
    return preference;
  }
  for (const tag of navigator.languages || [navigator.language || "en"]) {
    const base = String(tag).toLowerCase().split("-")[0];
    const alias = base === "iw" ? "he" : base;
    if (LANGUAGES.some((item) => item.code === alias)) {
      return alias;
    }
  }
  return "en";
}

export function currentLanguage() {
  return current;
}

export function languageInfo(code = current) {
  return LANGUAGES.find((item) => item.code === code) || LANGUAGES[0];
}

// Loads the dictionary and sets <html lang dir>. Returns the resolved language code.
export async function setLanguage(preference) {
  if (preference !== undefined) {
    try {
      localStorage.setItem(LANGUAGE_KEY, preference);
    } catch {
      // Private mode: the choice lasts for this visit only.
    }
  }
  let code = resolveLanguage(preference ?? languagePreference());
  if (!loaded[code]) {
    try {
      loaded[code] = (await import(`../i18n/${code}.js`)).default;
    } catch (error) {
      console.error(`Could not load language ${code}`, error);
      code = "en";
    }
  }
  current = code;
  pluralRules = new Intl.PluralRules(code);
  document.documentElement.lang = code;
  document.documentElement.dir = languageInfo(code).dir;
  return code;
}

function lookup(dictionary, key) {
  return key.split(".").reduce((node, part) => (node && typeof node === "object" ? node[part] : undefined), dictionary);
}

// t("home.lightsOn", { count: 3 }) -> "3 lights on". A value may be an object of plural forms
// (zero/one/two/few/many/other, chosen by Intl.PluralRules from params.count).
export function t(key, params = {}) {
  let value = lookup(loaded[current], key);
  if (value === undefined) {
    value = lookup(en, key);
  }
  if (value === undefined) {
    return key;
  }
  if (typeof value === "object") {
    const count = Number(params.count);
    const form = count === 0 && value.zero !== undefined ? "zero" : pluralRules.select(count);
    value = value[form] ?? value.other ?? "";
  }
  return String(value).replace(/\{(\w+)\}/g, (match, name) =>
    params[name] === undefined ? match : formatParam(params[name])
  );
}

function formatParam(value) {
  return typeof value === "number" ? formatNumber(value) : String(value);
}

export function formatNumber(value, options) {
  return new Intl.NumberFormat(current, options).format(value);
}

export function formatTemperature(value) {
  if (!Number.isFinite(value)) {
    return "—";
  }
  // Isolated left-to-right, so "26°" keeps its degree sign on the right inside Hebrew text.
  return `\u2066${formatNumber(value, { maximumFractionDigits: 1 })}°\u2069`;
}

export function formatTime(date) {
  return new Intl.DateTimeFormat(current, { hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(date);
}
