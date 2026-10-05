// DirectorLink demo home: the app's screens with a made-up home, in the visitor's browser only.
// Nothing here talks to a controller or any server, and nothing is stored. ICONS are copied from
// app/js/icons.js; the pictures (try/pictures/) are drawings.
(() => {
  "use strict";

  const ICONS = {"phone":"<rect x=\"7\" y=\"2.5\" width=\"10\" height=\"19\" rx=\"2.2\"/><path d=\"M11 18.5h2\"/>","home":"<path d=\"M3 10.5 12 3l9 7.5\"/><path d=\"M5 9.5V20a1 1 0 0 0 1 1h4v-6h4v6h4a1 1 0 0 0 1-1V9.5\"/>","camera":"<path d=\"M3 8a2 2 0 0 1 2-2h2.5l1.5-2h6l1.5 2H19a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2Z\"/><circle cx=\"12\" cy=\"13\" r=\"3.5\"/>","climate":"<path d=\"M14 14.8V5a2 2 0 0 0-4 0v9.8a4 4 0 1 0 4 0Z\"/><path d=\"M12 11v6\"/>","settings":"<circle cx=\"12\" cy=\"12\" r=\"3\"/><path d=\"M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z\"/>","bulb":"<path d=\"M9 18h6\"/><path d=\"M10 21h4\"/><path d=\"M12 3a6 6 0 0 0-3.6 10.8c.7.6 1.1 1.3 1.1 2.2h5c0-.9.4-1.6 1.1-2.2A6 6 0 0 0 12 3Z\"/>","blinds":"<path d=\"M4 4h16\"/><path d=\"M5 4v16h14V4\"/><path d=\"M5 8h14M5 12h14M5 16h14\"/>","fan":"<circle cx=\"12\" cy=\"12\" r=\"1.5\"/><path d=\"M12 10.5C11 7 11.5 3 14.5 3c2 0 2.5 2 1.5 3.5-1 1.6-2.6 2.6-4 4Z\"/><path d=\"M13.3 12.8c3.4 1 6 4 4.3 6.5-1.1 1.7-3 1-3.8-.5-.9-1.7-.9-3.6-.5-6Z\"/><path d=\"M10.7 12.8C7.4 13.9 4.5 13.4 4 10.4c-.3-2 1.6-2.8 3.2-2.2 1.8.7 3 2.2 3.5 4.6Z\"/>","power":"<path d=\"M12 3v8\"/><path d=\"M6.3 6.3a8 8 0 1 0 11.4 0\"/>","star":"<path d=\"m12 3 2.8 5.7 6.2.9-4.5 4.4 1 6.2L12 17.3l-5.5 2.9 1-6.2L3 9.6l6.2-.9Z\"/>","chevronBack":"<path d=\"m15 18-6-6 6-6\"/>","chevronForward":"<path d=\"m9 18 6-6-6-6\"/>","plus":"<path d=\"M12 5v14M5 12h14\"/>","minus":"<path d=\"M5 12h14\"/>","check":"<path d=\"m5 12.5 4.5 4.5L19 7.5\"/>","door":"<path d=\"M6 21V4a1 1 0 0 1 1-1h10a1 1 0 0 1 1 1v17\"/><path d=\"M4 21h16\"/><path d=\"M14 12h.01\"/>","music":"<path d=\"M9 18V5l11-2v13\"/><circle cx=\"6.5\" cy=\"18\" r=\"2.5\"/><circle cx=\"17.5\" cy=\"16\" r=\"2.5\"/>","play":"<path d=\"M8 5.5v13l10.5-6.5Z\"/>","pause":"<path d=\"M8 5.5v13M16 5.5v13\"/>","skipNext":"<path d=\"M5.5 5.5v13l9-6.5Z\"/><path d=\"M18.5 5.5v13\"/>","skipPrevious":"<path d=\"M18.5 5.5v13l-9-6.5Z\"/><path d=\"M5.5 5.5v13\"/>","volume":"<path d=\"M4 9.5h3.5L12 5.5v13l-4.5-4H4Z\"/><path d=\"M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11\"/>","sun":"<circle cx=\"12\" cy=\"12\" r=\"4\"/><path d=\"M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4\"/>","moon":"<path d=\"M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5Z\"/>","scene":"<path d=\"M11 3.5 12.8 8 17.5 9.8 12.8 11.6 11 16.3 9.2 11.6 4.5 9.8 9.2 8Z\"/><path d=\"m18 14 .9 2.1 2.1.9-2.1.9L18 20l-.9-2.1-2.1-.9 2.1-.9Z\"/>","leave":"<path d=\"M10 4H6a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h4\"/><path d=\"M14 8l4 4-4 4\"/><path d=\"M18 12H9\"/>","movie":"<rect x=\"3\" y=\"7\" width=\"18\" height=\"13\" rx=\"2\"/><path d=\"M3 11h18\"/><path d=\"m4 7 3-3 3 3M11 7l3-3 3 3\"/>","shield":"<path d=\"M12 3 4.5 6v5.5c0 4.4 3.2 8.2 7.5 9.5 4.3-1.3 7.5-5.1 7.5-9.5V6Z\"/>","bell":"<path d=\"M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15Z\"/><path d=\"M10 20.5a2 2 0 0 0 4 0\"/><path d=\"M12 3v2\"/>","fridge":"<rect x=\"5.5\" y=\"2.5\" width=\"13\" height=\"19\" rx=\"2\"/><path d=\"M5.5 9.5h13\"/><path d=\"M9 5.5v1.5M9 12.5v3\"/>","users":"<circle cx=\"9\" cy=\"8\" r=\"3.5\"/><path d=\"M2.5 20a6.5 6.5 0 0 1 13 0\"/><path d=\"M15.5 4.7a3.5 3.5 0 0 1 0 6.6\"/><path d=\"M18 14.3a6.5 6.5 0 0 1 3.5 5.7\"/>","close":"<path d=\"M6 6l12 12M18 6 6 18\"/>","clock":"<circle cx=\"12\" cy=\"12\" r=\"9\"/><path d=\"M12 7v5l3 2\"/>","arrowUp":"<path d=\"M12 19V5\"/><path d=\"m6 11 6-6 6 6\"/>","arrowDown":"<path d=\"M12 5v14\"/><path d=\"m6 13 6 6 6-6\"/>","stop":"<rect x=\"6.5\" y=\"6.5\" width=\"11\" height=\"11\" rx=\"1.5\"/>"};
  const PICTURES = window.DIRECTORLINK_DEMO_PICTURES || {};
  const pictureBase = (document.currentScript && document.currentScript.dataset.pictures) || "/try/pictures/";
  const picture = (name, size) => PICTURES[`${name}-${size}`] || `${pictureBase}${name}-${size}.jpg`;

  // ---- DOM helpers ------------------------------------------------------------------------------
  const SVG = "http://www.w3.org/2000/svg";
  function icon(name, className = "") {
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("fill", "none");
    svg.setAttribute("stroke", "currentColor");
    svg.setAttribute("stroke-width", "1.8");
    svg.setAttribute("stroke-linecap", "round");
    svg.setAttribute("stroke-linejoin", "round");
    svg.setAttribute("aria-hidden", "true");
    svg.setAttribute("focusable", "false");
    svg.setAttribute("class", `icon ${className}`.trim());
    svg.innerHTML = ICONS[name] || "";
    return svg;
  }
  function h(tag, props, ...children) {
    const el = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (value == null || value === false) continue;
      if (key === "class") el.className = value;
      else if (key === "dataset") Object.assign(el.dataset, value);
      else if (key.startsWith("on")) el.addEventListener(key.slice(2), value);
      else if (key === "text") el.textContent = value;
      else el.setAttribute(key, value === true ? "" : value);
    }
    for (const child of children.flat(Infinity)) {
      if (child == null || child === false) continue;
      el.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return el;
  }
  const clock = (date = new Date()) => date.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit", second: "2-digit" });

  // ---- The made-up home -------------------------------------------------------------------------
  const ROOMS = [
    { id: "living", name: "Living Room" },
    { id: "kitchen", name: "Kitchen" },
    { id: "master", name: "Master Bedroom" },
    { id: "kids", name: "Kids’ Room" },
    { id: "entrance", name: "Entrance" },
    { id: "garden", name: "Garden" },
  ];
  const roomName = (id) => (ROOMS.find((room) => room.id === id) || {}).name || "";
  const TRACKS = [
    { title: "Morning Light", artist: "The Example Band", art: "" },
    { title: "Slow River", artist: "North Avenue", art: "is-b" },
    { title: "Harbour Lights", artist: "The Made-Up Trio", art: "is-c" },
  ];
  const CAMERAS = [
    { id: "front-door", name: "Front Door", room: "entrance" },
    { id: "back-yard", name: "Back Yard", room: "garden" },
    { id: "driveway", name: "Driveway", room: "entrance" },
    { id: "garden", name: "Garden", room: "garden" },
  ];
  // Up to this many devices a user (ADR-061).
  const DEVICE_LIMIT = 5;

  function freshHome() {
    return {
      lights: [
        { id: "l1", room: "living", name: "Ceiling Lights", dim: true, on: true, level: 80 },
        { id: "l2", room: "living", name: "LED Strip", dim: true, on: false, level: 60 },
        { id: "l3", room: "living", name: "Wall Lamps", dim: true, on: true, level: 45 },
        { id: "l4", room: "kitchen", name: "Pendants", dim: true, on: true, level: 70 },
        { id: "l5", room: "kitchen", name: "Island Lights", dim: false, on: false },
        { id: "l6", room: "kitchen", name: "Under-cabinet", dim: false, on: true },
        { id: "l7", room: "master", name: "Ceiling Light", dim: true, on: false, level: 100 },
        { id: "l8", room: "master", name: "Bedside Lamps", dim: true, on: false, level: 40 },
        { id: "l9", room: "kids", name: "Night Light", dim: true, on: true, level: 20 },
        { id: "l10", room: "kids", name: "Ceiling Light", dim: false, on: false },
        { id: "l11", room: "entrance", name: "Entrance Lights", dim: true, on: true, level: 40 },
        { id: "l12", room: "entrance", name: "Porch Light", dim: false, on: false },
        { id: "l13", room: "garden", name: "Garden Lights", dim: false, on: false },
        { id: "l14", room: "garden", name: "Path Lights", dim: false, on: true },
      ],
      climate: [
        { id: "c1", room: "living", name: "AC", heater: false, mode: "cool", target: 23, now: 25.5, fan: "Medium" },
        { id: "c2", room: "master", name: "Floor Heating", heater: true, mode: "heat", target: 24, now: 22.5 },
        { id: "c3", room: "kids", name: "AC", heater: false, mode: "off", target: 24, now: 26, fan: "Low" },
      ],
      blinds: [
        { id: "b1", room: "living", name: "Curtain", position: 50, moving: 0 },
        { id: "b2", room: "master", name: "Shutter", position: 0, moving: 0 },
        { id: "b3", room: "kitchen", name: "Window Blind", position: 100, moving: 0 },
      ],
      doors: [
        { id: "d1", room: "entrance", name: "Main gate", kind: "gate", phase: "closed" },
        { id: "d2", room: "entrance", name: "Front Door", kind: "door", phase: "closed" },
      ],
      sonos: [
        { id: "kitchen", room: "kitchen", name: "Kitchen", volume: 30, follows: "kitchen", playing: true, track: 0 },
        { id: "living", room: "living", name: "Living Room", volume: 20, follows: "living", playing: false, track: 1 },
        { id: "master", room: "master", name: "Master Bedroom", volume: 15, follows: "master", playing: false, track: 2 },
      ],
      fridge: { fridge: 4, freezer: -18, powerCool: false, waiting: false },
      users: [
        { id: "alex", name: "Alex", role: "Admin", owner: true, account: "Google", devices: [
          { id: "k1", name: "Alex’s iPhone", last: "Now", self: true }, { id: "k2", name: "Alex’s PC", last: "Today 09:12" }] },
        { id: "jordan", name: "Jordan", role: "Admin", account: "Apple", devices: [
          { id: "k3", name: "Jordan’s iPhone", last: "Today 17:20" }, { id: "k4", name: "Jordan’s MacBook", last: "Yesterday" }] },
        { id: "sam", name: "Sam", role: "Member", account: "Google", devices: [{ id: "k5", name: "Sam’s iPhone", last: "Today 16:02" }],
          access: { rooms: ["living", "kitchen", "kids", "entrance", "garden"], kinds: ["Lights", "Climate", "Blinds", "Music"], cameras: true, doors: true } },
        { id: "robin", name: "Robin", role: "Member", account: null, devices: [{ id: "k6", name: "Robin’s iPad", last: "Today 15:40" }],
          access: { rooms: ["kids"], kinds: ["Lights", "Music"], cameras: false, doors: false } },
        { id: "kitchen-tablet", name: "Kitchen Tablet", role: "Member", account: null, devices: [{ id: "k7", name: "Kitchen tablet", last: "Now" }],
          access: { rooms: ["kitchen", "living"], kinds: ["Lights", "Music"], cameras: true, doors: false } },
      ],
      alerts: { doorbell: true, camera: false, doors: true, fridge: true },
    };
  }

  // ---- What to try ------------------------------------------------------------------------------
  const TASKS = [
    { id: "light", name: "Turn on a light", help: "In a room, or from Home.", show: { tab: "home", room: "living" }, hint: "light-l2" },
    { id: "ac", name: "Cool the living room", help: "Set the AC a degree lower.", show: { tab: "home", room: "living" }, hint: "climate-c1" },
    { id: "scene", name: "Run Good Night", help: "One tap: lights, blinds and the AC.", show: { tab: "scenes" }, hint: "scene-s4" },
    { id: "gate", name: "Open the main gate", help: "Two taps, so it never opens by mistake.", show: { tab: "home", room: "entrance" }, hint: "door-d1" },
    { id: "group", name: "Play music in two rooms", help: "Add the living room to the kitchen’s music.", show: { tab: "home", room: "kitchen" }, hint: "music-more" },
    { id: "camera", name: "Look at a camera", help: "Tap a picture for the full view.", show: { tab: "cameras" }, hint: "camera-front-door" },
  ];

  let home = freshHome();
  let route = { tab: "home" };
  let done = {};
  let toast = null;
  let toastTimer = 0;
  let hintKey = null;
  let viewer = null; // a camera's full view
  let musicPick = null; // the Sonos room adding others
  const scroll = new Map();
  const timers = new Set();
  const later = (ms, fn) => {
    const id = setTimeout(() => {
      timers.delete(id);
      fn();
    }, ms);
    timers.add(id);
    return id;
  };

  function finish(task) {
    if (done[task]) return;
    done[task] = true;
    renderTasks();
  }
  function say(text, iconName = "check") {
    toast = { text, icon: iconName };
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => {
      toast = null;
      render();
    }, 2800);
  }

  // ---- Changing the home ------------------------------------------------------------------------
  const light = (id) => home.lights.find((item) => item.id === id);
  function put(id, on, level) {
    const item = light(id);
    item.on = on;
    if (level != null) item.level = level;
  }
  function setLight(id, on, level) {
    put(id, on, level);
    if (on) finish("light");
  }
  function setTarget(item, delta) {
    const min = item.heater ? 15 : 16;
    const max = item.heater ? 30 : 30;
    item.target = Math.min(max, Math.max(min, item.target + delta));
    if (item.mode === "off") item.mode = item.heater ? "heat" : "cool";
    if (item.id === "c1" && delta < 0) finish("ac");
  }
  function moveBlind(item, to) {
    clearInterval(item.timer);
    item.moving = to > item.position ? 1 : to < item.position ? -1 : 0;
    if (!item.moving) return;
    item.timer = setInterval(() => {
      item.position = Math.max(0, Math.min(100, item.position + item.moving * 10));
      if ((item.moving > 0 && item.position >= to) || (item.moving < 0 && item.position <= to)) {
        item.position = to;
        item.moving = 0;
        clearInterval(item.timer);
      }
      render();
    }, 300);
  }
  function stopBlind(item) {
    clearInterval(item.timer);
    item.moving = 0;
  }
  function pressDoor(item) {
    if (item.phase === "closed") {
      item.phase = "confirm";
      clearTimeout(item.timer);
      item.timer = later(5000, () => {
        if (item.phase === "confirm") item.phase = "closed";
        render();
      });
    } else if (item.phase === "confirm") {
      clearTimeout(item.timer);
      item.phase = "opening";
      if (item.id === "d1") finish("gate");
      say(`${item.name} is opening`, "door");
      later(2500, () => {
        item.phase = "open";
        render();
        later(4000, () => {
          item.phase = "closed";
          render();
        });
      });
    }
  }
  function cancelDoor(item) {
    clearTimeout(item.timer);
    item.phase = "closed";
  }
  const sonos = (id) => home.sonos.find((room) => room.id === id);
  const leaderOf = (room) => sonos(room.follows);
  const groupOf = (leader) => home.sonos.filter((room) => room.follows === leader.id);
  function joinGroup(roomId, leaderId) {
    const room = sonos(roomId);
    room.follows = leaderId;
    room.playing = false;
    if (groupOf(sonos(leaderId)).length > 1) finish("group");
  }
  function leaveGroup(roomId) {
    const room = sonos(roomId);
    room.follows = room.id;
    room.playing = false;
  }

  const SCENES = [
    {
      id: "s1", name: "Good Morning", icon: "sun", steps: "Blinds open · Kitchen lights on · Music in the Kitchen",
      run() {
        home.blinds.forEach((item) => moveBlind(item, 100));
        put("l4", true, 70);
        put("l6", true);
        const kitchen = sonos("kitchen");
        kitchen.playing = true;
        return 6;
      },
    },
    {
      id: "s2", name: "Movie Night", icon: "movie", steps: "Living Room lights 20% · LED Strip 60% · Curtain closed",
      run() {
        put("l1", true, 20);
        put("l3", false);
        put("l2", true, 60);
        moveBlind(home.blinds[0], 0);
        return 4;
      },
    },
    {
      id: "s3", name: "Leaving Home", icon: "leave", steps: "All lights off · AC off · Blinds closed · Music paused",
      run() {
        home.lights.forEach((item) => (item.on = false));
        home.climate.forEach((item) => { if (!item.heater) item.mode = "off"; });
        home.blinds.forEach((item) => moveBlind(item, 0));
        home.sonos.forEach((room) => (room.playing = false));
        return home.lights.length + 6;
      },
    },
    {
      id: "s4", name: "Good Night", icon: "moon", steps: "All lights off · Night Light 10% · Blinds closed · Bedroom heating 22°",
      run() {
        home.lights.forEach((item) => (item.on = false));
        put("l9", true, 10);
        home.blinds.forEach((item) => moveBlind(item, 0));
        const heat = home.climate[1];
        heat.mode = "heat";
        heat.target = 22;
        home.sonos.forEach((room) => (room.playing = false));
        finish("scene");
        return home.lights.length + 4;
      },
    },
    {
      id: "s5", name: "Welcome Home", icon: "home", steps: "Entrance lights 80% · Living Room 60% · AC 23°",
      run() {
        put("l11", true, 80);
        put("l1", true, 60);
        put("l3", true, 60);
        const ac = home.climate[0];
        ac.mode = "cool";
        ac.target = 23;
        return 4;
      },
    },
  ];
  function runScene(scene) {
    const count = scene.run();
    say(`${scene.name} ran on ${count} devices`, scene.icon);
    render();
  }

  // ---- Pieces of the screens --------------------------------------------------------------------
  function section(title, iconName, ...content) {
    return h("section", { class: "sec" }, h("div", { class: "sec-head" }, h("h2", {}, iconName ? icon(iconName) : null, title)), ...content);
  }
  function lightRow(item) {
    const status = item.on ? (item.dim ? `${item.level}%` : "On") : "Off";
    const row = h(
      "div",
      { class: "card dev", dataset: { key: `light-${item.id}` } },
      h(
        "div",
        { class: "dev-row" },
        h("span", { class: `dev-icon ${item.on ? "is-on" : ""}` }, icon("bulb")),
        h("div", {}, h("div", { class: "dev-name" }, item.name), h("div", { class: "dev-sub", dataset: { level: item.id } }, status)),
        h("button", {
          class: "switch", role: "switch", "aria-checked": String(item.on), "aria-label": `${item.name}`,
          dataset: { focus: `switch-${item.id}` },
          onclick: () => { setLight(item.id, !item.on); render(); },
        })
      ),
      item.dim
        ? h("div", { class: "range-row" },
            h("input", {
              class: "range", type: "range", min: "1", max: "100", value: String(item.level), "aria-label": `${item.name} brightness`,
              id: `range-${item.id}`, dataset: { focus: `range-${item.id}` },
              oninput: (event) => {
                const level = Number(event.target.value);
                item.level = level;
                item.on = true;
                const label = row.querySelector(`[data-level="${item.id}"]`);
                if (label) label.textContent = `${level}%`;
                row.querySelector(".switch").setAttribute("aria-checked", "true");
                row.querySelector(".dev-icon").classList.add("is-on");
                row.querySelector(".range-row span").textContent = `${level}%`;
              },
              onchange: () => { finish("light"); render(); },
            }),
            h("span", {}, `${item.level}%`))
        : null
    );
    return row;
  }
  function climateCard(item, showRoom) {
    const modes = item.heater ? ["off", "heat"] : ["off", "heat", "cool"];
    const label = { off: "Off", heat: "Heat", cool: "Cool" };
    const state = item.mode === "off" ? "Off" : `${label[item.mode]}ing to ${item.target}°`;
    const tone = item.mode === "cool" ? "is-cool" : item.mode === "heat" ? "is-heat" : "";
    return h(
      "div",
      { class: "card dev", dataset: { key: `climate-${item.id}` } },
      h("div", { class: "dev-row" },
        h("span", { class: `dev-icon ${tone}` }, icon(item.heater ? "sun" : "climate")),
        h("div", {}, h("div", { class: "dev-name" }, showRoom ? `${roomName(item.room)} · ${item.name}` : item.name),
          h("div", { class: "dev-sub" }, `Now ${item.now}° · ${state}`)),
        h("span")),
      h("div", { class: "climate-dial" },
        h("button", { class: "round", "aria-label": `${item.name} cooler`, dataset: { focus: `down-${item.id}` }, onclick: () => { setTarget(item, -1); render(); } }, icon("minus")),
        h("div", { class: "climate-target" }, `${item.target}°`, h("small", {}, "Target")),
        h("button", { class: "round", "aria-label": `${item.name} warmer`, dataset: { focus: `up-${item.id}` }, onclick: () => { setTarget(item, 1); render(); } }, icon("plus"))),
      h("div", { class: `seg ${item.mode === "heat" ? "is-heat" : ""}`, role: "group", "aria-label": `${item.name} mode` },
        modes.map((mode) => h("button", { "aria-pressed": String(item.mode === mode), dataset: { focus: `mode-${item.id}-${mode}` }, onclick: () => { item.mode = mode; render(); } }, label[mode]))),
      item.heater ? null : h("div", { class: "seg", role: "group", "aria-label": `${item.name} fan` },
        ["Low", "Medium", "High"].map((fan) => h("button", { "aria-pressed": String(item.fan === fan), dataset: { focus: `fan-${item.id}-${fan}` }, onclick: () => { item.fan = fan; render(); } }, `Fan ${fan.toLowerCase()}`)))
    );
  }
  function blindCard(item) {
    const state = item.moving > 0 ? `Opening… ${item.position}%` : item.moving < 0 ? `Closing… ${item.position}%` : item.position === 0 ? "Closed" : `${item.position}% open`;
    return h("div", { class: "card dev" },
      h("div", { class: "dev-row" },
        h("span", { class: `dev-icon ${item.position > 0 ? "is-cool" : ""}` }, icon("blinds")),
        h("div", {}, h("div", { class: "dev-name" }, item.name), h("div", { class: "dev-sub" }, state)), h("span")),
      h("div", { class: "btn-row" },
        h("button", { class: "btn", dataset: { focus: `close-${item.id}` }, onclick: () => { moveBlind(item, 0); render(); } }, icon("arrowDown"), "Close"),
        h("button", { class: "btn", dataset: { focus: `stop-${item.id}` }, onclick: () => { stopBlind(item); render(); } }, icon("stop"), "Stop"),
        h("button", { class: "btn", dataset: { focus: `open-${item.id}` }, onclick: () => { moveBlind(item, 100); render(); } }, icon("arrowUp"), "Open")));
  }
  function doorCard(item) {
    let actions;
    if (item.phase === "confirm") {
      actions = [
        h("button", { class: "door-cancel", dataset: { focus: `cancel-${item.id}` }, onclick: () => { cancelDoor(item); render(); } }, "Cancel"),
        h("button", { class: "btn btn-primary", dataset: { focus: `door-${item.id}` }, onclick: () => { pressDoor(item); render(); } }, icon("door"), "Tap again to open"),
      ];
    } else if (item.phase === "opening") {
      actions = [h("span", { class: "btn btn-ok" }, "Opening…")];
    } else {
      actions = [h("button", { class: "btn", dataset: { focus: `door-${item.id}` }, onclick: () => { pressDoor(item); render(); } }, icon("door"), "Open")];
    }
    const sub = item.phase === "confirm" ? "Tap again within 5 seconds" : item.phase === "opening" ? "Opening" : item.phase === "open" ? "Open · closes by itself" : "Closed";
    return h("div", { class: "card dev", dataset: { key: `door-${item.id}` } },
      h("div", { class: "dev-row" },
        h("span", { class: `dev-icon ${item.phase === "open" || item.phase === "opening" ? "is-on" : ""}` }, icon("door")),
        h("div", {}, h("div", { class: "dev-name" }, item.name), h("div", { class: "dev-sub" }, item.kind === "gate" ? `Gate · ${sub}` : `Door · ${sub}`)),
        h("span")),
      h("div", { class: "door-actions" }, actions));
  }
  function musicCard(room) {
    const leader = leaderOf(room);
    const members = groupOf(leader);
    const track = TRACKS[leader.track];
    const names = members.map((member) => member.name).join(" + ");
    const card = h("div", { class: "card music", dataset: { key: `music-${leader.id}` } },
      h("div", { class: "music-top" },
        h("div", { class: `art ${track.art}`, role: "img", "aria-label": "Album art" }),
        h("div", {}, h("div", { class: "music-where" }, names),
          h("div", { class: "music-title" }, track.title),
          h("div", { class: "music-artist" }, `${track.artist} · ${leader.playing ? "Playing" : "Paused"}`))),
      h("div", { class: "music-ctrl" },
        h("button", { "aria-label": "Previous", onclick: () => { leader.track = (leader.track + TRACKS.length - 1) % TRACKS.length; render(); } }, icon("skipPrevious")),
        h("button", { class: "play", "aria-label": leader.playing ? "Pause" : "Play", dataset: { focus: `play-${leader.id}` }, onclick: () => { leader.playing = !leader.playing; render(); } }, icon(leader.playing ? "pause" : "play")),
        h("button", { "aria-label": "Next", onclick: () => { leader.track = (leader.track + 1) % TRACKS.length; render(); } }, icon("skipNext")))
    );
    if (members.length > 1) {
      const average = Math.round(members.reduce((sum, member) => sum + member.volume, 0) / members.length);
      card.append(h("div", { class: "music-room" },
        h("div", { class: "music-room-head" }, h("strong", {}, "Group volume")),
        h("div", { class: "range-row" }, h("input", {
          class: "range", type: "range", min: "0", max: "100", value: String(average), "aria-label": "Group volume", id: `group-${leader.id}`,
          onchange: (event) => {
            const to = Number(event.target.value);
            const factor = average ? to / average : 1;
            members.forEach((member) => (member.volume = Math.max(0, Math.min(100, Math.round(average ? member.volume * factor : to)))));
            render();
          },
        }), h("span", {}, `${average}%`))));
    }
    for (const member of members) {
      card.append(h("div", { class: "music-room" },
        h("div", { class: "music-room-head" }, h("span", {}, member.name),
          members.length > 1 ? h("button", { class: "leave", dataset: { focus: `leave-${member.id}` }, onclick: () => { leaveGroup(member.id); render(); } }, "Leave group") : null),
        h("div", { class: "range-row" }, h("input", {
          class: "range", type: "range", min: "0", max: "100", value: String(member.volume), "aria-label": `${member.name} volume`, id: `vol-${member.id}`,
          oninput: (event) => { member.volume = Number(event.target.value); event.target.nextSibling.textContent = `${member.volume}%`; },
          onchange: () => render(),
        }), h("span", {}, `${member.volume}%`))));
    }
    const others = home.sonos.filter((other) => other.follows !== leader.id);
    if (musicPick === leader.id && others.length) {
      card.append(h("div", { class: "pick" },
        h("p", { class: "pick-help" }, "Tap a room and it plays this too, in step."),
        others.map((other) => h("button", { class: "btn", dataset: { key: `pick-${other.id}`, focus: `pick-${other.id}` }, onclick: () => {
          joinGroup(other.id, leader.id);
          musicPick = null;
          say(`${other.name} plays with ${leader.name}`, "music");
          render();
        } }, icon("plus"), other.name))));
    } else if (others.length) {
      card.append(h("button", { class: "music-more", dataset: { key: "music-more", focus: `more-${leader.id}` }, onclick: () => { musicPick = leader.id; render(); } }, icon("plus"), "Play in more rooms…"));
    }
    return card;
  }
  function fridgeCard() {
    const fridge = home.fridge;
    return h("div", { class: "card dev" },
      h("div", { class: "dev-row" }, h("span", { class: "dev-icon is-cool" }, icon("fridge")),
        h("div", {}, h("div", { class: "dev-name" }, "Refrigerator"), h("div", { class: "dev-sub" }, `Fridge ${fridge.fridge}° · Freezer ${fridge.freezer}° · Doors closed`)), h("span")),
      h("div", { class: "dev-row" }, h("span"),
        h("div", {}, h("div", { class: "dev-name" }, "Power Cool"), h("div", { class: "dev-sub" }, fridge.waiting ? (fridge.powerCool ? "Turning on…" : "Turning off…") : fridge.powerCool ? "On" : "Off")),
        h("button", { class: `switch ${fridge.waiting ? "is-wait" : ""}`, role: "switch", "aria-checked": String(fridge.powerCool), "aria-label": "Power Cool", dataset: { focus: "fridge" },
          onclick: () => {
            if (fridge.waiting) return;
            fridge.powerCool = !fridge.powerCool;
            fridge.waiting = true;
            later(1600, () => { fridge.waiting = false; render(); });
            render();
          } })));
  }
  function cameraTile(camera, large) {
    const open = () => { viewer = camera.id; finish("camera"); render(); };
    return h("button", { class: large ? "cam-main" : "cam-tile", "aria-label": `${camera.name}: full view`, dataset: { key: `camera-${camera.id}`, focus: `camera-${camera.id}` }, onclick: open },
      h("img", { src: picture(camera.id, large ? 640 : 320), alt: "", width: large ? "640" : "320", height: large ? "400" : "200" }),
      h("span", { class: "cam-name" }, camera.name),
      h("span", { class: "cam-sub", dataset: { clock: "1" } }, `${roomName(camera.room)} · ${clock()}`));
  }

  // ---- Screens ----------------------------------------------------------------------------------
  function summaryChips() {
    const lightsOn = home.lights.filter((item) => item.on).length;
    const acOn = home.climate.filter((item) => item.mode !== "off").length;
    const blindsOpen = home.blinds.filter((item) => item.position > 0).length;
    return h("div", { class: "chips" },
      h("span", { class: `chip ${lightsOn ? "is-on" : ""}` }, icon("bulb"), lightsOn ? `${lightsOn} lights on` : "All lights off"),
      h("span", { class: `chip ${acOn ? "is-cool" : ""}` }, icon("climate"), acOn ? `${acOn} climate on` : "Climate off"),
      h("span", { class: "chip" }, icon("blinds"), blindsOpen ? `${blindsOpen} blinds open` : "Blinds closed"));
  }
  function roomSummary(room) {
    const lights = home.lights.filter((item) => item.room === room.id);
    const on = lights.filter((item) => item.on).length;
    const parts = [lights.length ? (on ? `${on} of ${lights.length} lights on` : "Lights off") : null];
    for (const item of home.climate.filter((c) => c.room === room.id)) parts.push(item.mode === "off" ? `${item.name} off` : `${item.mode === "cool" ? "Cool" : "Heat"} ${item.target}°`);
    for (const item of home.blinds.filter((b) => b.room === room.id)) parts.push(item.position ? `${item.name} ${item.position}% open` : `${item.name} closed`);
    if (home.doors.some((d) => d.room === room.id)) parts.push("Gate and door");
    const playing = home.sonos.find((s) => s.room === room.id && leaderOf(s).playing);
    if (playing) parts.push("Music playing");
    return parts.filter(Boolean).join(" · ");
  }
  function roomIcons(room) {
    const kinds = [];
    if (home.lights.some((i) => i.room === room.id)) kinds.push(["bulb", home.lights.some((i) => i.room === room.id && i.on)]);
    if (home.climate.some((i) => i.room === room.id)) kinds.push(["climate", false]);
    if (home.blinds.some((i) => i.room === room.id)) kinds.push(["blinds", false]);
    if (home.doors.some((i) => i.room === room.id)) kinds.push(["door", false]);
    if (CAMERAS.some((i) => i.room === room.id)) kinds.push(["camera", false]);
    if (home.sonos.some((i) => i.room === room.id)) kinds.push(["music", false]);
    if (room.id === "kitchen") kinds.push(["fridge", false]);
    return h("span", { class: "room-icons" }, kinds.map(([name, on]) => icon(name, on ? "is-on" : "")));
  }
  function homeScreen() {
    const ceiling = light("l1");
    const ac = home.climate[0];
    const gate = home.doors[0];
    const playing = home.sonos.find((room) => room.follows === room.id && room.playing) || sonos("kitchen");
    return [
      summaryChips(),
      section("Scenes", "scene", h("div", { class: "scroll-row" },
        SCENES.map((scene) => h("button", { class: "scene-chip", dataset: { focus: `chip-${scene.id}` }, onclick: () => runScene(scene) }, icon(scene.icon), scene.name)))),
      section("Favorites", "star", h("div", { class: "fav-grid" },
        h("button", { class: "fav fav-cam", dataset: { focus: "fav-cam" }, onclick: () => { viewer = "front-door"; finish("camera"); render(); } },
          h("img", { src: picture("front-door", 320), alt: "", width: "320", height: "200" }), h("span", { class: "fav-name" }, "Front Door")),
        h("button", { class: `fav ${ceiling.on ? "is-on" : ""}`, dataset: { focus: "fav-light" }, "aria-pressed": String(ceiling.on), onclick: () => { setLight("l1", !ceiling.on); render(); } },
          icon("bulb"), h("span", { class: "fav-name" }, "Ceiling Lights"), h("span", { class: "fav-sub" }, "Living Room"), h("span", { class: "fav-state" }, ceiling.on ? `${ceiling.level}%` : "Off")),
        h("button", { class: `fav ${ac.mode !== "off" ? "is-cool" : ""}`, dataset: { focus: "fav-ac" }, onclick: () => go({ tab: "home", room: "living" }) },
          icon("climate"), h("span", { class: "fav-name" }, "AC"), h("span", { class: "fav-sub" }, "Living Room"), h("span", { class: "fav-state" }, ac.mode === "off" ? "Off" : `${ac.now}° · ${ac.mode === "cool" ? "Cool" : "Heat"} ${ac.target}°`)),
        h("button", { class: `fav ${gate.phase === "confirm" ? "is-cool" : gate.phase !== "closed" ? "is-on" : ""}`, dataset: { focus: "fav-gate", key: "fav-gate" }, onclick: () => { pressDoor(gate); render(); } },
          icon("door"), h("span", { class: "fav-name" }, "Main gate"), h("span", { class: "fav-sub" }, "Entrance"),
          h("span", { class: "fav-state" }, gate.phase === "confirm" ? "Tap again to open" : gate.phase === "opening" ? "Opening…" : gate.phase === "open" ? "Open" : "Closed · tap to open")))),
      section("Music", "music", musicCard(playing)),
      section("Rooms", "home", h("div", { class: "list" },
        ROOMS.map((room) => h("button", { class: "room-card", dataset: { focus: `room-${room.id}` }, onclick: () => go({ tab: "home", room: room.id }) },
          roomIcons(room), h("span", { class: "room-name" }, room.name), h("span", { class: "room-sum" }, roomSummary(room)), icon("chevronForward"))))),
    ];
  }
  function roomScreen(roomId) {
    const parts = [];
    const lights = home.lights.filter((item) => item.room === roomId);
    if (lights.length) {
      parts.push(h("div", { class: "sec-head" }, h("span"), h("button", { class: "all-off", dataset: { focus: "all-off" }, onclick: () => { lights.forEach((item) => (item.on = false)); say("All off", "power"); render(); } }, icon("power"), "All off")));
      parts.push(section("Lights", "bulb", h("div", { class: "list" }, lights.map(lightRow))));
    }
    const climate = home.climate.filter((item) => item.room === roomId);
    if (climate.length) parts.push(section("Climate", "climate", h("div", { class: "list" }, climate.map((item) => climateCard(item)))));
    const blinds = home.blinds.filter((item) => item.room === roomId);
    if (blinds.length) parts.push(section("Blinds", "blinds", h("div", { class: "list" }, blinds.map(blindCard))));
    const doors = home.doors.filter((item) => item.room === roomId);
    if (doors.length) parts.push(section("Doors and gates", "door", h("div", { class: "list" }, doors.map(doorCard))));
    const music = home.sonos.find((item) => item.room === roomId);
    if (music) parts.push(section("Music", "music", musicCard(music)));
    if (roomId === "kitchen") parts.push(section("Refrigerators", "fridge", fridgeCard()));
    const cameras = CAMERAS.filter((camera) => camera.room === roomId);
    if (cameras.length) parts.push(section("Cameras", "camera", h("div", { class: "cam-grid" }, cameras.map((camera) => cameraTile(camera, false)))));
    return parts;
  }
  function scenesScreen() {
    return [
      h("p", { class: "small-note" }, "One tap runs everything in a scene. Admins make them in the app; no programming."),
      h("div", { class: "list" }, SCENES.map((scene) => h("div", { class: "card scene-card", dataset: { key: `scene-${scene.id}` } },
        h("span", { class: "dev-icon" }, icon(scene.icon)),
        h("div", {}, h("div", { class: "dev-name" }, scene.name), h("div", { class: "scene-steps" }, scene.steps)),
        h("button", { class: "btn btn-primary", dataset: { focus: `run-${scene.id}` }, onclick: () => runScene(scene) }, icon("play"), "Run")))),
      section("Schedules", "clock", h("div", { class: "list" },
        h("div", { class: "card sched" }, h("span", { class: "dev-icon" }, icon("clock")),
          h("div", {}, h("div", { class: "dev-name" }, "Mon–Fri at 07:00"), h("div", { class: "scene-steps" }, "Runs Good Morning"), h("span", { class: "tag" }, "Next: tomorrow 07:00"))),
        h("div", { class: "card sched" }, h("span", { class: "dev-icon" }, icon("sun")),
          h("div", {}, h("div", { class: "dev-name" }, "Every day at sunset"), h("div", { class: "scene-steps" }, "Turns on the Garden and Entrance lights"), h("span", { class: "tag" }, "Next: today 18:20"))),
        h("div", { class: "card sched" }, h("span", { class: "dev-icon" }, icon("climate")),
          h("div", {}, h("div", { class: "dev-name" }, "When it’s hotter than 30° outside"), h("div", { class: "scene-steps" }, "Closes the shutters, 12:00–17:00"))))),
    ];
  }
  function camerasScreen() {
    const [first, ...rest] = CAMERAS;
    return [
      cameraTile(first, true),
      h("div", { class: "cam-grid" }, rest.map((camera) => cameraTile(camera, false))),
      h("p", { class: "small-note" }, "Pictures come straight from the home, sealed so that nobody in between can see them."),
    ];
  }
  function climateScreen() {
    return [h("div", { class: "list" }, home.climate.map((item) => climateCard(item, true)))];
  }
  function settingsScreen() {
    const alert = (key, label) => h("div", { class: "kv" }, h("span", {}, label),
      h("button", { class: "switch", role: "switch", "aria-checked": String(home.alerts[key]), "aria-label": label, dataset: { focus: `alert-${key}` }, onclick: () => { home.alerts[key] = !home.alerts[key]; render(); } }));
    return [
      section("Users", "users", h("div", { class: "card list" },
        home.users.map((user, index) => [
          index ? h("div", { class: "divider" }) : null,
          h("button", { class: "person", dataset: { focus: `user-${user.id}` }, onclick: () => go({ tab: "settings", user: user.id }) },
            h("span", { class: "avatar" }, user.name[0]),
            h("span", {}, h("div", { class: "dev-name" }, user.name), h("div", { class: "dev-sub" }, userLine(user))),
            h("span", { class: "role" }, user.owner ? "Owner" : user.role)),
        ]))),
      h("p", { class: "small-note" }, `Each user has one set of permissions on all their devices, up to ${DEVICE_LIMIT}. A phone signed in to the same Google or Apple account joins its user by itself.`),
      section("Alerts on this phone", "bell", h("div", { class: "card list" },
        alert("doorbell", "The doorbell rings"), alert("camera", "A camera sees a person"), alert("doors", "A door or gate is opened"), alert("fridge", "The refrigerator door is left open"))),
      h("p", { class: "small-note" }, "Alerts are sealed on the controller for each phone, so DirectorLink’s servers can’t read them."),
    ];
  }
  const devicesWord = (count) => (count === 1 ? "1 device" : `${count} devices`);
  function userLine(user) {
    return [user.account ? `Signs in with ${user.account}` : "No account: home network only", devicesWord(user.devices.length)].join(" · ");
  }
  function removeDevice(user, device) {
    user.devices = user.devices.filter((item) => item.id !== device.id);
    if (user.devices.length) {
      say(`${device.name} was removed. It can no longer reach the home.`, "close");
      render();
      return;
    }
    // A user goes with their last device (ADR-061).
    home.users = home.users.filter((item) => item.id !== user.id);
    say(`${user.name} went with their last device.`, "close");
    go({ tab: "settings" });
  }
  function devicesSection(user) {
    const rows = user.devices.map((device, index) => [
      index ? h("div", { class: "divider" }) : null,
      h("div", { class: "dev-row" },
        h("span", { class: "dev-icon" }, icon("phone")),
        h("div", {}, h("div", { class: "dev-name" }, device.name), h("div", { class: "dev-sub" }, device.self ? "This device · now" : `Last used: ${device.last}`)),
        device.self ? h("span") : h("button", { class: "btn", dataset: { focus: `remove-${device.id}` }, onclick: () => removeDevice(user, device) }, "Remove")),
    ]);
    const add = h("button", { class: "music-more", dataset: { focus: `add-${user.id}` }, onclick: () => {
      if (user.devices.length >= DEVICE_LIMIT) say(`Remove a device first: up to ${DEVICE_LIMIT} devices a user.`, "close");
      else say("In the app, this shows a link and a code for the new device.", "plus");
      render();
    } }, icon("plus"), "Add a device");
    return section(`Devices (${user.devices.length} of ${DEVICE_LIMIT})`, null, h("div", { class: "card list" }, rows, add));
  }
  function userScreen(id) {
    const user = home.users.find((item) => item.id === id);
    if (!user) return [h("p", { class: "small-note" }, "This user is gone.")];
    const account = h("div", { class: "card list" },
      h("div", { class: "dev-name" }, user.account ? `Signs in with ${user.account}` : "No account"),
      h("p", { class: "small-note" }, user.account
        ? "Their devices reach the home from anywhere, sealed end to end."
        : "Their devices work on the home network only. An admin can invite their Google or Apple account for remote access."));
    if (user.role === "Admin") {
      return [
        h("div", { class: "card list" }, h("div", { class: "dev-name" }, `${user.name} is an admin`),
          h("p", { class: "small-note" }, "Admins can do everything: users, rooms, scenes, schedules and settings."),
          user.owner ? h("p", { class: "small-note" }, `${user.name} is the home’s owner. Nobody else can change their access or devices.`) : null),
        account,
        devicesSection(user),
      ];
    }
    const access = user.access;
    const toggle = (list, value) => { const i = list.indexOf(value); if (i >= 0) list.splice(i, 1); else list.push(value); render(); };
    return [
      h("p", { class: "small-note" }, `${user.name} is a member: they see and use only what you choose here, on all their devices.`),
      account,
      devicesSection(user),
      section("Rooms", "home", h("div", { class: "card" }, ROOMS.map((room) => h("label", { class: "check-row" },
        h("input", { type: "checkbox", id: `room-${id}-${room.id}`, checked: access.rooms.includes(room.id), onchange: () => toggle(access.rooms, room.id) }), room.name)))),
      section("Devices they use", "bulb", h("div", { class: "card list" }, ["Lights", "Climate", "Blinds", "Music", "Refrigerators"].map((kind) => h("div", { class: "kv" }, h("span", {}, kind),
        h("button", { class: "switch", role: "switch", "aria-checked": String(access.kinds.includes(kind)), "aria-label": kind, dataset: { focus: `kind-${id}-${kind}` }, onclick: () => toggle(access.kinds, kind) }))))),
      section("Cameras and doors", "shield", h("div", { class: "card list" },
        h("div", { class: "kv" }, h("span", {}, "Cameras in their rooms"), h("button", { class: "switch", role: "switch", "aria-checked": String(access.cameras), "aria-label": "Cameras", dataset: { focus: `cams-${id}` }, onclick: () => { access.cameras = !access.cameras; render(); } })),
        h("div", { class: "kv" }, h("span", {}, "Open doors and gates"), h("button", { class: "switch", role: "switch", "aria-checked": String(access.doors), "aria-label": "Doors and gates", dataset: { focus: `doors-${id}` }, onclick: () => { access.doors = !access.doors; render(); } })))),
    ];
  }

  // ---- Rendering --------------------------------------------------------------------------------
  const TABS = [
    { id: "home", name: "Home", icon: "home" },
    { id: "scenes", name: "Scenes", icon: "scene" },
    { id: "cameras", name: "Cameras", icon: "camera" },
    { id: "climate", name: "Climate", icon: "climate" },
    { id: "settings", name: "Settings", icon: "settings" },
  ];
  const routeKey = (r) => `${r.tab}/${r.room || ""}/${r.user || ""}`;
  let screenEl;
  let bodyEl;

  function go(next) {
    if (bodyEl) scroll.set(routeKey(route), bodyEl.scrollTop);
    route = next;
    musicPick = null;
    render(true);
  }
  function title() {
    if (route.room) return roomName(route.room);
    if (route.user) return (home.users.find((user) => user.id === route.user) || { name: "Users" }).name;
    return TABS.find((tab) => tab.id === route.tab).name;
  }
  function content() {
    if (route.room) return roomScreen(route.room);
    if (route.user) return userScreen(route.user);
    if (route.tab === "scenes") return scenesScreen();
    if (route.tab === "cameras") return camerasScreen();
    if (route.tab === "climate") return climateScreen();
    if (route.tab === "settings") return settingsScreen();
    return homeScreen();
  }
  let dragging = false;
  let pending = false;
  function render(moved) {
    if (!screenEl) return;
    if (dragging && !moved) {
      pending = true;
      return;
    }
    pending = false;
    const focused = document.activeElement && screenEl.contains(document.activeElement) ? document.activeElement.dataset.focus : null;
    const top = moved ? scroll.get(routeKey(route)) || 0 : bodyEl ? bodyEl.scrollTop : 0;
    const back = route.room || route.user;
    const head = h("header", { class: "app-head" },
      back ? h("button", { class: "app-back", "aria-label": "Back", dataset: { focus: "back" }, onclick: () => go({ tab: route.tab }) }, icon("chevronBack")) : null,
      h("h1", {}, title()), h("span", { class: "pill-ok" }, "Connected"));
    bodyEl = h("main", { class: "app-body", "aria-label": `${title()} screen` }, content());
    const tabs = h("nav", { class: "app-tabs", "aria-label": "App sections" },
      TABS.map((tab) => h("button", { class: "app-tab", "aria-current": route.tab === tab.id ? "page" : null, dataset: { focus: `tab-${tab.id}` }, onclick: () => go({ tab: tab.id }) }, icon(tab.icon), tab.name)));
    const layers = [];
    if (viewer) {
      const camera = CAMERAS.find((c) => c.id === viewer);
      layers.push(h("div", { class: "viewer", role: "dialog", "aria-label": `${camera.name}, full view` },
        h("div", { class: "viewer-head" }, h("h2", {}, camera.name), h("button", { class: "viewer-close", "aria-label": "Close", dataset: { focus: "viewer-close" }, onclick: () => { viewer = null; render(); } }, icon("close"))),
        h("img", { src: picture(camera.id, 640), alt: `${camera.name} camera picture (a drawing)`, width: "640", height: "400" }),
        h("div", { class: "viewer-foot" }, h("span", { class: "live" }, "LIVE"), h("span", { dataset: { clock: "1" } }, `${roomName(camera.room)} · ${clock()}`))));
    }
    if (toast) layers.push(h("div", { class: "toast", role: "status" }, icon(toast.icon), toast.text));
    screenEl.replaceChildren(head, bodyEl, tabs, ...layers);
    bodyEl.scrollTop = top;
    if (hintKey) {
      const target = screenEl.querySelector(`[data-key="${hintKey}"]`);
      if (target) {
        target.classList.add("hint");
        // Only the phone's screen scrolls to it, never the page around it.
        if (moved) bodyEl.scrollTop += target.getBoundingClientRect().top - bodyEl.getBoundingClientRect().top - (bodyEl.clientHeight - target.offsetHeight) / 2;
      }
    }
    if (focused) {
      const again = screenEl.querySelector(`[data-focus="${focused}"]`);
      if (again) again.focus({ preventScroll: true });
    }
  }

  // ---- The list beside the phone ----------------------------------------------------------------
  let tasksEl;
  let countEl;
  let finishEl;
  function renderTasks() {
    if (!tasksEl) return;
    const count = TASKS.filter((task) => done[task.id]).length;
    countEl.textContent = `${count} of ${TASKS.length} done`;
    tasksEl.replaceChildren(...TASKS.map((task) => h("li", { class: `task ${done[task.id] ? "is-done" : ""}` },
      h("span", { class: "task-mark", "aria-hidden": "true" }, icon("check")),
      h("div", { class: "task-text" }, h("div", { class: "task-name" }, task.name, done[task.id] ? h("span", { class: "visually-hidden" }, " (done)") : null), h("div", { class: "task-help" }, task.help)),
      h("button", { class: "task-show", "aria-label": `Show me: ${task.name}`, onclick: () => showMe(task) }, "Show me"))));
    finishEl.classList.toggle("is-all", count === TASKS.length);
    document.getElementById("demo-finish-title").textContent = count === TASKS.length ? "All six done. That’s all it takes." : "Ready for your own home?";
  }
  function showMe(task) {
    viewer = null;
    hintKey = task.hint;
    clearTimeout(showMe.timer);
    showMe.timer = setTimeout(() => {
      hintKey = null;
      const lit = screenEl.querySelector(".hint");
      if (lit) lit.classList.remove("hint");
    }, 3600);
    go(task.show);
    if (window.matchMedia("(max-width: 860px)").matches) screenEl.closest(".phone").scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function reset() {
    for (const id of timers) clearTimeout(id);
    timers.clear();
    home.blinds.forEach((item) => clearInterval(item.timer));
    home = freshHome();
    done = {};
    viewer = null;
    musicPick = null;
    toast = null;
    hintKey = null;
    scroll.clear();
    route = { tab: "home" };
    render(true);
    renderTasks();
  }

  function start() {
    screenEl = document.getElementById("demo-screen");
    tasksEl = document.getElementById("demo-tasks");
    countEl = document.getElementById("demo-count");
    finishEl = document.getElementById("demo-finish");
    if (!screenEl) return;
    document.getElementById("demo-reset").addEventListener("click", reset);
    screenEl.addEventListener("pointerdown", (event) => { if (event.target.type === "range") dragging = true; });
    const release = () => {
      if (!dragging) return;
      dragging = false;
      if (pending) setTimeout(() => render(), 0);
    };
    window.addEventListener("pointerup", release);
    window.addEventListener("pointercancel", release);
    render(true);
    renderTasks();
    setInterval(() => {
      for (const el of screenEl.querySelectorAll("[data-clock]")) el.textContent = el.textContent.replace(/\d\d:\d\d:\d\d$/, clock());
    }, 1000);
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})();
