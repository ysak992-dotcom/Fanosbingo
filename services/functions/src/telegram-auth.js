/**
 * Telegram request authentication.
 *
 * PLAIN JAVASCRIPT, not TypeScript, deliberately. telegram-auth.test.mjs
 * imports THIS FILE and exercises the real functions. A test that transcribes
 * the algorithm instead can drift from the implementation and keep passing
 * while the deployed code is wrong -- the same reason verify-detections.sh
 * reads the deployed metric filter rather than restating it.
 *
 * It lives in the AWS service rather than under supabase/functions/, because
 * that is the code with a future: the Deno functions are inherited source that
 * has never run under this account, and may never be ported.
 *
 * Two mechanisms, for two different callers:
 *
 *   verifyWebhookSecret()  Telegram's servers calling our webhook. Telegram
 *                          echoes a secret we chose at registration time.
 *   verifyInitData()       A Mini App client calling us. Telegram signs the
 *                          payload with a key derived from the bot token.
 *
 * Neither existed before. The webhook accepted a POST from anyone, and no
 * function referenced initData at all -- identity was a telegram_id in the
 * request body, taken on trust.
 */

/**
 * Constant-time string comparison.
 *
 * `a === b` on a secret leaks its length and its matching prefix through
 * timing. That is a slow attack over a network and a real one, and the correct
 * version is short enough that there is no reason to skip it.
 *
 * Compares over the longer length so an early return cannot reveal which input
 * was shorter.
 */
export function timingSafeEqual(a, b) {
  const len = Math.max(a.length, b.length);
  let diff = a.length ^ b.length;

  for (let i = 0; i < len; i++) {
    diff |= (a.charCodeAt(i) || 0) ^ (b.charCodeAt(i) || 0);
  }

  return diff === 0;
}

/**
 * Verify the secret Telegram echoes back on every webhook delivery.
 *
 * Telegram sends X-Telegram-Bot-Api-Secret-Token only if setWebhook was called
 * with a secret_token. If the webhook was registered WITHOUT one -- which is
 * how this project's was, until now -- the header never arrives and this
 * rejects every request.
 *
 * That is why the deploy order matters and is not merely tidy:
 *
 *   1. deploy setup-telegram-webhook (which now sends secret_token)
 *   2. RUN it, so Telegram re-registers and starts sending the header
 *   3. deploy this handler
 *
 * Reversing 2 and 3 takes the bot down until somebody notices.
 *
 * Deliberately NOT lenient about a missing header. A "verify it if present"
 * check is no check at all here: an attacker forging an update simply omits it.
 */
/**
 * Read a header from EITHER shape of request.
 *
 * This function was written for the Deno handlers, where a request is a Fetch
 * `Request` and headers are a `Headers` with `.get()`. This service is Express,
 * where `req.headers` is a plain lower-cased object and has no `.get()` -- so
 * the original line would have thrown TypeError the first time Telegram ever
 * called us.
 *
 * It was never caught because nothing called it: the webhook route did not
 * exist, and telegram-auth.test.mjs builds a real `Request` to test with. A test
 * that exercises a shape production never presents is not covering the code, it
 * is covering the test.
 *
 * Both shapes are accepted rather than the Express one alone, so the inherited
 * tests keep their meaning and a future Deno-shaped caller is not broken.
 */
function readHeader(req, name) {
  // Express: req.get() is case-insensitive.
  if (typeof req?.get === "function") return req.get(name) ?? null;
  // Fetch: Headers.get(), also case-insensitive.
  if (typeof req?.headers?.get === "function") return req.headers.get(name) ?? null;
  // Plain object, as req.headers is under Express. Node lower-cases them.
  const bag = req?.headers;
  if (bag && typeof bag === "object") return bag[name.toLowerCase()] ?? null;
  return null;
}

