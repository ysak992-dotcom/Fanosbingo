/**
 * POST /telegram/webhook — Telegram's servers calling us.
 *
 * WHY THIS EXISTS: /start to the bot did nothing. A player who found
 * @BingoNovaaBot and messaged it got silence, which for a Telegram-first product
 * is the front door being locked.
 *
 * AUTHENTICATION IS THE SECRET TOKEN, AND IT IS STRICT.
 *
 * Telegram does not sign webhook updates. It echoes a secret chosen at
 * registration time in X-Telegram-Bot-Api-Secret-Token, and that header is the
 * only thing separating "Telegram" from "anybody who guessed the URL".
 *
 * A missing header is REFUSED, not tolerated. "Verify it if present" is no check
 * at all here, because a forger simply omits it -- which is exactly what the
 * inherited Deno version did: it registered the webhook with no secret_token and
 * checked nothing, so anyone who knew the URL could forge an update and
 * impersonate any player to the bot.
 *
 * ORDER OF DEPLOYMENT MATTERS, and reversing it takes the bot silent:
 *
 *   1. deploy this route (it refuses everything until registration happens)
 *   2. run scripts/register-telegram-webhook.sh, which registers WITH a
 *      secret_token so Telegram starts sending the header
 *
 * That order is safe here because no webhook is registered today, so there is
 * nothing to break. If one already existed, registration would have to come
 * first -- see the header of src/telegram-auth.js.
 *
 * ALWAYS ANSWERS 200 ONCE AUTHENTICATED.
 *
 * Telegram retries a non-2xx update, with backoff, for a long time. An error
 * while handling one message would therefore turn into that message being
 * redelivered indefinitely. Whatever goes wrong inside is logged and swallowed;
 * only an UNAUTHENTICATED request gets a non-2xx, because that one should not be
 * encouraged to retry either but must not be silently accepted.
 */

import { verifyWebhookSecret } from './telegram-auth.js';
import { sendTelegramMessage } from './notify.js';

/**
 * Where to send a player who says /start.
 *
 * Read from settings so the operator can change it without a deploy -- the
 * admin panel already writes `game_url`. Falls back to the app origin, which is
 * always correct even if slightly worse: a t.me link opens inside Telegram,
 * where a bare https link opens a browser.
 */
async function resolveGameUrl(pool, fallback) {
  try {
    const { rows } = await pool.query(
      "SELECT value FROM settings WHERE key = 'game_url' LIMIT 1",
    );
    const url = typeof rows[0]?.value === 'string' ? rows[0].value.trim() : '';
    return url || fallback;
  } catch {
    // The webhook must answer even when the database does not. A welcome
    // pointing at the app origin is worth more than an unanswered /start.
    return fallback;
  }
}

const WELCOME = (url) =>
  [
    '🎮 Welcome to Fanos Bingo!',
    '',
    'Tap below to open the game and join a round.',
    '',
    url,
    '',
    'Deposit with TeleBirr or CBE, play, and withdraw to your own bank account.',
  ].join('\n');

const HELP = (url) =>
  [
    'Fanos Bingo',
    '',
    `Open the game: ${url}`,
    '',
    'Deposits and withdrawals are handled inside the game.',
    'If a deposit is taking longer than expected, an operator is checking their',
    'bank statement -- it is reviewed by a person, not automatically.',
  ].join('\n');

/**
 * @param {object}   opts
 * @param {object}   opts.pool
 * @param {string}   opts.botToken
 * @param {string}   [opts.webhookSecret]
 * @param {string}   opts.appUrl        fallback for the game link
 * @param {Function} [opts.fetchImpl]
 */
export function createTelegramWebhookHandler({
  pool,
  botToken,
  webhookSecret,
  appUrl,
  fetchImpl = fetch,
}) {
  return async function telegramWebhook(req, res) {
    const verdict = verifyWebhookSecret(req, webhookSecret);

    if (!verdict.ok) {
      // Logged with the reason, answered without it. A forger learns only that
      // they were refused.
      req.log?.warn?.({ event: 'webhook_rejected', reason: verdict.reason });
      return res.status(401).json({ error: 'unauthorized' });
    }

    // Answer FIRST. Telegram redelivers anything that is not 2xx, so a slow or
    // failing reply turns one message into a retry storm. The work below is not
    // something Telegram needs to wait for.
    res.status(200).json({ ok: true });

    try {
      const message = req.body?.message;
      const text = typeof message?.text === 'string' ? message.text.trim() : '';
      const chatId = message?.chat?.id;

      if (!chatId || !text.startsWith('/')) return;

      const command = text.split(/\s+/)[0].split('@')[0].toLowerCase();

      // Only commands this bot actually answers. Anything else is ignored
      // rather than answered with "unknown command" -- a bot that replies to
      // every stray message in a group it was added to is a nuisance.
      if (command !== '/start' && command !== '/help') return;

      const url = await resolveGameUrl(pool, appUrl);
      const body = command === '/start' ? WELCOME(url) : HELP(url);

      await sendTelegramMessage(fetchImpl, botToken, chatId, body);
      req.log?.warn?.({ event: 'webhook_replied', command, chat_id: chatId });
    } catch (err) {
      // Swallowed on purpose: the 200 has already gone, and there is nothing
      // Telegram can usefully do with a failure that happened afterwards.
      req.log?.error?.({ event: 'webhook_handler_failed', error: err.message });
    }
  };
}
