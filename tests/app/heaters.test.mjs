// Lights named for heating (1.10.0, ADR-066; app/js/heaters.js): one rule for the whole app. A
// room's All off, Home's Turn off all and a command's "the lights" leave them as they are (their
// own switch, or a command that names them, still changes them; scenes and schedules keep their
// steps). Here: which names are heaters, and that the parser, Turn off all and All off use this one
// list (tests/app/turn-off.test.mjs and command*.test.mjs check what each does with it).
//   node --test tests/app/

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { isHeater } from "../../app/js/heaters.js";

test("heaters by their usual names, in English and Hebrew, singular or plural, with prefixes", () => {
  for (const name of [
    "Heater", "Water heater", "Boiler", "Heat lamp", "Hot water", "Floor heat", "Floor heating", "Underfloor", "Immersion", "Geyser", "Towel rail", "Towel warmer",
    "Towels", "Radiator", "Infrared", "Heated floor", "Hot tub", "Sauna", "Heaters", "HEATER 2",
    "דוד", "דוד הורים", "דוד ילדים", "חימום רצפה", "מחמם מגבות", "דודים", "בוילר", "מקרן חום", "מים חמים", "החימום", "תנור", "מפזר חום", "מחממת", "רדיאטור",
    "קומקום", "דוד שמש", "הסקה", "חימום תת רצפתי", "תנור אינפרא", "דוד-הורים", "דוד2", "דּוּד",
  ]) {
    assert.equal(isHeater({ name }), true, name);
    assert.equal(isHeater(name), true, `${name} (a name alone)`);
  }
});

test("heaters by their Spanish and Italian names, singular or plural, accents or not (1.10.0, ADR-068)", () => {
  for (const name of [
    "Calentador", "Calentadores", "Termo", "Termo niños", "Termos", "Calefacción", "Calefaccion baño", "Suelo radiante", "Panel radiante", "Toallero", "Toallero eléctrico", "Calientatoallas",
    "Estufa", "Estufas", "Radiador", "Radiadores", "Caldera", "Calefactor", "Termoventilador", "Convector", "Agua caliente", "Lámpara de calor",
    "Scaldabagno", "Scaldabagni", "Boiler", "Riscaldamento", "Riscaldamento bagno", "Pavimento radiante", "Scaldasalviette", "Stufa", "Stufette", "Stufetta bagno",
    "Termosifone", "Termosifoni", "Radiatore", "Caldaia", "Termoconvettore", "Termoventilatore", "Acqua calda", "Infrarossi", "Scaldacqua",
  ]) {
    assert.equal(isHeater({ name }), true, name);
  }
});

test("lights that only sound warm are lights", () => {
  // Warm colours, and words that only go with heating ("caliente", "calda", "agua", "acqua").
  for (const name of ["Luz cálida", "Luz calida", "Blanco cálido", "Luce calda", "Bianco caldo", "Luces del techo", "Lámpara de pie", "Luci del soffitto", "Lampada da terra", "Agua", "Acqua", "Caliente", "Calda", "Termostato", "Terraza", "Terrazzo"]) {
    assert.equal(isHeater({ name }), false, name);
  }
  for (const name of ["Warm white", "אור חם", "תאורת חומה", "Hotel sign", "Water feature", "מים", "Kitchen Island", "ספוטים", "אי תלוי", "Spots", "Hot", "Dodi", "דודה", "", null]) {
    assert.equal(isHeater({ name }), false, String(name));
  }
  assert.equal(isHeater(undefined), false);
});

test("one list: the parser, Turn off all and a room's All off all ask heaters.js", async () => {
  const source = (path) => readFile(new URL(`../../app/js/${path}`, import.meta.url), "utf-8");
  for (const path of ["command-parser.js", "turn-off.js", "controls.js", "commands.js", "views/room.js"]) {
    const text = await source(path);
    assert.match(text, /import \{ isHeater \} from "\.\.?\/heaters\.js";/, `${path} imports the rule`);
    assert.doesNotMatch(text, /HEATER_WORDS|"heater heating/, `${path} keeps no list of its own`);
  }
  const sw = await readFile(new URL("../../app/sw.js", import.meta.url), "utf-8");
  assert.ok(sw.includes('"/js/heaters.js"'), "kept for offline use");
});
