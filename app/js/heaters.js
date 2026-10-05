// Lights named for heating (1.10.0, ADR-066): heaters, boilers, heat lamps and floor heating wired
// as lights, such as KNX boilers kept on or off by Composer programming ("דוד הורים"). One rule for
// the whole app: a room's All off, Home's Turn off all and a command's "the lights" (on, off, a
// level, brighter or dimmer) leave them as they are; only their own switch, or a command that names
// them, changes them. Scenes and schedules keep their steps. No imports, so the rule can be tested
// under Node (tests/app/heaters.test.mjs, tests/app/command-parser.test.mjs).

const FINAL_FORMS = { "ך": "כ", "ם": "מ", "ן": "נ", "ף": "פ", "ץ": "צ" };
const HEBREW = /[א-ת]/;
const PREFIXES = "והבלמשכ";

function fold(word) {
  return String(word)
    .normalize("NFKD")
    .toLowerCase()
    .replace(/\p{M}/gu, "")
    .replace(/[ךםןףץ]/g, (letter) => FINAL_FORMS[letter]);
}

// Each a whole word, in the singular or plural ("חומה", a wall, is not "חום"; "Warm white" and
// "אור חם" are lights), and two-word names whose words alone are not ("Hot water", "מים חמים").
const HEATER_WORDS = new Set(
  (
    "heater heating heat heated radiator radiant boiler geyser immersion underfloor towel infrared convector sauna warmer " +
    "חימום חום מחמם מחממת מחממי תנור מפזר רדיאטור דוד בוילר הסקה מקרן אינפרא אינפרה קומקום סאונה"
  )
    .split(" ")
    .map(fold)
);
const HEATER_PAIRS = [["hot", "water"], ["hot", "tub"], ["מים", "חמים"]].map((pair) => pair.map(fold));

// A word without a plural ending (heaters, דודים, מחממות).
function singular(word) {
  if (/^[a-z]+$/.test(word)) return word.length > 3 && word.endsWith("s") && !word.endsWith("ss") ? word.slice(0, -1) : word;
  if (HEBREW.test(word) && word.length >= 4 && (word.endsWith("ימ") || word.endsWith("ות"))) return word.slice(0, -2);
  return word;
}

// The word, and with up to two Hebrew prefixes taken off ("החימום"), from three letters.
function forms(word) {
  const list = [word];
  if (!HEBREW.test(word)) return list;
  for (let index = 0; index < 2 && PREFIXES.includes(word[index]) && word.length - index - 1 >= 2; index += 1) {
    const form = word.slice(index + 1);
    if (form.length >= 3) list.push(form);
  }
  return list;
}

// True for a light (or a name) named for heating.
export function isHeater(device) {
  const name = typeof device === "string" ? device : device?.name;
  const words = fold(name ?? "")
    .replace(/['’‘`׳״"“”]/g, "")
    // Numbers apart from letters ("דוד2").
    .replace(/(\p{L})(?=\p{N})|(\p{N})(?=\p{L})/gu, "$1$2 ")
    .split(/[^\p{L}\p{N}]+/u)
    .filter(Boolean)
    .map(forms);
  if (words.some((list) => list.some((form) => HEATER_WORDS.has(form) || HEATER_WORDS.has(singular(form))))) return true;
  return HEATER_PAIRS.some(([one, two]) => words.some((list) => list.includes(one)) && words.some((list) => list.includes(two)));
}
