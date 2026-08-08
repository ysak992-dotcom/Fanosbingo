/**
 * Tests for the CORS contract.
 *
 * WHY THIS FILE EXISTS: a header the SERVER reads is not a header the BROWSER
 * may send. The preflight decides that, and anything absent from
 * Access-Control-Allow-Headers is stripped before the request is made.
 *
 * requireSecondFactor read X-Admin-TOTP while the allow-list named only
 * Content-Type and Authorization, so the retry carrying the code never left the
 * browser. Firefox reported it as
 *
 *   NetworkError when attempting to fetch resource
 *
 * which reads like the API is down. The server log showed only the FIRST
 * attempt and nothing from the retry -- so it looked like an operator who gave
 * up, not a client that was blocked. Nothing in the service was wrong; the
 * contract between it and the browser was.
 *
 * So this asserts the pairing directly: every header the code reads via
 * req.get() must appear in the allow-list. It is derived from the SOURCE rather
 * than restated, so a header added later without a CORS change fails here
 * instead of in somebody's browser.
 *
 * Run: node src/cors.test.mjs
 */

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const dir = path.dirname(fileURLToPath(import.meta.url));

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

console.log('\nCORS allow-list');

const index = fs.readFileSync(path.join(dir, 'index.js'), 'utf8');

const m = index.match(/Access-Control-Allow-Headers',\s*'([^']+)'/);
check('the allow-list is set', Boolean(m));

const allowed = (m?.[1] ?? '').split(',').map((h) => h.trim().toLowerCase());
check('includes Authorization', allowed.includes('authorization'));
check('includes Content-Type', allowed.includes('content-type'));

// Every custom header the service reads, discovered from the source so this
// cannot drift. req.get('X-Foo') anywhere under src/ must be allowed here.
const custom = new Set();
for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.js'))) {
  const src = fs.readFileSync(path.join(dir, file), 'utf8');
  for (const hit of src.matchAll(/req\.get\(\s*'([^']+)'\s*\)/g)) {
    const h = hit[1].toLowerCase();
    // Standard headers are always permitted and never need listing.
    if (['authorization', 'content-type', 'accept', 'origin', 'user-agent'].includes(h)) continue;
    custom.add(h);
  }
}

console.log(`  (custom headers read by the service: ${[...custom].join(', ') || 'none'})`);

for (const h of custom) {
  check(`${h} is in Access-Control-Allow-Headers`, allowed.includes(h));
}

// The one this was written for, named explicitly so the intent survives even if
// the discovery above is ever weakened.
check('X-Admin-TOTP specifically is allowed', allowed.includes('x-admin-totp'));

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll CORS tests passed.');
process.exit(failures ? 1 : 0);
