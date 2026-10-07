// Text fields never go under 16 px, whatever the text size (ADR-067): iOS zooms the page into a smaller
// field it focuses, and the Small text size makes 1rem 15 px. The command dialog's title wraps.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const css = readFileSync(new URL("../../app/styles.css", import.meta.url), "utf8");

function rule(selector) {
  const start = css.indexOf(`${selector} {`);
  assert.ok(start >= 0, `no rule for ${selector}`);
  return css.slice(start, css.indexOf("}", start));
}

test("text fields, selects and the command field are never under 16 px", () => {
  for (const selector of ['input[type="password"],\nselect', "select.access-role", 'input[type="text"].command-input']) {
    assert.match(rule(selector), /font-size:\s*max\(1rem,\s*16px\)/, selector);
  }
});

test("the command dialog's title wraps, camera titles keep their ellipsis", () => {
  assert.match(rule(".command-dialog .dialog-title"), /white-space:\s*normal/);
  assert.match(rule(".dialog-title"), /white-space:\s*nowrap/);
});
