#!/usr/bin/env node
// Makes the VAPID key pair (RFC 8292) the cloud signs its alerts with (ADR-047, cloud/README.md).
// The private key goes to standard output as a JWK, for `wrangler secret put`, and is never shown;
// the public key goes to the terminal (standard error), for VAPID_PUBLIC_KEY in cloud/wrangler.jsonc.
//
//   cd cloud && node ../scripts/vapid_key.mjs | npx wrangler@4.143.0 secret put VAPID_PRIVATE_KEY
//
// Make it once: browsers subscribe with the public key, so a new pair means every device turns its
// alerts on again (the app does it by itself the next time it opens, signed in).

import { generateKeyPairSync } from "node:crypto";

if (process.stdout.isTTY) {
  console.error("This prints the private key: pipe it into wrangler instead, so it is never shown:");
  console.error("  cd cloud && node ../scripts/vapid_key.mjs | npx wrangler@4.143.0 secret put VAPID_PRIVATE_KEY");
  process.exit(2);
}

const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const { kty, crv, d, x, y } = privateKey.export({ format: "jwk" });
const publicKey = Buffer.concat([Buffer.from([4]), Buffer.from(x, "base64url"), Buffer.from(y, "base64url")]).toString("base64url");
process.stdout.write(JSON.stringify({ kty, crv, d, x, y }));
console.error(`VAPID_PUBLIC_KEY for cloud/wrangler.jsonc (vars): ${publicKey}`);
