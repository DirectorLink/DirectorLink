// Palette (colour set), theme (light / dark / auto) and text size. The colours themselves are CSS
// custom properties in styles.css on :root[data-palette=…][data-theme=…], the text size scales the
// root font size (:root[data-text-size=…]); theme-boot.js applies the saved choices before the
// first paint and this module keeps them up to date afterwards.
//
// Palette and theme follow the user (their profile, js/profile.js); the text size stays on this
// device (ADR-067): a phone and a big screen need different sizes.

export const PALETTES = ["graphite", "ocean", "forest", "plum", "midnight"];
export const THEMES = ["auto", "light", "dark"];
// theme-boot.js and styles.css know the same sizes.
export const TEXT_SIZES = ["small", "default", "large", "larger"];

const PALETTE_KEY = "directorlink.palette";
const THEME_KEY = "directorlink.theme";
const TEXT_SIZE_KEY = "directorlink.textSize";
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

export function textSizePreference() {
  const value = read(TEXT_SIZE_KEY);
  return TEXT_SIZES.includes(value) ? value : "default";
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
  root.dataset.textSize = textSizePreference();
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

// This device's text size, at once on every screen (never sent to the controller).
export function setTextSize(size) {
  if (TEXT_SIZES.includes(size)) {
    write(TEXT_SIZE_KEY, size);
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
