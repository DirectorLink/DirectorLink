// Pairing codes as typed or pasted from Composer ("1234 5678"), for app/api-client.js (the
// console uses an identical copy).
//   node --test tests/app/

import assert from "node:assert/strict";
import test from "node:test";

import { formatPairingCode, normalizePairingCode } from "../../app/api-client.js";

test("accepts the code with or without its space or a dash", () => {
  for (const typed of ["12345678", "1234 5678", "1234-5678", " 1234  5678 ", "1234 5678"]) {
    assert.equal(normalizePairingCode(typed), "12345678", JSON.stringify(typed));
  }
});

test("rejects anything but 8 digits", () => {
  for (const typed of ["", "1234567", "123456789", "1234 567a", "abcd efgh", null, undefined]) {
    assert.equal(normalizePairingCode(typed), null, JSON.stringify(typed));
  }
});

test("formats while typing: digits only, at most 8, a space after the fourth", () => {
  assert.equal(formatPairingCode(""), "");
  assert.equal(formatPairingCode("1"), "1");
  assert.equal(formatPairingCode("1234"), "1234");
  assert.equal(formatPairingCode("12345"), "1234 5");
  assert.equal(formatPairingCode("12345678"), "1234 5678");
  assert.equal(formatPairingCode("1234-5678"), "1234 5678");
  assert.equal(formatPairingCode("1234 56789"), "1234 5678");
  assert.equal(formatPairingCode("code: 1234 5678"), "1234 5678");
});
