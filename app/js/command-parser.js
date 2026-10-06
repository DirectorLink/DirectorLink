// Say or type a command (1.9.0, ADR-063; 1.10.0, ADR-066, ADR-068): a sentence in English, Hebrew,
// Spanish or Italian, by this user's own names of rooms, devices, scenes and Sonos rooms, becomes
// one action of the app (or two or three: "kitchen lights off and close the blinds"), a question
// (which one, which mode), a problem to say, or "I didn't understand". No AI and nothing sent
// anywhere: words, numbers and the names the app already has for this user (js/commands.js builds
// the catalog from what the controller lists for them). Its only import is heaters.js (the one rule
// for lights named for heating), so the rules can be tested under Node
// (tests/app/command-parser.test.mjs).
//
// The languages (ADR-068): English and Hebrew are read together, as in 1.9.0 (their letters never
// mix up). Spanish and Italian each have their own words, read only when the app is in that
// language, and first: then English and Hebrew only when the app's language understood nothing in
// the sentence (a refusal in it stands), so a Spanish or Italian sentence is never read as English
// words, nor the other way. The user's names count in every language.
//
// parseCommand(text, catalog, { language }) answers one of:
//   { status: "ok", action }                     do it (doors, Turn off all and scenes that open
//                                                doors still get their second tap: commands.js)
//   { status: "ok", actions }                    two or three things, each understood; all of them
//                                                are done (each second tap still its own)
//   { status: "ask", options: [action], partial } which one; nothing is done until one is chosen.
//                                                `partial`: only part of a name was said ("Did you
//                                                mean"), so even one match is asked
//   { status: "problem", problem, ... }          understood, but it cannot be done as said
//   { status: "unknown", words, refusal }        not understood; `words` it does not know (or none);
//                                                `refusal` (not, time, feel) when it says not to,
//                                                names a time or a change by an amount, or how warm
//                                                the user feels: then nothing else counts either
//                                                (not the speech service's other guesses)
// In a sentence of several parts, a part that is not understood, asks or is refused makes the
// whole sentence that answer, with `part` (its words): nothing is done (an ask becomes the problem
// "partAsks", with its question and options to name).
//
// The catalog: { rooms: [{ id, names }], scenes: [{ id, name }], devices: [{ kind, id, name, room,
// ... }] }, the kinds: light (dimmable, on), thermostat (modes, mode, dual, min, max), blind
// (position: it can stop between open and closed), fan (on), music (a Sonos room, its id a string),
// relay and doorbell (doors and gates; canOpen).
//
// An action: { type, ids, change, room, device, kept }. type: lights | climate | blinds | fans |
// music (`ids` of that kind's devices, `change` what they get: also a step from where each one is,
// brightnessBy, temperatureBy, volumeBy), scene (`id`), door (`device`), roomOff (`room`: the
// room's All off) or offAll (`filters`: Home's Turn off all for lights, climate or blinds). `room`
// is the room named, `device` ({ kind, id }) the device named, for the words shown; `kept` the
// lights named for heating that "the lights" left out (heaters.js), to say so.

import { isHeater } from "./heaters.js";

// ---- words ---------------------------------------------------------------------------------

const FINAL_FORMS = { "ך": "כ", "ם": "מ", "ן": "נ", "ף": "פ", "ץ": "צ" };

// Lower case, without accents, niqqud and Hebrew final forms: what words are compared by.
export function fold(word) {
  return String(word)
    .normalize("NFKD")
    .toLowerCase()
    .replace(/\p{M}/gu, "")
    .replace(/[ךםןףץ]/g, (letter) => FINAL_FORMS[letter]);
}

const HEBREW = /[א-ת]/;
const PREFIXES = "והבלמשכ";

// The word without a plural ending (lights, אורות) or a Hebrew feminine one (מנורה). Two Hebrew
// plurals, ים and ות, are not the same form of a word (בנים, בנות: sameForm).
function stem(word) {
  if (/^[a-z]+$/.test(word)) {
    if (word.length > 4 && word.endsWith("ies")) return `${word.slice(0, -3)}y`;
    if (word.length > 3 && word.endsWith("s") && !word.endsWith("ss")) return word.slice(0, -1);
    return word;
  }
  if (HEBREW.test(word) && word.length >= 4) {
    if (word.endsWith("ימ") || word.endsWith("ות")) return word.slice(0, -2);
    if (word.endsWith("ה")) return word.slice(0, -1);
  }
  return word;
}

const hebrewPlural = (word) => (HEBREW.test(word) && word.length >= 4 ? (word.endsWith("ימ") ? "ימ" : word.endsWith("ות") ? "ות" : null) : null);

// Two forms of one word: the same without their endings, unless one is a masculine plural and the
// other a feminine one (בנים, boys, is not בנות, girls).
function sameForm(a, b) {
  if (stem(a) !== stem(b)) return spanishPlural(a, b) || spanishPlural(b, a);
  const one = hebrewPlural(a);
  const other = hebrewPlural(b);
  return !one || !other || one === other;
}

// The Spanish plural of a word that ends in a consonant: salón, salones; luz, luces.
function spanishPlural(one, other) {
  if (!/^[a-z]+$/.test(one) || other.length !== one.length + 2 || !other.endsWith("es")) return false;
  if (one.endsWith("z")) return other === `${one.slice(0, -1)}ces`;
  return /[lnrdjy]$/.test(one) && other === `${one}es`;
}

// Two Spanish or Italian words that differ only in the vowel of gender or number at their end
// (niños, niñas; bambini, bambine; nonno, nonna): often two names, so said for one it is asked,
// as the other Hebrew plural is.
function otherEnding(a, b) {
  if (!a || !b || a.length !== b.length || a.length < 4 || !/^[a-z]+$/.test(a) || !/^[a-z]+$/.test(b)) return false;
  const end = a.endsWith("s") && b.endsWith("s") ? a.length - 2 : a.length - 1;
  if (a.slice(0, end) !== b.slice(0, end) || a.slice(end + 1) !== b.slice(end + 1)) return false;
  const pair = [a[end], b[end]].sort().join("");
  return pair === "ao" || pair === "ei";
}

// Hebrew spelled with one vowel letter (י, ו) more or less, or doubled, not first or last: חניה,
// חנייה; כניסה, כנסה; מטבח, מיטבח. Only for a name's word of four letters or more. "sure" when the
// shorter has four letters too; with three (גנה for גינה, also דנה for דינה) it is only a typo.
function spelling(name, said) {
  if (!HEBREW.test(name) || !HEBREW.test(said) || name.length < 4 || said.length < 3 || Math.abs(name.length - said.length) !== 1) return null;
  const [long, short] = name.length > said.length ? [name, said] : [said, name];
  for (let index = 1; index < long.length - 1; index += 1) {
    if ((long[index] === "י" || long[index] === "ו") && long.slice(0, index) + long.slice(index + 1) === short) return short.length >= 4 ? "sure" : "typo";
  }
  return null;
}

// A Hebrew word said with up to two of its prefixes taken off (ו, ה, ב, ל, מ, ש, כ: "ובסלון" is
// also "בסלון" and "סלון"), the word itself first. A word of a name keeps its own letters: only its
// article may be left out ("חדר הילדים" said "חדר ילדים"), so that "בני" is not "שני".
function bareForms(word, name = false) {
  const forms = [word];
  if (!HEBREW.test(word)) return forms;
  if (name) return word.startsWith("ה") && word.length >= 4 ? [word, word.slice(1)] : forms;
  for (let index = 0; index < 2 && PREFIXES.includes(word[index]) && word.length - index - 1 >= 2; index += 1) {
    forms.push(word.slice(index + 1));
  }
  return forms;
}

