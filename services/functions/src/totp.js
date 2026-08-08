/**
 * TOTP (RFC 6238), for the second factor on money-moving admin actions.
 *
 * WHY NOT A LIBRARY.
 *
 * Not NIH. TOTP is a HMAC, a big-endian counter and a truncation -- about thirty
 * lines, fully specified, and with PUBLISHED TEST VECTORS in RFC 6238 §Appendix
 * B that pin every one of them. src/totp.test.mjs runs those vectors, so this is
 * verified against the standard rather than against my reading of it.
 *
 * Against that, a dependency here is a supply-chain surface inside the process
 * that signs withdrawals and approves deposits. `otplib` pulls transitive
 * packages that would gain the ability to read this service's memory -- which
 * includes JWT_SECRET, the database password and anything KMS returns. That is a
 * poor trade for thirty lines whose correctness is checkable against the RFC.
 *
 * SHA-1 IS CORRECT HERE, and it is not a lapse. RFC 6238 defines SHA-1 as the
 * default, and every authenticator app (Google Authenticator, Aegis, 1Password)
 * implements that default. HMAC-SHA1 is not affected by the collision attacks
 * that killed SHA-1 for signatures: it relies on PRF security, which remains
 * sound. Choosing SHA-256 here would be more "modern" and would simply fail to
 * enrol on most phones.
 */

import crypto from 'node:crypto';

const DIGITS = 6;
const PERIOD = 30;
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/** RFC 4648 base32, which is what otpauth:// URIs and every authenticator use. */
export function base32Encode(buf) {
  let bits = 0;
  let value = 0;
  let out = '';

  for (const byte of buf) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

export function base32Decode(str) {
  const clean = str.toUpperCase().replace(/=+$/, '').replace(/\s+/g, '');
  let bits = 0;
  let value = 0;
  const out = [];

  for (const ch of clean) {
    const idx = B32.indexOf(ch);
    if (idx === -1) throw new Error('invalid base32 character');
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/**
 * A fresh secret. 20 bytes = 160 bits, which is the SHA-1 block size RFC 4226
 * recommends and what authenticator apps expect.
 */
export function generateSecret() {
  return base32Encode(crypto.randomBytes(20));
}

/** HOTP: RFC 4226 §5.3, including the dynamic truncation. */
function hotp(secret, counter) {
  const buf = Buffer.alloc(8);
  // writeBigUInt64BE rather than two 32-bit writes: the counter is a 64-bit
  // value and the top half stops being zero in the year 2^33 seconds hence,
  // but the RFC test vectors exercise it NOW (0x00000000023523EC).
  buf.writeBigUInt64BE(BigInt(counter));

  const digest = crypto.createHmac('sha1', base32Decode(secret)).update(buf).digest();

  // Dynamic truncation: the low nibble of the last byte selects the offset.
  const offset = digest[digest.length - 1] & 0x0f;
  const code =
    ((digest[offset] & 0x7f) << 24) |
    ((digest[offset + 1] & 0xff) << 16) |
    ((digest[offset + 2] & 0xff) << 8) |
    (digest[offset + 3] & 0xff);

  return String(code % 10 ** DIGITS).padStart(DIGITS, '0');
}

/**
 * @param {string} secret  base32
 * @param {number} [atMs]  injected by tests; the RFC vectors are at fixed times
 */
export function generate(secret, atMs = Date.now()) {
  return hotp(secret, Math.floor(atMs / 1000 / PERIOD));
}

/**
 * Verify a submitted code.
 *
 * WINDOW = 1, so the previous and next 30-second steps are accepted. That is
 * ±30s of clock skew between the operator's phone and this server, which is the
 * RFC's own suggestion. Widening it multiplies the number of codes valid at any
 * moment; a code is six digits, so every extra step is another 1-in-a-million
 * shot per guess.
 *
 * timingSafeEqual, not ===. String comparison short-circuits on the first
 * differing character, which leaks how much of a guess was right. The leak is
 * small and the fix is free.
 *
 * @returns {boolean}
 */
export function verify(secret, token, atMs = Date.now(), window = 1) {
  if (typeof token !== 'string' || !/^\d{6}$/.test(token)) return false;

  const step = Math.floor(atMs / 1000 / PERIOD);
  const submitted = Buffer.from(token, 'utf8');

  let ok = false;
  for (let i = -window; i <= window; i++) {
    const expected = Buffer.from(hotp(secret, step + i), 'utf8');
    // No early break: comparing every step regardless keeps the work constant,
    // so the response time does not reveal WHICH step matched.
    if (crypto.timingSafeEqual(expected, submitted)) ok = true;
  }
  return ok;
}

/**
 * The otpauth:// URI an authenticator app scans.
 *
 * The issuer appears twice -- once in the label prefix and once as a parameter
 * -- which looks redundant and is what the spec asks for: older apps read the
 * prefix, newer ones read the parameter, and omitting either makes the entry
 * show up unlabelled on somebody's phone.
 */
// The label a player sees in their authenticator app. Changing it affects
// only NEW enrolments -- an existing entry keeps whatever label it was created
// with, because the label is baked into the URI at enrolment and never re-read.
export function otpauthUri(secret, account, issuer = 'BingoNovaa') {
  const label = encodeURIComponent(`${issuer}:${account}`);
  const params = new URLSearchParams({
    secret,
    issuer,
    algorithm: 'SHA1',
    digits: String(DIGITS),
    period: String(PERIOD),
  });
  return `otpauth://totp/${label}?${params.toString()}`;
}
