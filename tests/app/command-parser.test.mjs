// Say or type a command (1.9.0, ADR-063): app/js/command-parser.js, the words alone. A made-up home
// with English and Hebrew names; sentences in both languages, numbers in digits and words, Hebrew
// with and without its prefixes, plural and singular, typos, names in any order, two close
// matches (a question, never a guess), unknown names and words, and what it refuses.
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import { fold, parseCommand } from "../../app/js/command-parser.js";

const ROOMS = [
  { id: 1, names: ["Kitchen", "מטבח"] },
  { id: 2, names: ["Living room", "סלון"] },
  { id: 3, names: ["Kids room", "חדר ילדים"] },
  { id: 4, names: ["Porch", "מרפסת"] },
  { id: 5, names: ["Bedroom", "חדר שינה"] },
  { id: 6, names: ["Bedroom 2"] },
  { id: 7, names: ["Sara"] },
  { id: 8, names: ["Sarah"] },
  { id: 9, names: ["חדר של שני"] },
  { id: 10, names: ["Garden", "גינה"] },
];

const light = (id, name, room, fields = {}) => ({ kind: "light", id, name, room, dimmable: true, on: false, ...fields });
const thermostat = (id, name, room, fields = {}) => ({ kind: "thermostat", id, name, room, modes: ["off", "cool", "heat", "auto"], mode: "cool", dual: false, min: 16, max: 30, ...fields });
const DEVICES = [
  light(100, "Kitchen Island", 1, { on: true }),
  light(101, "Spots", 1, { on: true }),
  light(102, "Ceiling", 2),
  light(103, "Floor lamp", 2, { dimmable: false }),
  light(104, "Heater", 2, { dimmable: false }),
  light(105, "Spots", 2),
  light(106, "Porch light", 4, { dimmable: false }),
  light(107, "Light", 5),
  light(108, "Lamp", 5),
  light(109, "Bedside", 6),
  light(110, "Ceiling", 7),
  light(111, "Ceiling", 8),
  light(112, "מנורה", 9),
  light(113, "דוד שמש", 9, { dimmable: false }),
  thermostat(200, "Living room AC", 2),
  thermostat(201, "מזגן", 3, { mode: "off", modes: ["off", "cool", "heat"] }),
  thermostat(202, "Bedroom AC", 5, { mode: "auto", dual: true }),
  { kind: "blind", id: 300, name: "Kitchen blind", room: 1, position: true },
  { kind: "blind", id: 301, name: "Window", room: 2, position: false },
  { kind: "blind", id: 302, name: "Shutter", room: 5, position: true },
  { kind: "fan", id: 400, name: "Ceiling fan", room: 3, on: false },
  { kind: "music", id: "RINCON_1", name: "Kitchen", room: 1 },
  { kind: "music", id: "RINCON_2", name: "Living Room", room: 2 },
  { kind: "relay", id: 500, name: "Main gate", room: 4, canOpen: true },
  { kind: "relay", id: 501, name: "Garden gate", room: 10, canOpen: true },
];
const SCENES = [
  { id: "aa000001", name: "Good night" },
  { id: "aa000002", name: "לילה טוב" },
  { id: "aa000003", name: "Movie time" },
];
const HOME = { rooms: ROOMS, devices: DEVICES, scenes: SCENES };

const parse = (text, catalog = HOME) => parseCommand(text, catalog);

// The action it would take, or a failure that says what came back.
function act(text, catalog = HOME) {
  const result = parse(text, catalog);
  assert.equal(result.status, "ok", `${text}: ${JSON.stringify(result)}`);
  return result.action;
}

function same(text, expected, catalog = HOME) {
  const action = act(text, catalog);
  for (const [field, value] of Object.entries(expected)) {
    const got = field === "ids" ? [...action.ids].sort() : action[field];
    assert.deepEqual(got, field === "ids" ? [...value].sort() : value, `${text}: ${field} ${JSON.stringify(action)}`);
  }
}

function problem(text, code, catalog = HOME) {
  const result = parse(text, catalog);
  assert.equal(result.status, "problem", `${text}: ${JSON.stringify(result)}`);
  assert.equal(result.problem, code, `${text}: ${JSON.stringify(result)}`);
  return result;
}

function asks(text, catalog = HOME) {
  const result = parse(text, catalog);
  assert.equal(result.status, "ask", `${text}: ${JSON.stringify(result)}`);
  return result;
}