// A sentence in words: numbers apart from letters ("ל-23", "30%"), a decimal point kept.
function split(text) {
  return String(text ?? "")
    .normalize("NFC")
    // Italian elisions are two words: "l'aria", "dell'ingresso", "all'una", "mezz'ora".
    .replace(/\b(l|dell|all|nell|sull|dall|coll|un|quest|quell|c|d|tutt|mezz)['’‘`](?=\p{L})/giu, "$1 ")
    .replace(/['’‘`׳״"“”]/g, "")
    // Percent in words: "por ciento", "per cento", "cien por cien", "per cent".
    .replace(/\b(?:por|per)\s+(?:ciento|cien|cento|cent)\b/giu, " % ")
    // "A/C", "a.c." are AC.
    .replace(/\ba[./]c\b\.?/gi, "ac")
    // Degrees Celsius: "23°C", "23 °C", "23C", "23º", "23℃".
    .replace(/[º˚℃]/g, "°")
    .replace(/(\d)\s*°?\s*c(?![\p{L}\p{N}])/giu, "$1°")
    .replace(/(\d)[.,](\d)/g, "$1\u0001$2")
    // A minus sign before a number ("-18"), not a hyphen after a word ("ל-23").
    .replace(/(^|\s)[-−‐–](?=\d)/g, "$1\u0002")
    .replace(/[%°]/g, " $& ")
    // A comma or a semicolon may part two things said ("kitchen lights off, AC to 23").
    .replace(/[,;،]/g, " \u0003 ")
    .replace(/(\p{L})(?=\p{N})|(\p{N})(?=\p{L})/gu, "$1$2 ")
    .replace(/[^\p{L}\p{M}\p{N}\u0001\u0002\u0003%°]+/gu, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map((word) => word.replace(/\u0001/g, ".").replace(/\u0002/g, "-").replace(/\u0003/g, ","));
}

function word(display, name = false) {
  const raw = fold(display);
  const bares = bareForms(raw, name);
  return { display, raw, stem: stem(raw), bares, stems: [...new Set(bares.map(stem))], num: /^-?\d+(\.\d+)?$/.test(raw) ? Number(raw) : null };
}

// What words mean: role, and for kinds of devices, which kind and whether the word is plural (or
// says "all of them": lighting, מיזוג). Hebrew verbs in the forms people say and type: the
// imperative, the future and the infinitive, for one or more.
const VOCABULARY = [
  ["on", "on הדלק הדליקי הדליקו תדליק תדליקי תדליקו להדליק דלוק דלוקה דלוקים דולק דולקת דולקים הדלקה"],
  ["off", "off out deactivate disable כבה כבי כבו תכבה תכבי תכבו לכבות כבוי כבויה כבויים כיבוי"],
  ["open", "open פתח פתחי פתחו תפתח תפתחי תפתחו לפתוח פתוח פתוחה פתוחים פתיחה"],
  ["close", "close shut סגור סגרי סגרו תסגור תסגרי תסגרו לסגור סגורה סגורים סגירה"],
  ["up", "up raise הרם הרימי הרימו תרים תרימי תרימו להרים העלה העלי העלו תעלה תעלי תעלו להעלות"],
  ["down", "down lower הורד הורידי הורידו תוריד תורידי תורידו להוריד"],
  ["stop", "stop halt עצור עצרי עצרו תעצור תעצרי תעצרו לעצור עצירה הפסק הפסיקי הפסיקו תפסיק תפסיקי תפסיקו להפסיק"],
  ["start", "start activate הפעל הפעילי הפעילו תפעיל תפעילי תפעילו להפעיל הפעלה התחל התחילי התחילו תתחיל"],
  ["run", "run scene trigger הרץ הריצי הריצו תריץ תריצי תריצו להריץ סצנה סצינה סצנת סצינת תרחיש"],
  ["play", "play resume unpause continue נגן נגני נגנו תנגן תנגני תנגנו לנגן השמע השמיעי השמיעו תשמיע תשמיעי תשמיעו להשמיע המשך המשיכי המשיכו תמשיך"],
  ["pause", "pause השהה השהי השהו תשהה להשהות השהיה"],
  ["next", "next skip הבא הבאה דלג דלגי דלגו תדלג לדלג"],
  ["volume", "volume vol loudness ווליום וליום עוצמה עוצמת"],
  ["level", "dim brightness level בהירות עמעם עמעמי עמעמו תעמעם לעמעם"],
  ["cool", "cool cooling קירור לקרר"],
  ["heat", "heat heating חימום לחמם"],
  ["auto", "auto automatic אוטומטי אוטו"],
  ["percent", "percent pct % אחוז אחוזים"],
  ["degrees", "degree degrees deg ° celsius מעלה מעלות צלזיוס"],
  ["all", "all every each כל"],
  ["everything", "everything הכל הכול כולם כולן"],
  // Not a command: "don't", a question, a time or a change by an amount (DirectorLink does it now,
  // as said, or not at all).
  ["not", "not dont never אל לא אין בלי ואל ולא שלא ושלא"],
  ["question", "is are what whats how which does did why when where who האם מה למה מתי איפה איך מי כמה"],
  ["time", "am pm oclock minute minutes hour hours seconds tomorrow tonight morning evening afternoon later until till after before within דקה דקות שעה שעות שנייה שניות מחר בוקר ערב צהריים עוד אחרי לפני"],
  [
    "filler",
    "the a an in at to into of my our your please now hey can could would will you i me want it its be for with and set turn switch make put change adjust room house home whole entire also just then thanks thank kindly air mode , " +
      "את של על עם ב ה ל ו מ ש כ בבקשה אנא נא לי עכשיו גם רק עד חדר בית אוויר אויר שים שימי שימו תשים תשימי תשימו כוון כווני כוונו תכוון תכווני תכוונו לכוון קבע קבעי קבעו תקבע תקבעי תקבעו שנה תשנה העבר תעביר עשה עשי עשו תעשה תעשי תעשו הגדר תגדיר אפשר תוכל מצב וגם ואז ואת אז",
  ],
];
// A change by a step from where each device is (1.10.0, ADR-066), only with these words: a kind
// (or, for increase and decrease, a light or the music said), and up (1) or down (-1). A comparative
// may take an amount said next to it ("2 degrees warmer").
const RELATIVE = [
  ["light", 1, "brighter brighten", true],
  ["light", -1, "dimmer darker", true],
  ["climate", 1, "warmer hotter", true],
  ["climate", -1, "cooler colder", true],
  ["music", 1, "louder", true],
  ["music", -1, "quieter softer", true],
  [null, 1, "increase הגבר הגבירי הגבירו תגביר תגבירי תגבירו להגביר הגברה", false],
  [null, -1, "decrease reduce הנמך הנמיכי הנמיכו תנמיך תנמיכי תנמיכו להנמיך הנמכה", false],
];
// Words that make a change by a step only with the words above ("more light", "יותר חם", "a bit
// brighter", "by 20%", "ב-2 מעלות"); alone they are a change by an amount, which is not done
// (a time role, as in 1.9.0: "more", "by 20%").
const MODIFIERS = [
  ["more", "more יותר"],
  ["less", "less פחות"],
  ["bit", "bit little slightly קצת טיפה"],
  ["by", "by"],
];
// How warm the user feels ("I'm cold", "חם לי") is not what the AC should do: a mode only right
// after "on", "to" or "על" in a sentence that names the AC ("מזגן על קר", "set the AC to warm").
const FEELINGS = [
  ["cool", "cold chilly freezing קר קרה קרים"],
  ["heat", "warm hot חם חמה חמים"],
];
// Before a number, these make it a time, not a level or a temperature, unless a unit follows
// ("at 7", "in 5", "עד 7"; "at 50%" is a level).
const AT_WORDS = new Set(["at", "in", "for", "until", "till", "עד"]);
// A number with ב or מ in front ("ב-7", "בשבע", "ב-20%", "מ-7") is a time or a change by that
// much, never a level.
const AT_PREFIX = /^[וש]?[במ]$/;
const KIND_WORDS = [
  ["light", "light lamp bulb אור מנורה מנורת נורה נורת", "lights lamps lighting bulbs אורות תאורה תאורת מנורות נורות"],
  ["climate", "ac aircon airco thermostat temperature temp conditioner אירקון מזגן תרמוסטט טמפרטורה טמפרטורת", "acs climate thermostats hvac conditioning מזגנים מיזוג"],
  ["blind", "blind shade shutter curtain drape roller תריס וילון תריסול", "blinds shades shutters curtains drapes rollers תריסים וילונות הצללה"],
  ["fan", "fan מאוורר מאורר", "fans מאווררים"],
  ["music", "song track speaker שיר רמקול", "music songs speakers sonos audio radio מוזיקה מוסיקה שירים רמקולים סונוס רדיו"],
  ["door", "door gate דלת שער", "doors gates דלתות שערים"],
];
// The words for an AC itself (not a thermostat, temperature or climate): a room's AC is its
// thermostats that cool, not its floor heating.
const AC_WORDS = new Set("ac aircon airco conditioner אירקון מזגן acs conditioning מזגנים מיזוג".split(" "));

const ROLES = new Map(); // folded word -> { role, kind?, plural? }
const ROLE_STEMS = new Map(); // its stem -> the same
for (const [role, list] of VOCABULARY) {
  for (const entry of list.split(" ")) ROLES.set(fold(entry), { role });
}
for (const [kind, singular, plural] of KIND_WORDS) {
  for (const entry of singular.split(" ")) ROLES.set(fold(entry), { role: "kind", kind, plural: false, ac: AC_WORDS.has(entry) });
  for (const entry of plural.split(" ")) ROLES.set(fold(entry), { role: "kind", kind, plural: true, ac: AC_WORDS.has(entry) });
}
for (const [mode, list] of FEELINGS) {
  for (const entry of list.split(" ")) ROLES.set(fold(entry), { role: "feel", mode });
}
for (const [kind, dir, list, comparative] of RELATIVE) {
  for (const entry of list.split(" ")) ROLES.set(fold(entry), { role: "rel", kind, dir, comparative });
}
for (const [modifier, list] of MODIFIERS) {
  for (const entry of list.split(" ")) ROLES.set(fold(entry), { role: "time", modifier });
}
for (const [key, value] of ROLES) if (!ROLE_STEMS.has(stem(key))) ROLE_STEMS.set(stem(key), value);
// Words close enough to a command word to be a typo of it (6 letters or more, never a filler:
// "night" is not a typo of "light").
const FUZZY_ROLES = [...ROLES].filter(([key, value]) => key.length >= 6 && value.role !== "filler");

// "Dim" with a step ("dim the lights a bit", "by 20%") is dimmer; alone, a level to say.
const DIM_WORDS = new Set("dim עמעם עמעמי עמעמו תעמעם תעמעמי תעמעמו לעמעם".split(" ").map(fold));
// "Make it warmer": a climate comparative needs the AC said, or one of these.
const MAKE_WORDS = new Set("make תעשה תעשי תעשו עשה עשי עשו".split(" ").map(fold));
// Said with these, a climate comparative is how the user feels ("I'm colder", "יותר חם לי").
const FEEL_MARKERS = new Set("i im me feel feels feeling felt לי מרגיש מרגישה מרגישים מרגישות".split(" ").map(fold));
// A number right after these is a level, a temperature or a time, never an amount.
const TARGET_WORDS = new Set("to at in for until till into על ל עד".split(" ").map(fold));
const FILLER = { role: "filler" };

// ---- numbers -------------------------------------------------------------------------------

const NUMBER_WORDS = new Map();
function numberWords(list, value, type) {
  for (const entry of list.split(" ")) NUMBER_WORDS.set(fold(entry), { value, type });
}
numberWords("zero אפס", 0, "unit");
numberWords("one אחת אחד", 1, "unit");
numberWords("two שתיים שתים שניים שנים שתי שני", 2, "unit");
numberWords("three שלוש שלושה שלש שלשה", 3, "unit");
numberWords("four ארבע ארבעה", 4, "unit");
numberWords("five חמש חמישה חמשה", 5, "unit");
numberWords("six שש שישה ששה", 6, "unit");
numberWords("seven שבע שבעה", 7, "unit");
numberWords("eight שמונה", 8, "unit");
numberWords("nine תשע תשעה", 9, "unit");
numberWords("ten", 10, "teen");
numberWords("עשר עשרה", 10, "ten");
["eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"].forEach((entry, index) => numberWords(entry, 11 + index, "teen"));
numberWords("twenty עשרים", 20, "tens");
numberWords("thirty שלושים שלשים", 30, "tens");
numberWords("forty fourty ארבעים", 40, "tens");
numberWords("fifty חמישים חמשים", 50, "tens");
numberWords("sixty שישים ששים", 60, "tens");
numberWords("seventy שבעים", 70, "tens");
numberWords("eighty שמונים", 80, "tens");
numberWords("ninety תשעים", 90, "tens");
numberWords("hundred מאה", 100, "hundred");
numberWords("half halfway חצי", 50, "half");

// A number word, and the prefixes said before it ("בשבע": ב).
function numberWord(token) {
  if (!token || token.num !== null) return null;
  for (const form of token.bares) {
    const found = NUMBER_WORDS.get(form);
    if (found) return { ...found, prefix: token.raw.slice(0, token.raw.length - form.length) };
  }
  return null;
}

const isHalf = (token) => token && (token.raw === "half" || token.bares.includes("חצי"));
const isUnit = (token) => Boolean(token?.bares.some((form) => ["percent", "degrees"].includes(ROLES.get(form)?.role)));

// The number that starts at tokens[index] (digits, or words: "twenty three", "עשרים ושלוש",
// "שלוש עשרה", "23 and a half", "23 וחצי"), and where it ends; null when none starts there.
function readNumber(tokens, index, names) {
  const first = tokens[index];
  let value = null;
  let prefix = "";
  let end = index + 1;
  if (first.num !== null) {
    value = first.num;
  } else {
    // A number word that is also in a name stays a word ("שני", a name too).
    const found = names.has(first.stem) ? null : numberWord(first);
    if (!found) return null;
    const next = numberWord(tokens[end]);
    if (found.type === "half") return { value: 50, end, prefix: found.prefix, half: true };
    value = found.value;
    prefix = found.prefix;
    if (found.type === "tens" && next?.type === "unit" && next.value > 0) {
      value += next.value;
      end += 1;
    } else if (found.type === "unit" && next?.type === "ten") {
      value += 10;
      end += 1;
    } else if (found.type === "unit" && next?.type === "hundred") {
      value *= 100;
      end += 1;
    } else if (found.type === "unit" && !isUnit(tokens[end])) {
      // "One of the lights", "שתי מנורות": a word from one to nine is a number only with its
      // unit ("five percent"); digits always are.
      return null;
    }
  }
  // "and a half", "וחצי"
  const and = tokens[end]?.raw === "and" ? 1 : 0;
  const a = tokens[end + and]?.raw === "a" ? 1 : 0;
  if (isHalf(tokens[end + and + a]) && (and || tokens[end].raw.startsWith("ו"))) {
    value += 0.5;
    end += and + a + 1;
  }
  return { value, end, prefix };
}

// The sentence as tokens: words and numbers. A number says `at`: "by" with ב or מ in front of it
// ("ב-7", "בעשר", "ב-20%": a time or a change by that much), "at" after at, in, for, until, עד (a
// time, unless a unit follows: "at 50%").
function tokenize(text, names) {
  const words = split(text).map((display) => word(display));
  const tokens = [];
  for (let index = 0; index < words.length; ) {
    const number = readNumber(words, index, names);
    if (number) {
      const display = words.slice(index, number.end).map((item) => item.display).join(" ");
      const before = words[index - 1];
      const prefix = AT_PREFIX.test(number.prefix) ? number.prefix : before && AT_PREFIX.test(before.raw) ? before.raw : null;
      const at = prefix ? "by" : before && AT_WORDS.has(before.raw) ? "at" : null;
      // `byPrefix`: ב ("by 2 degrees" with a change by a step) or מ ("from": never an amount).
      tokens.push({ ...word(display), raw: `#${number.value}`, stem: "", bares: [], stems: [], num: number.value, digits: words[index].num !== null && number.end === index + 1, at, byPrefix: prefix ? prefix.slice(-1) : null, half: Boolean(number.half) });
      index = number.end;
    } else {
      // A number word kept as a word still matches a number in a name ("Bedroom two"); with ב or
      // מ in front ("בשבע") it is a time, unless it is in a name ("בשני").
      const found = numberWord(words[index]);
      const atWord = Boolean(found && AT_PREFIX.test(found.prefix));
      tokens.push(found && found.type !== "half" ? { ...words[index], wordNum: found.value, atWord } : found ? { ...words[index], atWord } : words[index]);
      index += 1;
    }
  }
  return tokens;
}

// ---- comparing names ------------------------------------------------------------------------

// Optimal string alignment distance (a swap of two letters is one), or more than `limit`.
function distance(a, b, limit) {
  if (Math.abs(a.length - b.length) > limit) return limit + 1;
  let before = null;
  let previous = Array.from({ length: b.length + 1 }, (_value, index) => index);
  for (let i = 1; i <= a.length; i += 1) {
    const row = [i];
    for (let j = 1; j <= b.length; j += 1) {
      const cost = a[i - 1] === b[j - 1] ? 0 : 1;
      row[j] = Math.min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + cost);
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) row[j] = Math.min(row[j], before[j - 2] + 1);
    }
    before = previous;
    previous = row;
  }
  return previous[b.length];
}

// Typos allowed: none in words of three letters or fewer, one from four, two from eight.
function typosAllowed(a, b) {
  const length = Math.min(a.length, b.length);
  return length >= 8 ? 2 : length >= 4 ? 1 : 0;
}

function closeEnough(a, b) {
  const limit = typosAllowed(a, b);
  return limit > 0 && distance(a, b, limit) <= limit;
}

function roleOf(token, names) {
  if (token.num !== null) return null;
  // "בשבע", "בעשר": at seven, at ten.
  if (token.atWord && !token.bares.some((form) => names.has(stem(form)))) return { role: "time" };
  for (const [index, form] of token.bares.entries()) {
    // With its prefixes off, a command word of three letters or more ("בבוקר" is not "קר"), and
    // כל ("בכל הבית").
    if (index > 0 && form.length < 3 && form !== "כל") continue;
    const found = ROLES.get(form) || ROLE_STEMS.get(stem(form));
    if (found) return found;
  }
  // A typo of one letter in a command word ("ligths"), unless the word is in one of the names
  // ("deactivate" is two from "activate": not a typo of it).
  if (names.has(token.stem) || token.raw.length < 6) return null;
  for (const [key, value] of FUZZY_ROLES) {
    if (distance(token.raw, key, 1) <= 1) return value;
  }
  return null;
}

// How well a word of a name matches a word said: 1 the same, 0.95 another form (plural), 0.9
// with a Hebrew prefix or another Hebrew spelling (חנייה for חניה), 0.75 a small typo (never
// against a command word; also the other Hebrew plural, בנים for בנות), 0 not at all.
function quality(part, token, exactOnly) {
  if (token.num !== null) return part.num !== null && part.num === token.num ? 1 : 0;
  if (part.num !== null) return token.wordNum === part.num ? 1 : 0;
  if (part.raw === token.raw) return 1;
  if (exactOnly) return part.bares.some((form) => token.bares.includes(form)) ? 0.9 : 0;
  if (sameForm(part.raw, token.raw)) return 0.95;
  if (part.bares.some((form) => token.bares.some((said) => sameForm(form, said)))) return 0.9;
  if (token.role) return 0;
  const spelled = part.bares.flatMap((form) => token.bares.map((said) => spelling(form, said)));
  if (spelled.includes("sure")) return 0.9;
  if (spelled.includes("typo") || token.stems.some((form) => closeEnough(part.stem, form))) return 0.75;
  // The other Hebrew plural of the same word.
  if (part.bares.some((form) => token.bares.some((said) => stem(form) === stem(said)))) return 0.75;
  return 0;
}

// ---- the catalog ----------------------------------------------------------------------------

const KIND_OF = { light: "light", thermostat: "climate", blind: "blind", fan: "fan", music: "music", relay: "door", doorbell: "door" };

// A name as words. In a device's or room's name, words for kinds of devices and fillers ("Porch
// light", "חדר שינה") need not be said; a name made only of such words ("Light", "מזגן") must be
// said word for word, and only with its room.
function nameParts(name, type) {
  const parts = split(name)
    .map((display) => word(display, true))
    .map((part) => ({ ...part, role: part.num !== null ? null : ROLES.get(part.raw) || ROLE_STEMS.get(part.stem) || null }));
  for (const part of parts) {
    part.optional = part.role ? part.role.role === "filler" || (type !== "scene" && part.role.role === "kind") : false;
  }
  let exactOnly = false;
  if (parts.length && parts.every((part) => part.optional)) {
    exactOnly = true;
    const kinds = parts.filter((part) => part.role?.role === "kind");
    for (const part of kinds.length ? kinds : parts) part.optional = false;
  }
  return { parts, exactOnly, required: parts.filter((part) => !part.optional).length };
}

const prepared = new WeakMap();

function prepare(catalog) {
  if (prepared.has(catalog)) return prepared.get(catalog);
  const entities = [];
  for (const room of catalog.rooms || []) {
    for (const name of new Set((room.names || []).filter(Boolean))) entities.push({ type: "room", room, ...nameParts(name, "room") });
  }
  for (const device of catalog.devices || []) {
    if (device.name) entities.push({ type: "device", device, kind: KIND_OF[device.kind], ...nameParts(device.name, "device") });
  }
  for (const scene of catalog.scenes || []) {
    if (scene.name) entities.push({ type: "scene", scene, ...nameParts(scene.name, "scene") });
  }
  const names = new Set(entities.flatMap((entity) => entity.parts.map((part) => part.stem)));
  const value = { entities, names };
  prepared.set(catalog, value);
  return value;
}

// The best way the entity's name lies in the sentence: which tokens, how well, whether all of it.
// Only the words that must be said are placed (a name's kind and fillers may be left over: they
// mean the same there), each at one of its four best places, so a long name stays quick.
function matchEntity(entity, tokens) {
  const parts = entity.parts.filter((part) => !part.optional);
  const candidates = parts.map((part) =>
    tokens
      .map((token, position) => [position, quality(part, token, entity.exactOnly)])
      .filter(([, q]) => q > 0)
      .sort((a, b) => b[1] - a[1])
      .slice(0, 4)
  );
  if (!candidates.some((list) => list.length)) return null;
  let best = null;
  const used = [];
  // A name of many words that each appear often stops looking after this many steps.
  let steps = 0;
  const walk = (index, score, sure) => {
    steps += 1;
    if (steps > 5000) return;
    if (index === parts.length) {
      if (!used.length) return;
      const full = used.length === parts.length;
      const rank = (full ? 100 : 0) + score;
      if (!best || rank > best.rank) best = { rank, full, score, sure, positions: used.map(([position]) => position) };
      return;
    }
    for (const [position, q] of candidates[index]) {
      if (used.some(([taken]) => taken === position)) continue;
      used.push([position, q]);
      walk(index + 1, score + q, sure || (q >= 0.9 && parts[index].num === null));
      used.pop();
    }
    walk(index + 1, score, sure);
  };
  walk(0, 0, false);
  if (!best) return null;
  // A name said only with a typo in a word under six letters (Dana for Dina, בנים for בנות): one
  // letter there is often another name, so it is asked ("Did you mean"), never done.
  const unsure = best.full && !best.sure && parts.some((part, index) => part.num === null && part.raw.length < 6 && quality(part, tokens[best.positions[index]], entity.exactOnly) < 0.9);
  if (!best.full) {
    // Part of a name: never by a typo or a number alone, never only by command words, never a name
    // said word for word.
    if (entity.exactOnly || !best.sure || !best.positions.some((position) => !tokens[position].role && tokens[position].num === null)) return null;
  }
  // A word of the name that need not be said, said with a typo ("porch ligth"), is the name's too.
  const positions = new Set(best.positions);
  for (const part of entity.parts) {
    if (!part.optional) continue;
    const position = tokens.findIndex((token, index) => !positions.has(index) && !token.role && token.num === null && quality(part, token, false) > 0);
    if (position >= 0) positions.add(position);
  }
  return { entity, full: best.full, unsure, score: best.score, positions };
}

// ---- what the sentence asks ------------------------------------------------------------------

const MAX_OPTIONS = 6;
const TIE = 0.05;
// A change by a step: lights 20 points, the AC 1°, the music 10, unless an amount is said
// ("by 30%", "2 degrees warmer"); the AC at most 10° at once.
const LIGHT_STEP = 20;
const DEGREE_STEP = 1;
const MUSIC_STEP = 10;
const MAX_DEGREE_STEP = 10;

function devicesOf(catalog, kind, roomId = undefined) {
  return (catalog.devices || []).filter((device) => KIND_OF[device.kind] === kind && (roomId === undefined || device.room === roomId));
}

const action = (type, fields) => ({ status: "ok", action: { type, room: null, device: null, ...fields } });
const problem = (code, fields = {}) => ({ status: "problem", problem: code, ...fields });

// A number that is a time or a change by an amount ("at 7", "ב-7", "ב-20%"), not a level.
function timeNumber(tokens, position) {
  const token = tokens[position];
  if (token.at === "by") return true;
  if (token.at !== "at" || token.half) return false;
  return !["percent", "degrees"].includes(tokens[position + 1]?.role?.role);
}

// What makes a sentence not a command to do now, at that word: "not" (don't, אל), "time" (a time,
// a change by an amount), "feel" (I'm cold, חם לי); null for any other word.
function refusalOf(tokens, position) {
  const token = tokens[position];
  if (token.carried) return null;
  if (token.num !== null) return timeNumber(tokens, position) ? "time" : null;
  const role = token.role?.role;
  return role === "not" || role === "time" || role === "feel" ? role : null;
}

const isDim = (token) => token.role?.role === "level" && token.bares.some((form) => DIM_WORDS.has(form));
const isMarker = (token) => ["rel", "up", "down"].includes(token.role?.role) || isDim(token);

// A change by a step, said with its words (1.10.0, ADR-066): "more light", "יותר חם", "a bit
// brighter", "dim … a bit", "by 20%", "ב-2 מעלות", "2 degrees warmer". The words that make it are
// given the role "rel" (a kind and a direction), an amount said with them is marked, and what is
// left of "more", "less", "a bit" and "by" stays a change by an amount that is not done.
function relativeRoles(tokens) {
  for (const [position, token] of tokens.entries()) {
    const modifier = token.role?.modifier;
    if (modifier !== "more" && modifier !== "less") continue;
    const sign = modifier === "more" ? 1 : -1;
    const next = tokens[position + 1];
    // "more light", "פחות אור": right before a word for light.
    if (next?.role?.role === "kind" && next.role.kind === "light") {
      token.role = { role: "rel", kind: "light", dir: sign, comparative: true };
      continue;
    }
    // "יותר חם", "קר יותר": the AC warmer or cooler (a sentence that names the AC: intent).
    if (!HEBREW.test(token.raw)) continue;
    const feel = [next, tokens[position - 1]].find((other) => other?.role?.role === "feel");
    if (!feel) continue;
    token.role = { role: "rel", kind: "climate", dir: sign * (feel.role.mode === "heat" ? 1 : -1), comparative: true };
    feel.role = FILLER;
  }
  // An amount: a number with its unit, said with "by" or ב ("by 20%", "ב-2 מעלות"), or next to a
  // comparative ("2 degrees warmer"), and only with a word for a change by a step.
  if (tokens.some(isMarker)) {
    const comparative = tokens.some((token) => token.role?.role === "rel" && token.role.comparative);
    for (const [position, token] of tokens.entries()) {
      const unit = tokens[position + 1]?.role?.role;
      if (token.num === null || token.carried || (unit !== "percent" && unit !== "degrees")) continue;
      const before = tokens[position - 1];
      const byWord = before?.role?.modifier === "by";
      const byPrefix = token.at === "by" && token.byPrefix === "ב";
      const near = comparative && token.at === null && !TARGET_WORDS.has(before?.raw);
      if (!byWord && !byPrefix && !near) continue;
      token.amount = unit;
      tokens[position + 1].amountUnit = true;
      if (byWord) before.role = FILLER;
      // "Dim the lights by 20%": dimmer by that much.
      for (const other of tokens) if (isDim(other)) other.role = { role: "rel", kind: "light", dir: -1, comparative: true };
    }
  }
  // "A bit", "a little", "קצת": with a change by a step ("a bit brighter"), or "dim" ("dim the
  // lights a bit").
  for (const token of tokens) {
    if (token.role?.modifier !== "bit") continue;
    if (!tokens.some((other) => other.role?.role === "rel")) {
      const dim = tokens.find(isDim);
      if (!dim) continue;
      dim.role = { role: "rel", kind: "light", dir: -1, comparative: true };
    }
    token.role = FILLER;
  }
  // How warm the user feels is never a change ("make it warmer for me", "יותר חם לי"), nor how
  // warm it is ("it's colder in the bedroom"): warmer and cooler only with the AC said (AC,
  // temperature, מזגן) or "make".
  const feels = tokens.some((token) => FEEL_MARKERS.has(token.raw));
  const saysAC = tokens.some((token) => token.role?.role === "kind" && token.role.kind === "climate");
  if (feels || !(saysAC || tokens.some((token) => MAKE_WORDS.has(token.raw)))) {
    for (const token of tokens) {
      if (token.role?.role === "rel" && token.role.kind === "climate") token.role = { role: "feel", mode: token.role.dir > 0 ? "heat" : "cool" };
    }
  }
}

// The words left over once the names are taken out: what they ask, or null when they contradict
// each other or say nothing this understands.
function summarize(tokens, taken) {
  const summary = { actions: new Set(), kinds: new Map(), modes: new Set(), units: new Set(), all: false, everything: false, numbers: [], ac: false, feel: false, rel: null, amount: null, make: false, hebrewUpDown: false };
  for (const [position, token] of tokens.entries()) {
    if (taken.has(position)) continue;
    // A room carried from another part of the sentence need not be used.
    if (token.carried || token.amountUnit) continue;
    if (token.amount) {
      if (summary.amount) return null;
      summary.amount = { value: token.num, unit: token.amount };
      continue;
    }
    if (refusalOf(tokens, position)) return null;
    if (token.num !== null) {
      summary.numbers.push(token.num);
      continue;
    }
    const role = token.role;
    if (!role) return null;
    if (MAKE_WORDS.has(token.raw)) summary.make = true;
    if (role.role === "question") {
      summary.question = true;
    } else if (role.role === "kind") {
      summary.kinds.set(role.kind, (summary.kinds.get(role.kind) || false) || role.plural);
      if (role.ac) summary.ac = true;
    } else if (["cool", "heat", "auto"].includes(role.role)) {
      summary.modes.add(role.role);
      if (role.feel) summary.feel = true;
    } else if (role.role === "percent" || role.role === "degrees") {
      summary.units.add(role.role);
    } else if (role.role === "all") {
      summary.all = true;
    } else if (role.role === "everything") {
      summary.everything = true;
    } else if (role.role === "rel") {
      // Brighter and dimmer at once, or the lights and the AC: not one change.
      const before = summary.rel;
      if (before && (before.dir !== role.dir || (before.kind && role.kind && before.kind !== role.kind))) return null;
      summary.rel = { kind: before?.kind || role.kind || null, dir: role.dir, comparative: Boolean(before?.comparative || role.comparative) };
    } else if (role.role !== "filler") {
      summary.actions.add(role.role);
      // "תעלה את המזגן": in Hebrew, the AC up is warmer (in English "turn up the AC" is not clear).
      if ((role.role === "up" || role.role === "down") && HEBREW.test(token.raw)) summary.hebrewUpDown = true;
    }
  }
  // "Turn off the light on the porch", "open the gate on the porch": with another verb, an "on"
  // before a name or "the" is a preposition.
  // ("Turn on the kitchen lights and turn it off" is not "off": right after turn or switch, "on" is
  // what to do.)
  const preposition = (position) => {
    const next = tokens[position + 1];
    if (["turn", "switch"].includes(tokens[position - 1]?.raw)) return false;
    return next && (taken.has(position + 1) || ["the", "a", "an", "my", "our"].includes(next.raw));
  };
  if (summary.actions.has("on") && summary.actions.size > 1 && tokens.every((token, position) => taken.has(position) || token.role?.role !== "on" || preposition(position))) {
    summary.actions.delete("on");
  }
  if (summary.actions.has("level")) summary.actions.delete("on");
  if (summary.numbers.length > 1 || summary.modes.size > 1 || summary.units.size > 1) return null;
  return summary;
}

// The one thing the leftover words do: on, off, open, close, up, down, stop, start, run, play,
// pause, next; volume and level go with a number. null: none; false: two that contradict.
function verb(summary) {
  const main = [...summary.actions].filter((item) => item !== "volume" && item !== "level");
  if (main.length > 1) {
    // "run" and "start" say the same, as do "start" and "on".
    const same = new Set(main.map((item) => (item === "start" || item === "run" ? "start" : item)));
    if (same.size === 1) return "start";
    if (same.size === 2 && same.has("start") && same.has("on")) return "on";
    return false;
  }
  return main[0] || null;
}

// A temperature as the app sends it (0.5 steps), or a problem when it is outside what the
// thermostats take.
function temperatureFor(value, thermostats) {
  const rounded = Math.round(value * 2) / 2;
  for (const device of thermostats) {
    const min = Number.isFinite(device.min) ? device.min : 10;
    const max = Number.isFinite(device.max) ? device.max : 32;
    if (rounded < min || rounded > max) return problem("range", { device: { kind: device.kind, id: device.id }, min, max, unit: "degrees" });
  }
  return rounded;
}

const MODE_ORDER = ["cool", "heat", "auto"];

function modesOf(thermostats) {
  const all = new Set(thermostats.flatMap((device) => (device.modes || []).filter((mode) => mode !== "off")));
  return [...MODE_ORDER.filter((mode) => all.has(mode)), ...[...all].filter((mode) => !MODE_ORDER.includes(mode))];
}

const isOn = (thermostat) => Boolean(thermostat.mode) && thermostat.mode !== "off";

// Which mode, for thermostats that are off: one option per mode they have; with a temperature and
// heat and cool setpoints, heat or cool (the setpoint the temperature is for).
function askMode(targets, where, ids, change) {
  const dual = "temperature" in change && targets.some((device) => device.dual);
  const modes = modesOf(targets).filter((mode) => !dual || mode === "cool" || mode === "heat");
  if (!modes.length) return problem("noMode", { device: where.device, mode: null });
  return { status: "ask", question: "mode", options: modes.map((mode) => action("climate", { ...where, ids, change: { mode, ...change } }).action) };
}

// The step of a change by a step: the amount said in its unit, or the usual step; null when the
// amount has another unit ("brighter by 2 degrees").
function stepOf(summary, unit, usual) {
  if (!summary.amount) return usual;
  return summary.amount.unit === unit ? summary.amount.value : null;
}

// One kind's devices: `targets` (the device named, those in the room, or all of the kind), and
// what is asked of them.
function kindIntent(kind, targets, where, summary, act) {
  const ids = targets.map((device) => device.id);
  const number = summary.numbers.length ? summary.numbers[0] : null;
  const unit = [...summary.units][0] || null;
  const named = where.device;
  const percent = (value) => (value < 0 || value > 100 ? problem("range", { min: 0, max: 100, unit: "percent", device: named }) : Math.round(value));
  const rel = summary.rel;
  // A change by a step: its words, or an amount said with ב or "by" (then only with them).
  const stepped = Boolean(rel || summary.amount);

  if (kind === "light") {
    if (unit === "degrees" || summary.modes.size) return null;
    // "The lights" leave lights named for heating as they are, unless one is named (heaters.js,
    // ADR-066): `kept` says which, to say so.
    const kept = named ? [] : targets.filter(isHeater);
    const lights = named ? targets : targets.filter((device) => !isHeater(device));
    const lightAction = (list, change) => action("lights", { ...where, ids: list.map((device) => device.id), change, ...(kept.length ? { kept: kept.map((device) => device.id) } : {}) });
    const none = () => (kept.length ? problem("heatersOnly", { room: where.room }) : problem("none", { kind, room: where.room }));
    if (stepped) {
      if (!rel || (rel.kind && rel.kind !== "light") || act !== null || number !== null) return null;
      // "Increase", "תגביר": the light said.
      if (!rel.kind && !(summary.kinds.has("light") || summary.actions.has("level") || named)) return null;
      const step = stepOf(summary, "percent", LIGHT_STEP);
      if (step === null) return null;
      if (!(step > 0 && step <= 100)) return problem("range", { min: 0, max: 100, unit: "percent", device: named });
      if (!lights.length) return none();
      const dimmable = lights.filter((device) => device.dimmable !== false);
      if (!dimmable.length) return problem("cannotDim", { device: named, room: where.room });
      return lightAction(dimmable, { brightnessBy: rel.dir * Math.round(step) });
    }
    if (act === "off") {
      if (number !== null) return null;
      if (!lights.length) return none();
      return lightAction(lights, { on: false });
    }
    if (number !== null) {
      if (!["on", "start", "up", "down", null].includes(act)) return null;
      const level = percent(number);
      if (typeof level !== "number") return level;
      if (!lights.length) return none();
      if (level === 0) return lightAction(lights, { on: false });
      const dimmable = lights.filter((device) => device.dimmable !== false);
      if (!dimmable.length) return problem("cannotDim", { device: named, room: where.room });
      return lightAction(dimmable, { brightness: level });
    }
    if (summary.actions.has("level")) return problem("needLevel", { kind });
    if (act === "on" || act === "start" || act === "up") {
      if (!lights.length) return none();
      return lightAction(lights, { on: true });
    }
    return act === null ? problem("needWhat", { kind, room: where.room, device: named }) : null;
  }

  if (kind === "climate") {
    if (unit === "percent") return null;
    // Warmer or cooler: "warmer", "יותר חם", "תעלה את המזגן", by a degree or as said.
    const upDown = (act === "up" || act === "down") && summary.hebrewUpDown;
    if (stepped || (upDown && number === null)) {
      if (rel ? rel.kind !== "climate" || act !== null : !upDown) return null;
      if (number !== null || summary.modes.size) return null;
      // A comparative with the AC said (by a word or its name) or "make": "warmer in the bedroom"
      // may say how it is, not what to do.
      if (rel && !(summary.kinds.has("climate") || summary.named || summary.make)) return null;
      const step = stepOf(summary, "degrees", DEGREE_STEP);
      if (step === null) return null;
      if (!(step > 0 && step <= MAX_DEGREE_STEP)) return problem("step", { max: MAX_DEGREE_STEP });
      const dir = rel ? rel.dir : act === "up" ? 1 : -1;
      // Only an AC that is on has a setpoint to move.
      const running = targets.filter(isOn);
      if (!running.length) return problem("isOff", { device: named, room: where.room });
      const onIds = running.map((device) => device.id);
      const change = { temperatureBy: dir * (Math.round(step * 2) / 2) };
      // With heat and cool setpoints in auto: which one.
      if (running.some((device) => device.dual && device.mode !== "heat" && device.mode !== "cool")) {
        return { status: "ask", question: "setpoint", options: ["cool", "heat"].map((setpoint) => action("climate", { ...where, ids: onIds, change: { setpoint, ...change } }).action) };
      }
      return action("climate", { ...where, ids: onIds, change });
    }
    // "Turn off the heating" is the AC off too.
    if (act === "off") return number === null ? action("climate", { ...where, ids, change: { mode: "off" } }) : null;
    if (act && !["on", "start", "up", "down"].includes(act)) return null;
    if ((act === "up" || act === "down") && number === null) return null;
    const mode = [...summary.modes][0] || null;
    if (mode) {
      const lacking = targets.find((device) => !(device.modes || []).includes(mode));
      if (lacking) return problem("noMode", { device: { kind: lacking.kind, id: lacking.id }, mode });
    }
    if (number !== null) {
      const temperature = temperatureFor(number, targets);
      if (typeof temperature !== "number") return temperature;
      if (mode && mode !== "heat" && mode !== "cool" && targets.some((device) => device.dual)) {
        return { status: "ask", question: "setpoint", options: ["cool", "heat"].map((setpoint) => action("climate", { ...where, ids, change: { mode, setpoint, temperature } }).action) };
      }
      if (mode) return action("climate", { ...where, ids, change: { mode, temperature } });
      // Off, the thermostat needs a mode; with heat and cool setpoints in auto, which setpoint.
      if (targets.some((device) => !isOn(device))) return askMode(targets, where, ids, { temperature });
      if (targets.some((device) => device.dual && device.mode !== "heat" && device.mode !== "cool")) {
        return { status: "ask", question: "setpoint", options: ["cool", "heat"].map((setpoint) => action("climate", { ...where, ids, change: { setpoint, temperature } }).action) };
      }
      return action("climate", { ...where, ids, change: { temperature } });
    }
    if (mode) return action("climate", { ...where, ids, change: { mode } });
    if (act === "on" || act === "start") {
      if (targets.every(isOn)) return problem("alreadyOn", { device: named, room: where.room, kind });
      return askMode(targets, where, ids, {});
    }
    return problem("needWhat", { kind, room: where.room, device: named });
  }

  if (kind === "blind") {
    if (unit === "degrees" || summary.modes.size || stepped) return null;
    if (act === "stop") return number === null ? action("blinds", { ...where, ids, change: { stop: true } }) : null;
    let position = null;
    if (number !== null) {
      if (act && !["open", "close", "up", "down", "start", "on"].includes(act)) return null;
      position = percent(number);
      if (typeof position !== "number") return position;
    } else if (act === "open" || act === "up") position = 100;
    else if (act === "close" || act === "down") position = 0;
    else return act === null ? problem("needWhat", { kind, room: where.room, device: named }) : null;
    let blinds = targets;
    if (position > 0 && position < 100) {
      blinds = targets.filter((device) => device.position !== false);
      if (!blinds.length) return problem("noPosition", { device: named, room: where.room });
    }
    return action("blinds", { ...where, ids: blinds.map((device) => device.id), change: { position } });
  }

  if (kind === "fan") {
    if (number !== null || summary.modes.size || stepped) return null;
    if (act === "on" || act === "start") return action("fans", { ...where, ids, change: { on: true } });
    if (act === "off") return action("fans", { ...where, ids, change: { on: false } });
    return act === null ? problem("needWhat", { kind, room: where.room, device: named }) : null;
  }

  if (kind === "music") {
    if (unit === "degrees" || summary.modes.size) return null;
    // Louder or quieter: "louder", "תגביר את המוזיקה", "turn up the music", "volume down".
    const upDown = (act === "up" || act === "down") && (summary.actions.has("volume") || summary.kinds.has("music"));
    if (stepped || (upDown && number === null)) {
      if (rel ? (rel.kind && rel.kind !== "music") || act !== null : !upDown) return null;
      if (rel && !rel.kind && !(summary.kinds.has("music") || summary.actions.has("volume") || named)) return null;
      if (number !== null) return null;
      const step = stepOf(summary, "percent", MUSIC_STEP);
      if (step === null) return null;
      if (!(step > 0 && step <= 100)) return problem("range", { min: 0, max: 100, unit: "percent", device: named });
      const dir = rel ? rel.dir : act === "up" ? 1 : -1;
      return action("music", { ...where, ids, change: { volumeBy: dir * Math.round(step) } });
    }
    if (number !== null) {
      if (act && !["up", "down", "on", "start"].includes(act)) return null;
      const volume = percent(number);
      if (typeof volume !== "number") return volume;
      return action("music", { ...where, ids, change: { volume } });
    }
    if (summary.actions.has("volume")) return problem("needLevel", { kind });
    const which = { play: "play", start: "play", on: "play", pause: "pause", stop: "pause", off: "pause", next: "next" }[act];
    if (which) return action("music", { ...where, ids, change: { action: which } });
    return act === null ? problem("needWhat", { kind, room: where.room, device: named }) : null;
  }

  if (kind === "door") {
    if (number !== null || summary.modes.size || stepped || (act !== "open" && act !== "start")) return null;
    // Only the doors and gates this user may open; each still gets its second tap.
    const doors = targets.filter((device) => device.canOpen);
    if (!doors.length) return problem("noDoors", { device: targets.length === 1 ? { kind: targets[0].kind, id: targets[0].id } : null });
    if (doors.length > MAX_OPTIONS) return problem("needRoom", { kind });
    const options = doors.map((device) => action("door", { device: { kind: device.kind, id: device.id } }).action);
    return doors.length === 1 ? { status: "ok", action: options[0] } : { status: "ask", question: "which", options };
  }
  return null;
}

// An AC, not floor heating or another thermostat that only heats (one that lists no modes may be
// either).
const isAC = (thermostat) => !(thermostat.modes || []).length || thermostat.modes.includes("cool");

// A room's thermostats (or the home's) for what was said: with "AC" (מזגן), those that cool; with
// a mode, those that have it ("cool the living room": its AC, not its floor heating).
function climateTargets(targets, summary, act) {
  let list = summary.ac ? targets.filter(isAC) : targets;
  const mode = [...summary.modes][0];
  if (mode && act !== "off") {
    const having = list.filter((device) => (device.modes || []).includes(mode));
    if (having.length) list = having;
  }
  return list;
}

// What one reading of the sentence (a target T and a room R, either may be null) asks; null when
// it does not make sense.
function intent(target, room, summary, catalog) {
  if (summary.question) return problem("question");
  const act = verb(summary);
  if (act === false) return null;
  const roomId = room ? room.entity.room.id : null;
  // "Cold", "חם" are a mode only for the AC said ("מזגן על קר").
  if (summary.feel && !summary.kinds.has("climate") && target?.entity.kind !== "climate") return null;

  if (target?.entity.type === "scene") {
    if (summary.kinds.size || summary.modes.size || summary.numbers.length || summary.all || summary.everything || summary.rel || summary.amount || room) return null;
    if (act && !["run", "start", "on", "play"].includes(act)) return null;
    return action("scene", { id: target.entity.scene.id });
  }

  const kinds = [...summary.kinds.keys()];
  if (kinds.length > 1) return problem("oneAtATime");
  if (target) {
    const device = target.entity.device;
    if (kinds.length && kinds[0] !== target.entity.kind) return null;
    if (room && device.room !== roomId) return null;
    if (summary.all || summary.everything) return null;
    return kindIntent(target.entity.kind, [device], { room: null, device: { kind: device.kind, id: device.id } }, summary, act);
  }

  // No device named: the kind said, or what the words imply.
  let kind = kinds[0] || null;
  if (!kind && summary.rel?.kind) kind = summary.rel.kind;
  if (!kind && summary.modes.size) kind = "climate";
  if (!kind && summary.units.has("degrees")) kind = "climate";
  if (!kind && (summary.actions.has("volume") || ["play", "pause", "next"].includes(act))) kind = "music";
  if (!kind && summary.actions.has("level")) kind = "light";
  if (!kind && room && ["open", "close", "up", "down", "stop"].includes(act)) {
    // Open and close are for blinds, stop also for music; open alone for a room's doors.
    if (devicesOf(catalog, "blind", roomId).length) kind = "blind";
    else if (act === "stop" && devicesOf(catalog, "music", roomId).length) kind = "music";
    else if (act === "open" && devicesOf(catalog, "door", roomId).length) kind = "door";
    else return problem("none", { kind: "blind", room: roomId });
  }

  if (!kind) {
    if (summary.numbers.length || summary.rel || summary.amount) return room && summary.numbers.length ? problem("needWhat", { room: roomId }) : null;
    if (act === "off") {
      if (room) return action("roomOff", { room: roomId });
      if (summary.all || summary.everything) return action("offAll", { filters: ["lights", "climate"] });
      return problem("needRoom", { kind: null });
    }
    if (room && (act === "on" || act === "start")) return problem("needWhat", { room: roomId });
    if (!room && (summary.all || summary.everything) && (act === "close" || act === "down")) return action("offAll", { filters: ["blinds"] });
    return null;
  }
  if (summary.everything) return null;

  let targets = devicesOf(catalog, kind, room ? roomId : undefined);
  if (kind === "climate" && targets.length) {
    targets = climateTargets(targets, summary, act);
    if (!targets.length) return problem("none", { kind, room: roomId });
  }
  if (room) {
    if (!targets.length) return problem("none", { kind, room: roomId });
    return kindIntent(kind, targets, { room: roomId, device: null }, summary, act);
  }
  // The whole home: Turn off all for lights, AC and blinds; otherwise one device of the kind, or
  // the ones to choose from. Lights named for heating are never "the light" (ADR-066).
  if (kind === "light" && targets.length) {
    const lights = targets.filter((device) => !isHeater(device));
    if (!lights.length) return problem("heatersOnly", { room: null });
    targets = lights;
  }
  if (!targets.length) return problem("none", { kind, room: null });
  if (targets.length === 1) {
    const device = targets[0];
    return kindIntent(kind, targets, { room: null, device: { kind: device.kind, id: device.id } }, summary, act);
  }
  const off = kind === "light" || kind === "climate" ? act === "off" : kind === "blind" ? act === "close" || act === "down" : false;
  if (off && !summary.numbers.length && !summary.rel && !summary.amount) return action("offAll", { filters: [{ light: "lights", climate: "climate", blind: "blinds" }[kind]] });
  // All of them at once is only Turn off all (above).
  if (summary.all) return problem("needRoom", { kind });
  if (kind === "door") return kindIntent(kind, targets, { room: null, device: null }, summary, act);
  // Several: ask which (each would get the same), or for the room when there are many.
  const each = targets.map((device) => kindIntent(kind, [device], { room: null, device: { kind: device.kind, id: device.id } }, summary, act));
  if (each.some((item) => !item)) return null;
  if (each.every((item) => item.status === "problem")) return each[0];
  if (kind === "light" || each.length > MAX_OPTIONS || each.some((item) => item.status !== "ok")) return problem("needRoom", { kind });
  return { status: "ask", question: "which", options: each.map((item) => item.action) };
}

// What two results do, to tell readings that differ from readings that come to the same.
function effect(result) {
  if (result.status === "ok") {
    const { type, ids, change, id, device, room, filters } = result.action;
    return JSON.stringify([type, ids ? [...ids].sort() : null, change || null, id ?? null, type === "door" ? device : null, type === "roomOff" ? room : null, filters || null]);
  }
  if (result.status === "ask") return JSON.stringify(["ask", result.options.map((option) => effect({ status: "ok", action: option }))]);
  return JSON.stringify(["problem", result.problem]);
}

// ---- one sentence, or one part of it -----------------------------------------------------------

// The tokens of one thing said (a whole sentence, or one part with a room or a verb it takes from
// another part): what it asks.
function readPart(input, prepared) {
  const { entities, catalog } = prepared;
  const tokens = input.map((token) => ({ ...token }));
  // "על קר", "to warm", "on cold": a mode (the AC must be said too: intent).
  for (const [position, token] of tokens.entries()) {
    if (token.role?.role === "feel" && ["על", "to", "on"].includes(tokens[position - 1]?.raw)) token.role = { role: token.role.mode, feel: true };
  }
  relativeRoles(tokens);

  const matches = entities.map((entity) => matchEntity(entity, tokens)).filter(Boolean);
  const rooms = [null, ...matches.filter((match) => match.entity.type === "room")];
  const targets = [null, ...matches.filter((match) => match.entity.type !== "room")];
  const kindWords = tokens.filter((token) => token.role?.role === "kind");
  const plural = kindWords.some((token) => token.role.plural) || tokens.some((token) => token.role?.role === "all");
  const carriedRoom = matches.find((match) => match.entity.type === "room" && match.full && [...match.positions].every((position) => tokens[position].carried));

  const readings = [];
  for (const room of rooms) {
    for (const target of targets) {
      if (room && target && [...room.positions].some((position) => target.positions.has(position))) continue;
      // A device named only by its kind ("Light", "מזגן") is that device only in its room.
      if (target?.entity.exactOnly && target.entity.type === "device" && !room) continue;
      // A room carried from another part is that room: a device's name may take its words only
      // in it ("the island" after "kitchen…" is the Kitchen Island), a scene's never.
      if (target && [...target.positions].some((position) => tokens[position].carried)) {
        if (target.entity.type !== "device" || !carriedRoom || target.entity.device.room !== carriedRoom.entity.room.id) continue;
      }
      const taken = new Set([...(room?.positions || []), ...(target?.positions || [])]);
      const summary = summarize(tokens, taken);
      if (!summary) continue;
      // A device named by more than its room's words ("the living room AC", not "warmer in the
      // living room" for a thermostat called "Living room AC").
      summary.named = Boolean(target && !matches.some((match) => match.entity.type === "room" && match.full && [...target.positions].every((position) => match.positions.has(position))));
      const result = intent(target, room, summary, catalog);
      if (!result) continue;
      let score = 0;
      for (const match of [room, target]) if (match) score += match.score + (match.full ? 0.5 : 0);
      // "Kitchen lights" is the room's lights, "the kitchen light" a light of that name.
      if (room && !target && (plural || !kindWords.length)) score += 0.3;
      if (target?.entity.type === "device" && kindWords.some((token) => token.role.kind === target.entity.kind && !token.role.plural)) score += 0.3;
      readings.push({ result, score, partial: Boolean((room && (!room.full || room.unsure)) || (target && (!target.full || target.unsure))) });
    }
  }

  if (!readings.length) {
    const covered = new Set(matches.flatMap((match) => [...match.positions]));
    // Don't, a time, how warm one feels: refused, whatever else was said.
    const refusal = tokens.map((_token, position) => (covered.has(position) ? null : refusalOf(tokens, position))).find(Boolean);
    if (refusal) return { status: "unknown", words: [], refusal };
    const words = tokens.filter((token, position) => !token.role && token.num === null && !token.carried && !covered.has(position)).map((token) => token.display);
    // Two rooms said at once.
    const fullRooms = matches.filter((match) => match.entity.type === "room" && match.full);
    if (!words.length && fullRooms.some((one) => fullRooms.some((other) => other.entity.room.id !== one.entity.room.id && ![...one.positions].some((position) => other.positions.has(position))))) {
      return problem("oneAtATime");
    }
    return { status: "unknown", words };
  }

  readings.sort((a, b) => b.score - a.score);
  const best = readings.filter((reading) => reading.score >= readings[0].score - TIE);
  const distinct = [];
  for (const reading of best) {
    if (!distinct.some((other) => effect(other.result) === effect(reading.result))) distinct.push(reading);
  }
  const partial = distinct.some((reading) => reading.partial);
  if (distinct.length === 1 && !partial) return distinct[0].result;
  const options = distinct.flatMap((reading) => (reading.result.status === "ok" ? [reading.result.action] : []));
  if (!options.length) return distinct[0].result;
  if (options.length > MAX_OPTIONS) return problem("tooMany");
  return { status: "ask", question: partial ? "partial" : "which", options, partial };
}

// ---- several things in one sentence (1.10.0, ADR-066) -------------------------------------------

// At most three things a sentence.
export const MAX_PARTS = 3;
// What parts a sentence ("and", ",", "ואז", "וגם", "ואת"), and the words that may come before the
// next thing said ("and the blinds", "ואת התריסים").
const SEPARATORS = new Set(["and", "then", "ו", "וגם", "ואז", "ואת", ","].map(fold));
const LEADS = new Set(["the", "a", "an", "my", "our", "also", "then", "please", "את", "גם", "אז", "בבקשה"].map(fold));
// Verbs that start what is said next ("and set the AC to 23", "ותשים את המזגן על 23").
const VERB_WORDS = new Set("set turn switch make put change adjust שים שימי שימו תשים תשימי תשימו כוון כווני כוונו תכוון תכווני תכוונו לכוון קבע קבעי קבעו תקבע תקבעי תקבעו שנה תשנה העבר תעביר עשה עשי עשו תעשה תעשי תעשו הגדר תגדיר".split(" ").map(fold));
const DOING = new Set(["on", "off", "open", "close", "up", "down", "stop", "start", "run", "play", "pause", "next"]);
const ACTING = new Set([...DOING, "volume", "level", "rel"]);

// Whether a word is a word of a room's name, and of a device's or a scene's (said as it is, or
// with its prefixes or another form; no typos).
function nameKinds(token, entities) {
  const kinds = { room: false, thing: false };
  if (token.num !== null) return kinds;
  for (const entity of entities) {
    const which = entity.type === "room" ? "room" : "thing";
    if (kinds[which] || entity.exactOnly) continue;
    if (entity.parts.some((part) => !part.optional && quality(part, token, false) >= 0.9)) kinds[which] = true;
  }
  return kinds;
}

// A Hebrew word with ו in front that starts something new: the word without it ("ותסגרו",
// "והמזגן", "ומזגן"). Never a word that is itself a command word or a word of a name ("ורד",
// "וילון").
function andRest(token, names) {
  const raw = token.raw;
  if (token.num !== null || !raw.startsWith("ו") || raw.length < 3) return null;
  if (ROLES.has(raw) || ROLE_STEMS.has(stem(raw)) || names.has(token.stem)) return null;
  const rest = word(raw.slice(1));
  rest.role = roleOf(rest, names);
  return rest;
}

// Something new starts at `from` (skipping "the", "את" and a room's name): a verb, a kind of
// device, or a word of a device's or a scene's name.
function startsSomething(tokens, from, end, rest, entities) {
  for (let index = from; index < end; index += 1) {
    const token = index === from && rest ? rest : tokens[index];
    const role = token.role?.role;
    if (role === "kind" || ACTING.has(role) || token.bares?.some((form) => VERB_WORDS.has(form))) return true;
    const kinds = nameKinds(token, entities);
    if (kinds.thing && !kinds.room) return true;
    if (kinds.room || role === "filler" || role === "all" || role === "everything" || token.role?.modifier || LEADS.has(token.raw)) continue;
    return false;
  }
  return false;
}

// A thing of its own: more than a verb ("and off"), and more than a room's name without one
// ("Kitchen," before "lights off"; "kitchen off" is one), even when a device's name has the word.
function hasContent(tokens, from, end, rest, entities) {
  let room = false;
  let doing = false;
  for (let index = from; index < end; index += 1) {
    const token = index === from && rest ? rest : tokens[index];
    const role = token.role?.role;
    if (role === "filler" || SEPARATORS.has(token.raw) || LEADS.has(token.raw)) continue;
    if (DOING.has(role)) {
      doing = true;
      continue;
    }
    if (!role && token.num === null && nameKinds(token, entities).room) {
      room = true;
      continue;
    }
    return true;
  }
  return room && doing;
}

// A separator inside a name said ("Rock and Roll", "סרט ומוזיקה") parts nothing.
function insideName(tokens, index, entities) {
  for (const entity of entities) {
    const { parts } = entity;
    if (parts.length < 2) continue;
    for (let start = Math.max(0, index - parts.length + 1); start < index; start += 1) {
      if (start + parts.length > tokens.length) break;
      if (parts.every((part, offset) => tokens[start + offset].raw === part.raw || quality(part, tokens[start + offset], false) >= 0.9)) return true;
    }
  }
  return false;
}

// The parts of a sentence: [{ tokens, text }]. A part starts after "and" (or a comma, ואז, וגם,
// ואת) or at a Hebrew word with ו in front, only where something new starts (a verb, a kind of
// device, a device's or a scene's name) and both sides say more than a room ("kitchen lights on
// and off" is one thing, as is "the lights in the kitchen and the living room").
function splitParts(tokens, prepared) {
  const { entities, names } = prepared;
  const candidates = tokens.map((token, index) => (index === 0 ? null : SEPARATORS.has(token.raw) ? { index, drop: true } : andRest(token, names) ? { index, drop: false } : null)).filter(Boolean);
  if (!candidates.length) return [{ tokens, text: tokens.map((token) => token.display).join(" ") }];
  const cuts = [];
  let start = 0;
  for (const [order, candidate] of candidates.entries()) {
    const { index, drop } = candidate;
    const rest = drop ? null : andRest(tokens[index], names);
    const from = drop ? index + 1 : index;
    const end = candidates[order + 1]?.index ?? tokens.length;
    if (from >= end) continue;
    if (!hasContent(tokens, start, index, null, entities)) continue;
    if (!startsSomething(tokens, from, end, rest, entities)) continue;
    if (!hasContent(tokens, from, end, rest, entities)) continue;
    if (insideName(tokens, index, entities)) continue;
    cuts.push({ index, from, rest });
    start = from;
  }
  const parts = [];
  let begin = 0;
  let restFirst = null;
  for (const cut of [...cuts, { index: tokens.length, from: tokens.length, rest: null }]) {
    const list = tokens.slice(begin, cut.index);
    if (list.length) {
      const words = list.map((token, position) => (position === 0 && restFirst ? token.display.replace(/^ו/, "") : token.display));
      parts.push({ tokens: list, text: words.join(" ") });
    }
    begin = cut.from;
    restFirst = cut.rest;
  }
  return parts;
}

// The room a part says itself: the tokens of the best room said whole (in a device's name too:
// "the kitchen island"), or null.
function roomSaid(tokens, prepared) {
  let best = null;
  for (const entity of prepared.entities) {
    if (entity.type !== "room") continue;
    const match = matchEntity(entity, tokens);
    if (!match?.full || match.unsure) continue;
    // With the words of its name that need not be said, when said right before ("room 12").
    const positions = new Set(match.positions);
    for (const position of [...positions].sort((a, b) => a - b)) {
      const before = tokens[position - 1];
      if (before && !positions.has(position - 1) && entity.parts.some((part) => part.optional && part.raw === before.raw)) positions.add(position - 1);
    }
    // Said by a word, not by a number alone ("set the AC to 23" names no room "23").
    if ([...positions].some((position) => tokens[position].num === null) && (!best || match.score > best.match.score)) best = { match, positions };
  }
  return best ? [...best.positions].sort((a, b) => a - b).map((position) => tokens[position]) : null;
}

// A part that says only what (a device, a kind, a scene), with no verb, number or mode of its own:
// "and the AC" takes the verb said before it.
function needsVerb(tokens) {
  return !tokens.some((token) => token.num !== null || ACTING.has(token.role?.role) || ["cool", "heat", "auto", "feel"].includes(token.role?.role));
}

// What two or three parts do: each read alone, with the room said in another part when it says
// none (forward, and back to the part before when they share one verb: "turn off the lights and
// the AC in the living room"), and the verb of another part when it has none. All or nothing.
function readSeveral(parts, prepared) {
  const info = parts.map((part) => ({
    room: roomSaid(part.tokens, prepared),
    verb: part.tokens.filter((token) => DOING.has(token.role?.role)),
    needsVerb: needsVerb(part.tokens),
    all: part.tokens.some((token) => ["all", "everything"].includes(token.role?.role)),
  }));
  const verbFrom = info.map((item, index) => {
    if (!item.needsVerb) return null;
    for (let other = index - 1; other >= 0; other -= 1) if (info[other].verb.length) return other;
    for (let other = index + 1; other < info.length; other += 1) if (info[other].verb.length) return other;
    return null;
  });
  const roomFrom = info.map((item, index) => {
    if (item.room) return null;
    for (let other = index - 1; other >= 0; other -= 1) if (info[other].room) return other;
    const next = index + 1;
    if (info[next]?.room && (verbFrom[index] === next || verbFrom[next] === index)) return next;
    return null;
  });
  const results = parts.map((part, index) => {
    const room = roomFrom[index] === null ? [] : info[roomFrom[index]].room.map((token) => ({ ...token, carried: true }));
    const verb = verbFrom[index] === null ? [] : info[verbFrom[index]].verb;
    if (!verb.length) return readPart([...part.tokens, ...room], prepared);
    // "And the AC": with the verb before it; a scene's name ("and good night") as it is.
    const withVerb = readPart([...verb, ...part.tokens, ...room], prepared);
    if (withVerb.status === "ok") return withVerb;
    const alone = readPart([...part.tokens, ...room], prepared);
    return alone.status === "ok" ? alone : withVerb;
  });

  // A refusal anywhere ("don't", a time, how warm one feels) decides; then the first part that is
  // not understood, asks or cannot be done. Nothing is done.
  const refused = results.findIndex((result) => result.status === "unknown" && result.refusal);
  if (refused >= 0) return { ...results[refused], part: parts[refused].text };
  const failed = results.findIndex((result) => result.status !== "ok");
  if (failed >= 0) {
    const result = results[failed];
    const part = parts[failed].text;
    if (result.status === "ask") return problem("partAsks", { question: result.question, options: result.options, part });
    return { ...result, part };
  }
  // The whole home without "all" while another part names a room ("turn off the lights and close
  // the kitchen blinds"): which room? never a guess.
  const anyRoom = info.some((item) => item.room);
  for (const [index, result] of results.entries()) {
    if (result.action.type === "offAll" && !info[index].all && anyRoom) {
      return problem("needRoom", { kind: { lights: "light", climate: "climate", blinds: "blind" }[result.action.filters[0]] || null, part: parts[index].text });
    }
  }
  return combine(results.map((result) => result.action), parts, prepared.catalog);
}

// The devices an action changes, as "kind:id" (a room's All off and Turn off all: all they may).
function touched(item, catalog) {
  const devices = catalog.devices || [];
  const of = (kind) => (device) => device.kind === kind;
  const keys = (list) => list.map((device) => `${device.kind}:${device.id}`);
  const lights = (list) => list.filter((device) => device.kind === "light" && !isHeater(device));
  switch (item.type) {
    case "lights":
      return item.ids.map((id) => `light:${id}`);
    case "climate":
      return item.ids.map((id) => `thermostat:${id}`);
    case "blinds":
      return item.ids.map((id) => `blind:${id}`);
    case "fans":
      return item.ids.map((id) => `fan:${id}`);
    case "music":
      return item.ids.map((id) => `music:${id}`);
    case "door":
      return [`${item.device.kind}:${item.device.id}`];
    case "scene":
      return [`scene:${item.id}`];
    case "roomOff": {
      const here = devices.filter((device) => device.room === item.room);
      return [...keys(lights(here)), ...keys(here.filter(of("thermostat"))), ...keys(here.filter(of("fan")))];
    }
    case "offAll":
      return item.filters.flatMap((filter) => keys(filter === "lights" ? lights(devices) : devices.filter(of(filter === "climate" ? "thermostat" : "blind"))));
    default:
      return [];
  }
}

// The parts' actions as one answer: Turn off all said in two parts is one (one confirm), never the
// same device twice, at most one door or gate.
function combine(actions, parts, catalog) {
  const list = [];
  let offAll = null;
  for (const item of actions) {
    if (item.type !== "offAll") {
      list.push(item);
      continue;
    }
    if (!offAll) {
      offAll = { ...item, filters: [...item.filters] };
      list.push(offAll);
      continue;
    }
    for (const filter of item.filters) {
      if (offAll.filters.includes(filter)) return problem("overlap", { device: null });
      offAll.filters.push(filter);
    }
  }
  if (list.filter((item) => item.type === "door").length > 1) return problem("oneDoor");
  const seen = new Map();
  for (const item of list) {
    for (const key of new Set(touched(item, catalog))) {
      if (seen.has(key)) {
        const [kind, ...rest] = key.split(":");
        const id = rest.join(":");
        if (kind === "scene") return problem("overlap", { scene: id });
        const device = (catalog.devices || []).find((candidate) => candidate.kind === kind && String(candidate.id) === id);
        return problem("overlap", { device: device ? { kind: device.kind, id: device.id } : null });
      }
      seen.set(key, item);
    }
  }
  if (list.length === 1) return { status: "ok", action: list[0] };
  return { status: "ok", actions: list, parts: parts.map((part) => part.text) };
}

// ---- parse ---------------------------------------------------------------------------------

// Longer than this, a text is not a command (the field takes one letter more, so that a longer
// text pasted and cut short by it is never understood in part).
export const MAX_LENGTH = 200;

export function parseCommand(text, catalog = {}) {
  const sentence = String(text ?? "");
  if (sentence.trim().length > MAX_LENGTH) return { status: "unknown", words: [] };
  const prepared = { ...prepare(catalog), catalog };
  const tokens = tokenize(sentence, prepared.names);
  if (!tokens.length || tokens.length > 30) return { status: "unknown", words: [] };
  // A question mark makes it a question ("האור במטבח כבוי?", "kitchen lights off?"): Hebrew asks
  // yes or no without a question word, and dictation writes "?" for a rising voice.
  if (/[?？؟]/u.test(sentence)) return problem("question");
  for (const token of tokens) token.role = roleOf(token, prepared.names);
  const parts = splitParts(tokens, prepared);
  if (parts.length === 1) return readPart(parts[0].tokens, prepared);
  if (parts.length > MAX_PARTS) return problem("tooManyParts", { max: MAX_PARTS });
  return readSeveral(parts, prepared);
}
