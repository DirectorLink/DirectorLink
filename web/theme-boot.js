// Runs before the first paint (a blocking script in <head>; the site's CSP forbids inline
// scripts) so the saved palette, theme and text direction apply without a flash.
// js/theme.js takes over once the app has loaded.
(function () {
  var root = document.documentElement;
  var palettes = ["graphite", "ocean", "forest", "plum", "midnight"];
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
  var palette = read("c4bridge.palette");
  if (palettes.indexOf(palette) < 0) palette = "graphite";
  var theme = read("c4bridge.theme");
  if (theme !== "light" && theme !== "dark") {
    theme = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  }
  root.setAttribute("data-palette", palette);
  root.setAttribute("data-theme", theme);

  var lang = read("c4bridge.lang");
  if (!lang || lang === "auto") {
    var tags = navigator.languages || [navigator.language || "en"];
    lang = "en";
    for (var i = 0; i < tags.length; i++) {
      var base = String(tags[i]).toLowerCase().split("-")[0];
      if (base === "he" || base === "iw") {
        lang = "he";
        break;
      }
      if (base === "en") break;
    }
  }
  if (lang === "he") {
    root.setAttribute("lang", "he");
    root.setAttribute("dir", "rtl");
  }

  var meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", backgrounds[palette][theme === "dark" ? 1 : 0]);
})();