function unknown(text, words, catalog = HOME) {
  const result = parse(text, catalog);
  assert.equal(result.status, "unknown", `${text}: ${JSON.stringify(result)}`);
  if (words) assert.deepEqual(result.words, words, text);
}

// ---- lights ------------------------------------------------------------------------------------

test("a room's lights off, in any case and word order", () => {
  for (const text of ["kitchen lights off", "Kitchen Lights OFF", "turn off the kitchen lights", "turn off the lights in the kitchen", "lights off in the kitchen", "switch the kitchen lights off"]) {
    same(text, { type: "lights", room: 1, device: null, ids: [100, 101], change: { on: false } });
  }
});

test("a room's lights to a level: digits, a percent sign or word, number words", () => {
  for (const text of ["living room lights 30%", "living room lights 30 percent", "set the living room lights to 30", "living room lights thirty percent", "dim the living room lights to 30"]) {
    // The ceiling and the spots; not the floor lamp (no dimmer) nor the heater.
    same(text, { type: "lights", room: 2, ids: [102, 105], change: { brightness: 30 } });
  }
  same("living room lights twenty-five percent", { change: { brightness: 25 } });
  same("living room lights to one hundred percent", { change: { brightness: 100 } });
  same("kitchen lights to half", { change: { brightness: 50 } });
  same("kitchen lights 0%", { ids: [100, 101], change: { on: false } });
  problem("kitchen lights 150%", "range");
  problem("dim the kitchen lights", "needLevel");
  problem("kitchen lights", "needWhat");
});

test("a light by its name, with or without its room", () => {
  same("turn on the porch light", { type: "lights", room: null, device: { kind: "light", id: 106 }, ids: [106], change: { on: true } });
  same("turn the porch light on", { device: { kind: "light", id: 106 }, change: { on: true } });
  same("porch light off", { device: { kind: "light", id: 106 }, change: { on: false } });
  // "on" before a name is a preposition.
  same("turn off the light on the porch", { device: { kind: "light", id: 106 }, change: { on: false } });
  problem("porch light 30%", "cannotDim");
  same("turn on the island in the kitchen", { device: { kind: "light", id: 100 }, change: { on: true } });
});

test("heaters wired as lights stay off unless named", () => {
  same("living room lights on", { room: 2, ids: [102, 103, 105], change: { on: true } });
  same("turn on the heater", { device: { kind: "light", id: 104 }, change: { on: true } });
  // Off is for every light, heaters too, as the room's All off.
  same("living room lights off", { ids: [102, 103, 104, 105], change: { on: false } });
  same("הדליקו את האור בחדר של שני", { room: 9, ids: [112], change: { on: true } });
});

test("a light named only by its kind is that light in its room; the plural is the room's lights", () => {
  same("bedroom light on", { device: { kind: "light", id: 107 }, ids: [107] });
  same("turn on the lamp in the bedroom", { device: { kind: "light", id: 108 }, ids: [108] });
  same("bedroom lights on", { room: 5, ids: [107, 108] });
});

test("the whole home: Turn off all for lights, AC and blinds, nothing else at once", () => {
  for (const text of ["turn off everything", "everything off", "all off", "turn everything off", "כבה הכל", "כבו הכול", "תכבו את כל הבית"]) {
    same(text, { type: "offAll", filters: ["lights", "climate"] });
  }
  same("turn off all the lights", { type: "offAll", filters: ["lights"] });
  same("lights off", { type: "offAll", filters: ["lights"] });
  same("כבו את כל האורות", { type: "offAll", filters: ["lights"] });
  same("turn off all the AC", { type: "offAll", filters: ["climate"] });
  same("close all blinds", { type: "offAll", filters: ["blinds"] });
  problem("lights on", "needRoom");
  problem("turn on all the lights", "needRoom");
  problem("open all the blinds", "needRoom");
  problem("turn off", "needRoom");
});

test("a room's All off", () => {
  same("kitchen off", { type: "roomOff", room: 1 });
  same("turn off everything in the living room", { type: "roomOff", room: 2 });
  same("כבו הכל בסלון", { type: "roomOff", room: 2 });
  problem("turn on the kitchen", "needWhat");
});

// ---- climate -----------------------------------------------------------------------------------

