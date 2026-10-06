// Runs before the first paint (a blocking script in <head>; the site's CSP forbids inline
// scripts) so the saved palette, theme, text size and text direction apply without a flash.
// js/theme.js and js/i18n.js take over once the app has loaded.
(function () {
  var root = document.documentElement;
  var palettes = ["graphite", "ocean", "forest", "plum", "midnight"];
  // As js/theme.js TEXT_SIZES; styles.css scales the root font size for each (ADR-067).
  var textSizes = ["small", "default", "large", "larger"];
  // As js/i18n.js LANGUAGES: the codes, and those written right to left.
  var languages = ["en", "he", "es", "it"];
  var rtl = ["he"];
  // Page background per palette: the browser's toolbar colour (meta theme-color).
  var backgrounds = {
    graphite: ["#f5f5f4", "#0f1012"],
    ocean: ["#eef4f6", "#0a1419"],
    forest: ["#f3f1ea", "#121510"],
    plum: ["#f6f3f7", "#140f19"],
    midnight: ["#f2f4f8", "#0b1020"],
  };
  function read(key) {
    try {
      return localStorage.getItem(key);
    } catch (error) {
      return null;
    }
  }
  var palette = read("directorlink.palette");
  if (palettes.indexOf(palette) < 0) palette = "graphite";
  var theme = read("directorlink.theme");
  if (theme !== "light" && theme !== "dark") {
    theme = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  var textSize = read("directorlink.textSize");
  if (textSizes.indexOf(textSize) < 0) textSize = "default";
  root.setAttribute("data-palette", palette);
  root.setAttribute("data-theme", theme);
  root.setAttribute("data-text-size", textSize);

  // The saved language, or the browser's first one DirectorLink has ("iw" is Hebrew's old code).
  var lang = read("directorlink.lang");
  if (languages.indexOf(lang) < 0) {
    var tags = navigator.languages || [navigator.language || "en"];
    lang = "en";
    for (var i = 0; i < tags.length; i++) {
      var base = String(tags[i]).toLowerCase().split("-")[0];
      if (base === "iw") base = "he";
      if (languages.indexOf(base) >= 0) {
        lang = base;
        break;
      }
    }
  }
  if (lang !== "en") {
    root.setAttribute("lang", lang);
    root.setAttribute("dir", rtl.indexOf(lang) >= 0 ? "rtl" : "ltr");
  }

  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", backgrounds[palette][theme === "dark" ? 1 : 0]);
})();