export function verifyWebhookSecret(req, expected) {
  if (!expected) {
    return {
      ok: false,
      reason:
        "no webhook secret is configured, so no request can be authenticated. Set TELEGRAM_WEBHOOK_SECRET and re-run setup-telegram-webhook.",
    };
  }

  const presented = readHeader(req, "X-Telegram-Bot-Api-Secret-Token");

  if (!presented) {
    return {
      ok: false,
      reason:
        "no X-Telegram-Bot-Api-Secret-Token header. Either this is not Telegram, or the webhook was registered without a secret_token -- re-run setup-telegram-webhook.",
    };
  }

  if (!timingSafeEqual(presented, expected)) {
    return { ok: false, reason: "webhook secret does not match" };
  }

  return { ok: true };
}

/** @typedef {{id: number, username?: string, first_name?: string, last_name?: string}} TelegramUser */

/**
 * Verify a Telegram Mini App initData payload and return the user it proves.
 *
 * The algorithm is Telegram's, and every step of it matters:
 *
 *   secret_key       = HMAC_SHA256(key: "WebAppData", message: bot_token)
 *   data_check_string = every field except `hash`, as "k=v", sorted by key,
 *                       joined with newlines
 *   expected         = HMAC_SHA256(key: secret_key, message: data_check_string)
 *
 * Note the inversion in the first line -- "WebAppData" is the KEY and the bot
 * token is the MESSAGE. Getting that backwards produces a function that is
 * wrong for every input, which at least fails loudly.
 *
 * auth_date is checked too. Without a freshness window a captured initData
 * works forever, which turns a single leaked payload into a permanent
 * credential for that account.
 */