test("AC to a temperature, off, a mode", () => {
  same("living room AC to 23", { type: "climate", ids: [200], change: { temperature: 23 } });
  same("set the living room AC to 23.5 degrees", { ids: [200], change: { temperature: 23.5 } });
  same("living room AC twenty three", { change: { temperature: 23 } });
  same("living room AC 23 and a half", { change: { temperature: 23.5 } });
  same("living room temperature 22", { change: { temperature: 22 } });
  same("set the A/C in the living room to 22", { ids: [200], change: { temperature: 22 } });
  same("turn off the air conditioning in the living room", { ids: [200], change: { mode: "off" } });
  same("set the AC in the living room to twenty-two and a half", { change: { temperature: 22.5 } });
  same("הפעל מזגן בסלון על 24", { ids: [200], change: { temperature: 24 } });
  same("כבו את כל המזגנים", { type: "offAll", filters: ["climate"] });
  unknown("מזגן בסלון חם יותר");
  same("AC off in the kids' room", { type: "climate", ids: [201], change: { mode: "off" } });
  same("turn off the heating in the kids room", { ids: [201], change: { mode: "off" } });
  same("cool the kids room to 22", { ids: [201], change: { mode: "cool", temperature: 22 } });
  same("living room heat 21", { ids: [200], change: { mode: "heat", temperature: 21 } });
  same("living room AC auto", { ids: [200], change: { mode: "auto" } });
  // A thermostat's own range; the unit is degrees, never percent.
  const range = problem("living room ac 40", "range");
  assert.deepEqual([range.min, range.max], [16, 30]);
  unknown("living room AC 23%");
});

test("an AC that is off asks which mode; one with two setpoints in auto, which setpoint", () => {
  const mode = asks("AC on in the kids room");
  assert.equal(mode.question, "mode");
  assert.deepEqual(mode.options.map((option) => option.change), [{ mode: "cool" }, { mode: "heat" }]);
  const withTemperature = asks("kids room AC to 24");
  assert.deepEqual(withTemperature.options.map((option) => option.change), [{ mode: "cool", temperature: 24 }, { mode: "heat", temperature: 24 }]);
  const setpoint = asks("bedroom AC to 22");
  assert.equal(setpoint.question, "setpoint");
  assert.deepEqual(setpoint.options.map((option) => option.change), [{ setpoint: "cool", temperature: 22 }, { setpoint: "heat", temperature: 22 }]);
  problem("living room AC on", "alreadyOn");
  problem("kids room AC auto", "noMode");
  problem("turn on the AC", "needRoom");
});

// ---- blinds and fans ---------------------------------------------------------------------------

test("blinds open, close, to a position, stop", () => {
  same("open the kitchen blinds", { type: "blinds", room: 1, ids: [300], change: { position: 100 } });
  same("close the shades in the kitchen", { ids: [300], change: { position: 0 } });
  same("kitchen blinds 40%", { ids: [300], change: { position: 40 } });
  same("open the kitchen blinds halfway", { ids: [300], change: { position: 50 } });
  same("lower the kitchen blinds", { ids: [300], change: { position: 0 } });
  same("stop the blinds in the kitchen", { ids: [300], change: { stop: true } });
  same("open the window", { device: { kind: "blind", id: 301 }, change: { position: 100 } });
  // Open and close alone in a room are its blinds.
  same("open the kitchen", { type: "blinds", ids: [300], change: { position: 100 } });
  // The living room's window only opens and closes fully.
  problem("living room blinds 50%", "noPosition");
  problem("blinds open in the kids room", "none");
});

test("fans on and off", () => {
  same("kids room fan on", { type: "fans", ids: [400], change: { on: true } });
  same("turn off the ceiling fan", { device: { kind: "fan", id: 400 }, change: { on: false } });
});

// ---- scenes, music, doors ----------------------------------------------------------------------

test("a scene by its name, with or without a verb", () => {
  for (const text of ["run Good night", "good night", "Good Night!", "activate good night", "start the good night scene"]) same(text, { type: "scene", id: "aa000001" });
  same("start movie time", { type: "scene", id: "aa000003" });
  same("הפעל לילה טוב", { type: "scene", id: "aa000002" });
  same("הפעילו את הסצנה לילה טוב", { type: "scene", id: "aa000002" });
  // A scene the user may not run is not in their catalog.
  unknown("run party", ["party"]);
});

test("a scene whose name is a command is the scene", () => {
  const home = { ...HOME, scenes: [...SCENES, { id: "aa000009", name: "All off" }] };
  same("all off", { type: "scene", id: "aa000009" }, home);
  same("turn off everything", { type: "offAll" }, home);
});

