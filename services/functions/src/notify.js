/**
 * Telling the operator that money is waiting, at the moment it starts waiting.
 *
 * WHY THIS EXISTS.
 *
 * A deposit claim was found on a player's screen reading
 *
 *   Deposit · Telebirr    0.10    pending    1d ago
 *
 * against a zero balance, while the form promised "usually within a few
 * minutes". Nothing was broken -- the queue, the RLS policy and the route all
 * worked. There was no signal that anything was in it.
 *
 * modules/monitoring answered that with an alarm on the OLDEST pending claim,
 * and deliberately set it to four hours: short enough that a claim does not sit
 * for a day, long enough that a solo operator is not paged through the night for
 * every overnight deposit. Its own comment says what it is waiting for --
 *
 *   "This is the backstop underneath a per-claim notification, not a
 *    replacement for one. When the Telegram bot exists, notify the operator per
 *    claim and this can be raised further."
 *
 * This is that per-claim notification. The alarm stays as the backstop: it
 * answers "is anybody looking at the queue at all", which a per-claim message
 * cannot, because a message nobody reads produces no alarm.
 *
 * FIRE AND FORGET, AND THAT IS THE WHOLE CONTRACT.
 *
 * Notifying is not part of filing a claim. A player's deposit must not fail,
 * slow down, or roll back because api.telegram.org is unreachable from an
 * Ethiopian-hosted container at that moment -- the claim is already committed
 * and the operator has an alarm underneath. So every path here swallows its own
 * errors into the log and returns nothing the caller is expected to await.
 *
 * It is also why this is called AFTER the response is sent, not before.
 */

/** One implementation, shared with src/alerts.js, so a fix reaches both. */
export async function sendTelegramMessage(fetchImpl, botToken, chatId, text, replyMarkup) {
  const res = await fetchImpl(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: chatId,
      text,
      disable_web_page_preview: true,
      // Omitted entirely when absent: Telegram rejects reply_markup: null.
      ...(replyMarkup ? { reply_markup: replyMarkup } : {}),
    }),
  });

  if (!res.ok) {
    const detail = await res.text().catch(() => '');
    throw new Error(`telegram sendMessage HTTP ${res.status}: ${detail.slice(0, 300)}`);
  }
}

/**
 * @param {object}   opts
 * @param {string}   [opts.botToken]
 * @param {string}   [opts.chatId]     absent disables notifying, not the route
 * @param {Function} [opts.fetchImpl]
 * @param {Function} [opts.log]
 */
export function createOperatorNotifier({ botToken, chatId, fetchImpl = fetch, log } = {}) {
  const configured = Boolean(botToken && chatId);

  /**
   * Never throws, never rejects, never returns a promise the caller must
   * handle. Deliberately: the call site is on the path of a player's money and
   * has already answered them.
   */
  function notify(text) {
    if (!configured) return;

    sendTelegramMessage(fetchImpl, botToken, chatId, text).catch((err) => {
      // Logged, not raised. The claim is committed either way, and the
      // pending-deposit alarm is the backstop for exactly this case.
      log?.('warn', 'operator notification failed', { error: err.message });
    });
  }

  return {
    /** Whether a chat id is configured, so callers can log the gap once. */
    enabled: configured,

    depositClaimed({ telegramUserId, amount, bank, reference }) {
      notify(
        [
          '💰 Deposit claim waiting',
          '',
          // The token carries { uid, telegramUserId, role } and no username, so
          // the id is what identifies them here. The panel shows @username when
          // the operator opens it to act, which is the moment that matters.
          `player ${telegramUserId}`,
          `${amount} birr via ${bank}`,
          `ref ${reference}`,
          '',
          'Check your bank statement, then approve or reject in the admin panel.',
        ].join('\n'),
      );
    },

    withdrawalRequested({ telegramUserId, amount, bank, accountNumber }) {
      notify(
        [
          '🏧 Withdrawal requested',
          '',
          `player ${telegramUserId}`,
          `${amount} birr to ${bank}`,
          // Last four only. This lands in a chat that may be read on an unlocked
          // phone, and the operator does not need the full number to recognise
          // the request -- they will see it in the panel when they act on it.
          `account ...${String(accountNumber ?? '').slice(-4)}`,
          '',
          'This is money owed. Send it, then record the payout reference.',
        ].join('\n'),
      );
    },
  };
}
