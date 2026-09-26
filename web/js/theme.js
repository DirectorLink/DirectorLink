// Palette (colour set) and theme (light / dark / auto). The colours themselves are CSS custom
// properties in styles.css on :root[data-palette=…][data-theme=…]; theme-boot.js applies the
// saved choice before the first paint and this module keeps it up to date afterwards.

export const PALETTES = ["graphite", "ocean", "forest", "plum", "midnight"];
export const THEMES = ["auto", "light", "dark"];

const PALETTE_KEY = "c4bridge.palette";
const THEME_KEY = "c4bridge.theme";
const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");

function read(key) {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

function write(key, value) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // Private mode: the choice lasts for this visit only.
  }
}

export function palettePreference() {
  const value = read(PALETTE_KEY);
  return PALETTES.includes(value) ? value : "graphite";
}

export function themePreference() {
  const value = read(THEME_KEY);
  return THEMES.includes(value) ? value : "auto";
}

export function resolvedTheme(preference = themePreference()) {
  if (preference === "light" || preference === "dark") {
    return preference;
  }
  return darkQuery.matches ? "dark" : "light";
}

export function applyTheme() {
  const root = document.documentElement;
  root.dataset.palette = palettePreference();
  root.dataset.theme = resolvedTheme();
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) {
    const background = getComputedStyle(root).getPropertyValue("--bg").trim();
    if (background) {
      meta.content = background;
    }
  }
}

export function setPalette(palette) {
  if (PALETTES.includes(palette)) {
    write(PALETTE_KEY, palette);
    applyTheme();
  }
}

export function setTheme(theme) {
  if (THEMES.includes(theme)) {
    write(THEME_KEY, theme);
    applyTheme();
  }
}

// Follows the system setting while the theme is Auto.
export function watchSystemTheme(onChange) {
  darkQuery.addEventListener("change", () => {
    if (themePreference() === "auto") {
      applyTheme();
      onChange?.();
    }
  });
}