test("music play, pause, next and volume in a room", () => {
  same("play music in the kitchen", { type: "music", ids: ["RINCON_1"], change: { action: "play" } });
  same("pause the music in the living room", { ids: ["RINCON_2"], change: { action: "pause" } });
  same("stop the music in the living room", { ids: ["RINCON_2"], change: { action: "pause" } });
  same("next song in the kitchen", { ids: ["RINCON_1"], change: { action: "next" } });
  same("kitchen volume 30", { ids: ["RINCON_1"], change: { volume: 30 } });
  same("volume 30 in the kitchen", { ids: ["RINCON_1"], change: { volume: 30 } });
  problem("play music in the porch", "none");
  problem("kitchen volume", "needLevel");
  const where = asks("play music");
  assert.deepEqual(where.options.map((option) => option.ids[0]), ["RINCON_1", "RINCON_2"]);
});

test("doors and gates: only open, only where the user may, one at a time", () => {
  same("open the main gate", { type: "door", device: { kind: "relay", id: 500 } });
  same("open the gate on the porch", { type: "door", device: { kind: "relay", id: 500 } });
  same("פתחו את השער במרפסת", { type: "door", device: { kind: "relay", id: 500 } });
  const which = asks("open the gate");
  assert.deepEqual(which.options.map((option) => option.device.id), [500, 501]);
  unknown("close the main gate");
  unknown("main gate on");
  const noDoors = { ...HOME, devices: DEVICES.map((device) => (device.kind === "relay" ? { ...device, canOpen: false } : device)) };
  problem("open the main gate", "noDoors", noDoors);
  problem("open the gate", "noDoors", noDoors);
});

// ---- Hebrew ------------------------------------------------------------------------------------

test("Hebrew: prefixes, plural and singular, imperatives for one or many", () => {
  for (const text of ["כבה את האורות במטבח", "כבו את האור במטבח", "תכבה אורות במטבח", "כיבוי אורות מטבח", "האורות במטבח כבויים"]) {
    same(text, { type: "lights", room: 1, ids: [100, 101], change: { on: false } });
  }
  same("אור בסלון 40%", { room: 2, ids: [102, 105], change: { brightness: 40 } });
  same("תדליקו את האורות בסלון", { room: 2, change: { on: true } });
  same("אורות בסלון ל-30 אחוז", { change: { brightness: 30 } });
  same("מזגן בסלון 23", { type: "climate", ids: [200], change: { temperature: 23 } });
  same("מזגן בסלון לעשרים ושלוש", { change: { temperature: 23 } });
  same("מזגן בסלון עשרים ושלוש וחצי מעלות", { change: { temperature: 23.5 } });
  same("כבה מזגן בחדר הילדים", { ids: [201], change: { mode: "off" } });
  same("מזגן בחדר ילדים על קירור 22", { ids: [201], change: { mode: "cool", temperature: 22 } });
  same("פתח את התריסים במטבח", { type: "blinds", ids: [300], change: { position: 100 } });
  same("סגרו את התריס במטבח", { ids: [300], change: { position: 0 } });
  same("תריס במטבח חצי", { ids: [300], change: { position: 50 } });
  same("נגן מוזיקה במטבח", { type: "music", ids: ["RINCON_1"], change: { action: "play" } });
  same("עצרו את המוזיקה בסלון", { ids: ["RINCON_2"], change: { action: "pause" } });
  same("ווליום 30 במטבח", { ids: ["RINCON_1"], change: { volume: 30 } });
  same("השיר הבא במטבח", { ids: ["RINCON_1"], change: { action: "next" } });
  // Niqqud and the maqaf.
  same("כַּבֵּה אֶת הָאוֹר בַּמִּטְבָּח", { room: 1, change: { on: false } });
  same("אור בסלון ל־40", { room: 2, change: { brightness: 40 } });
});

test("Hebrew: a word that is also a number stays a word in a name", () => {
  same("כבו את האור בחדר של שני", { room: 9, ids: [112, 113], change: { on: false } });
});

test("English names in a Hebrew sentence, and the other way", () => {
  same("כבה את האורות ב-Kitchen", { room: 1, change: { on: false } });
  same("living room AC off", { ids: [200], change: { mode: "off" } });
  same("סלון AC off", { ids: [200], change: { mode: "off" } });
});

// ---- forgiving, never guessing -------------------------------------------------------------------

test("small typos in names and command words", () => {
  same("kitchn lights off", { room: 1, change: { on: false } });
  same("ligths off in the kitchen", { room: 1, change: { on: false } });
  same("turn on the porch ligth", { device: { kind: "light", id: 106 } });
  same("כבה את האורות במטבך", { room: 1, change: { on: false } });
  same("livng room lights on", { room: 2 });
});