export async function verifyInitData(initData, botToken, maxAgeSeconds = 86400) {
  if (!initData) return { ok: false, reason: "no initData supplied" };
  if (!botToken) return { ok: false, reason: "no bot token configured" };

  const params = new URLSearchParams(initData);
  const hash = params.get("hash");
  if (!hash) return { ok: false, reason: "initData has no hash field" };

  params.delete("hash");

  const dataCheckString = [...params.entries()]
    .map(([k, v]) => `${k}=${v}`)
    .sort()
    .join("\n");

  const encoder = new TextEncoder();

  const secretKeyMaterial = await crypto.subtle.importKey(
    "raw",
    encoder.encode("WebAppData"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const secretKey = await crypto.subtle.sign(
    "HMAC",
    secretKeyMaterial,
    encoder.encode(botToken),
  );

  const signingKey = await crypto.subtle.importKey(
    "raw",
    secretKey,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    "HMAC",
    signingKey,
    encoder.encode(dataCheckString),
  );

  const computed = Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (!timingSafeEqual(computed, hash)) {
    return { ok: false, reason: "initData signature does not match" };
  }

  const authDate = Number(params.get("auth_date") ?? 0);
  if (!authDate) return { ok: false, reason: "initData has no auth_date" };

  const age = Math.floor(Date.now() / 1000) - authDate;
  if (age > maxAgeSeconds) {
    return {
      ok: false,
      reason: `initData is ${age}s old, older than the ${maxAgeSeconds}s window`,
    };
  }
  // A payload dated in the future is either a clock problem or a forgery
  // attempt; neither is a request to serve.
  if (age < -300) {
    return { ok: false, reason: "initData auth_date is in the future" };
  }

  const rawUser = params.get("user");
  if (!rawUser) return { ok: false, reason: "initData has no user field" };

  /** @type {TelegramUser} */
  let user;
  try {
    user = JSON.parse(rawUser);
  } catch {
    return { ok: false, reason: "initData user field is not valid JSON" };
  }

  if (typeof user.id !== "number") {
    return { ok: false, reason: "initData user has no numeric id" };
  }

  return { ok: true, user };
}

/**
 * Verify a Telegram LOGIN WIDGET payload and return the user it proves.
 *
 * This is the desktop counterpart to verifyInitData, and the two look almost
 * identical while differing in the one line that matters:
 *
 *   Mini App        secret_key = HMAC_SHA256(key: "WebAppData", message: bot_token)
 *   Login Widget    secret_key = SHA256(bot_token)
 *
 * A PLAIN HASH, not an HMAC, and no "WebAppData" anywhere. Reusing the Mini App
 * derivation here produces a verifier that rejects every genuine login, and --
 * far worse if the mistake went the other way -- reusing this one for initData
 * would accept payloads Telegram never signed for a Mini App. They are separate
 * functions rather than one with a flag for exactly that reason: a boolean
 * parameter deciding which key derivation to use is a boolean somebody
 * eventually passes wrong.
 *
 * The rest is the same algorithm: every field except `hash`, as "k=v", sorted
 * by key, joined with newlines, HMAC'd under that secret.
 *
 * FIELDS ARE TOP-LEVEL HERE. initData nests the user as a JSON string under
 * `user`; the widget sends id, first_name, username and so on directly. Parsing
 * one as the other silently yields no user.
 *
 * A MUCH SHORTER FRESHNESS WINDOW than initData's, deliberately. A Mini App
 * payload is minted once and reused for the whole session, so it needs a day. A
 * widget payload is handed to the page and posted immediately, so anything older
 * than a few minutes is a replay rather than a slow user. The window is the
 * whole replay defence -- Telegram signs no nonce, so a captured payload is a
 * permanent credential for that account until it expires.
 *
 * @param {Record<string, string|number>} payload
 */
export async function verifyLoginWidget(payload, botToken, maxAgeSeconds = 300) {
  if (!payload || typeof payload !== "object") {
    return { ok: false, reason: "no login payload supplied" };
  }
  if (!botToken) return { ok: false, reason: "no bot token configured" };

  const hash = payload.hash;
  if (typeof hash !== "string" || !hash) {
    return { ok: false, reason: "login payload has no hash field" };
  }

  const dataCheckString = Object.keys(payload)
    .filter((k) => k !== "hash")
    .sort()
    .map((k) => `${k}=${payload[k]}`)
    .join("\n");

  const enc = new TextEncoder();

  // SHA256 of the bot token, used directly as the HMAC key. See the header --
  // this is the line that differs from the Mini App path.
  const secretKey = await crypto.subtle.digest("SHA-256", enc.encode(botToken));

  const key = await crypto.subtle.importKey(
    "raw",
    secretKey,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign("HMAC", key, enc.encode(dataCheckString));
  const computed = [...new Uint8Array(signature)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");

  if (!timingSafeEqual(computed, hash)) {
    return { ok: false, reason: "login payload signature does not match" };
  }

  const authDate = Number(payload.auth_date ?? 0);
  if (!authDate) return { ok: false, reason: "login payload has no auth_date" };

  const age = Math.floor(Date.now() / 1000) - authDate;
  if (age > maxAgeSeconds) {
    return {
      ok: false,
      reason: `login payload is ${age}s old, older than the ${maxAgeSeconds}s window`,
    };
  }
  if (age < -300) {
    return { ok: false, reason: "login payload auth_date is in the future" };
  }

  const id = Number(payload.id);
  if (!Number.isFinite(id) || id <= 0) {
    return { ok: false, reason: "login payload has no numeric id" };
  }

  return {
    ok: true,
    user: {
      id,
      username: typeof payload.username === "string" ? payload.username : undefined,
      first_name: typeof payload.first_name === "string" ? payload.first_name : undefined,
      last_name: typeof payload.last_name === "string" ? payload.last_name : undefined,
    },
  };
}

/**
 * CORS headers locked to one origin.
 *
 * Every function in this project sent `Access-Control-Allow-Origin: *`,
 * including the ones that move money. `*` means any page on the internet can
 * make a browser issue these requests.
 *
 * Falls back to "null" rather than "*" when no origin is configured: a
 * misconfiguration should fail closed, not silently restore the thing being
 * fixed.
 */
export function corsHeaders() {
  // globalThis.Deno rather than a bare reference, so the Node test can import
  // this module without the whole file failing to load.
  const allowed = globalThis.Deno?.env.get("ALLOWED_ORIGIN") ?? "null";

  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers":
      "Content-Type, Authorization, X-Client-Info, Apikey, X-Telegram-Init-Data",
    "Vary": "Origin",
  };
}