test("two names that match as well ask which one", () => {
  const spots = asks("spots on");
  assert.equal(spots.question, "which");
  assert.deepEqual(spots.options.map((option) => option.device.id).sort(), [101, 105]);
  same("kitchen spots on", { device: { kind: "light", id: 101 } });
  // One letter from Sara and from Sarah: a question.
  const close = asks("sarh ceiling on");
  assert.deepEqual(close.options.map((option) => option.device.id).sort(), [110, 111]);
  // Said exactly, Sara is Sara.
  same("sara ceiling on", { device: { kind: "light", id: 110 } });
  // Bedroom is the bedroom, not Bedroom 2; Bedroom 2 is said with its number.
  same("bedroom lights off", { room: 5 });
  same("bedroom 2 lights off", { room: 6, ids: [109] });
  same("bedroom two lights off", { room: 6 });
});

test("part of a name is asked, never done", () => {
  const island = asks("island on");
  assert.equal(island.partial, true);
  assert.deepEqual(island.options.map((option) => option.device.id), [100]);
  // Part of a name and a typo too: not understood.
  unknown("islnd on", ["islnd"]);
});

test("words it does not know, names that are not there, two things at once", () => {
  unknown("frobnicate the kitchen", ["frobnicate"]);
  unknown("make me a sandwich", ["sandwich"]);
  unknown("garage lights off", ["garage"]);
  unknown("תעשה לי קפה", ["קפה"]);
  unknown("", []);
  unknown("   ", []);
  unknown("kitchen lights on and off");
  problem("turn off the lights in the kitchen and the living room", "oneAtATime");
  problem("kitchen lights and blinds off", "oneAtATime");
});

test("a viewer's catalog has nothing to control", () => {
  const viewer = { rooms: ROOMS, devices: [], scenes: [] };
  problem("kitchen lights off", "none", viewer);
  unknown("run good night", ["good", "night"], viewer);
});

test("every sentence in the app's README is understood", async () => {
  const { readFile } = await import("node:fs/promises");
  const readme = await readFile(new URL("../../app/README.md", import.meta.url), "utf-8");
  const section = readme.slice(readme.indexOf("## Say or type a command"), readme.indexOf("## Turn off all"));
  const rows = section.split("\n").filter((line) => line.startsWith("| *"));
  const sentences = rows.flatMap((row) => [...row.split("|")[1].matchAll(/\*([^*]+)\*/g)].map((match) => match[1]));
  assert.ok(sentences.length >= 25, `${sentences.length} sentences`);
  for (const sentence of sentences) {
    const result = parse(sentence);
    // "פתחו את השער" asks which: this home has two gates.
    assert.ok(result.status === "ok" || result.status === "ask", `${sentence}: ${JSON.stringify(result)}`);
  }
});

test("folding: case, accents, niqqud and Hebrew final letters", () => {
  assert.equal(fold("Café"), "cafe");
  assert.equal(fold("סָלוֹן"), "סלונ");
  assert.equal(fold("מטבך"), "מטבכ");
});

test("fast enough for a phone in a home with 111 lights", () => {
  const rooms = Array.from({ length: 40 }, (_value, index) => ({ id: index + 1, names: [`Room ${index + 1}`, `חדר ${index + 1}`] }));
  const devices = [
    ...Array.from({ length: 111 }, (_value, index) => light(1000 + index, `Light ${index} spot`, (index % 40) + 1)),
    ...Array.from({ length: 22 }, (_value, index) => thermostat(2000 + index, `AC ${index}`, (index % 40) + 1)),
    ...Array.from({ length: 15 }, (_value, index) => ({ kind: "blind", id: 3000 + index, name: `Shade ${index}`, room: (index % 40) + 1, position: true })),
  ];
  const big = { rooms, devices, scenes: Array.from({ length: 30 }, (_value, index) => ({ id: `s${index}`, name: `Scene number ${index}` })) };
  const started = performance.now();
  for (let round = 0; round < 20; round += 1) {
    parseCommand("turn off the lights in room 12", big);
    parseCommand("מזגן בחדר 7 לעשרים ושלוש", big);
    parseCommand("open the shades in room 3", big);
  }
  const each = (performance.now() - started) / 60;
  assert.ok(each < 50, `${each.toFixed(1)} ms a command`);
  same("turn off the lights in room 12", { room: 12, change: { on: false } }, big);
});
