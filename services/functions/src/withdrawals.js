/**
 * Bank withdrawals: the player side and the operator side.
 *
 * The mirror of deposits.js, against the correctness layer db/20-post/007
 * already built. That file did the hard part — the row lock, the available-
 * balance calculation, the freeze trigger, the unique payout reference. These
 * routes exist because all three of its functions are SECURITY DEFINER, take an
 * identity as an ordinary parameter, and were therefore revoked from
 * `authenticated`. This is their only caller.
 *
 * WHY THESE ARE ROUTES AND NOT PostgREST.
 *
 * Reading your own requests IS plain data access — 007 gives `authenticated` a
 * SELECT policy scoped through telegram_users, so the Mini App fetches its own
 * history straight from PostgREST and there is deliberately no route for it.
 *
 * Creating one is not, and 007 says so in a comment rather than leaving it
 * implied: src/components/BankWithdrawalModal.tsx inserts into
 * withdrawal_requests directly from the browser, which fails on RLS today and
 * should keep failing. A client-side insert sets telegram_user_id and amount
 * with no balance check and no serialisation, so a player could file against
 * somebody else's balance, or ten against their own at once. That modal is
 * rewritten to call this route.
 *
 * Completing is not, obviously: complete_bank_withdrawal takes an admin id and
 * does not verify it.
 *
 * THE ASYMMETRY WITH DEPOSITS, because it decides how strict these are.
 *
 * A deposit credited wrongly costs the house what the player did not send. A
 * withdrawal PAID twice is real money out of a real bank account, and a TeleBirr
 * transfer does not reverse. So two things are required rather than defaulted
 * here — the payout reference on completion, and the amount on request — and
 * both database-level duplicate guards are surfaced as a 409 the operator can
 * act on rather than as a 500 they have to go and read logs about.
 *
 * WHAT THE OPERATOR IS ACTUALLY DOING: sending money from their own account, by
 * hand, and then recording that they did. The queue is a worklist, not an
 * instruction. `payoutReference` is their own transfer's receipt, which is what
 * makes "did we pay this" answerable later without trusting memory.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** withdrawal_requests.amount is numeric(10,2), so this is the column's ceiling. */
const MAX_AMOUNT = 99_999_999.99;

/**
 * Money, validated against the column that will hold it.
 *
 * Two decimal places, because numeric(10,2) SILENTLY ROUNDS anything longer.
 * A request for 10.005 would be stored as 10.01 and the player would be told
 * they asked for something they did not — small, but it is the ledger, and the
 * whole point of 007 is that these numbers reconcile.
 *
 * Rejecting rather than rounding here means the disagreement surfaces at the
 * edge, where it can be answered, instead of inside the database where nobody
 * looks.
 */
function isPayableAmount(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return false;
  if (value <= 0 || value > MAX_AMOUNT) return false;
  // Round to cents and compare against the original. Written this way round --
  // divide back and compare to `value` -- rather than comparing two roundings of
  // the same product, which is a tautology that accepts everything.
  //
  // Floating point makes this less obvious than it looks: 10.005 * 100 is
  // 1000.4999999999999, so it rounds DOWN to 10 and is rejected, while
  // 10.01 * 100 is 1001.0000000000001 and survives the round trip. Both are the
  // answers we want, but only because the comparison is against the input.
  return Math.round(value * 100) / 100 === value;
}

/**
 * The destination is transcribed by hand from a bank app or an SMS, so it
 * arrives with stray spaces. Trimmed here; 007 trims again on insert, which is
 * deliberate belt-and-braces rather than duplication — the function is callable
 * from psql too.
 */
export function validateWithdrawalRequest(body) {
  const bankOptionId = body?.bankOptionId;
  const amount = body?.amount;
  const accountNumber = typeof body?.accountNumber === 'string' ? body.accountNumber.trim() : '';
  const accountName = typeof body?.accountName === 'string' ? body.accountName.trim() : '';

  if (typeof bankOptionId !== 'string' || !UUID_RE.test(bankOptionId)) {
    return { ok: false, error: 'bankOptionId must be a uuid' };
  }
  if (!isPayableAmount(amount)) {
    return { ok: false, error: 'amount must be a positive number with at most 2 decimal places' };
  }
  // 34 is the IBAN maximum. An Ethiopian account number is well inside it and a
  // TeleBirr destination is a phone number, so this bounds the field without
  // guessing at a format that varies by bank.
  if (accountNumber.length < 4 || accountNumber.length > 34) {
    return { ok: false, error: 'accountNumber must be between 4 and 34 characters' };
  }
  if (accountName.length < 2 || accountName.length > 100) {
    return { ok: false, error: 'accountName must be between 2 and 100 characters' };
  }

  return { ok: true, bankOptionId, amount, accountNumber, accountName };
}

/**
 * The Telegram id from the verified token, as something safe to hand a bigint
 * parameter.
 *
 * The claim is a STRING — auth.js sets it with String(user.telegram_user_id),
 * because a Telegram id exceeds what JSON numbers represent exactly. node-pg
 * passes it through as text and PostgreSQL casts, so a non-numeric value would
 * surface as a cast error from inside the function rather than as a bad request.
 * Checked here so it is the latter.
 */
function telegramIdFrom(req) {
  const raw = req.auth?.telegramUserId;
  return typeof raw === 'string' && /^[0-9]{1,19}$/.test(raw) ? raw : null;
}

/**
 * GET /withdrawals/available — what this player may currently ask for.
 *
 * A route rather than a client-side subtraction, and rather than exposing
 * get_available_balance() to `authenticated`.
 *
 * The SPA could compute this: it can read its own telegram_users row and its own
 * pending requests. It should not. The number the player is shown and the number
 * request_bank_withdrawal() enforces must come from the same expression, or the
 * form offers an amount the server then refuses — which reads as a bug in the
 * game rather than as the race it is.
 *
 * Exposing the function to `authenticated` instead would mean an RPC that takes
 * a telegram id and does not check it, which is the class db/20-post/004 exists
 * to close. This runs as app_service and passes the id from the token.
 */
export function createAvailableBalanceHandler(pool) {
  return async function available(req, res) {
    const telegramUserId = telegramIdFrom(req);
    if (!telegramUserId) {
      return res.status(400).json({ success: false, error: 'token carries no telegram id' });
    }

    const { rows } = await pool.query('SELECT get_available_balance($1) AS available', [
      telegramUserId,
    ]);

    // The function returns 0 rather than NULL for an unknown user, so this is
    // only defensive against the row being deleted mid-session.
    const value = rows[0]?.available ?? 0;

    return res.json({ success: true, available: Number(value) });
  };
}

/**
 * POST /withdrawals/request  { bankOptionId, amount, accountNumber, accountName }
 *
 * The bank must be one WE publish and still accept, resolved from
 * withdrawal_bank_options rather than taken from the request — the same
 * reasoning as the deposit claim. A request naming a bank we do not pay out to
 * is one the operator has to notice and refuse by hand.
 */
export function createRequestWithdrawalHandler(pool, notifier) {
  return async function request(req, res) {
    const parsed = validateWithdrawalRequest(req.body);
    if (!parsed.ok) return res.status(400).json({ success: false, error: parsed.error });

    const telegramUserId = telegramIdFrom(req);
    if (!telegramUserId) {
      return res.status(400).json({ success: false, error: 'token carries no telegram id' });
    }

    const client = await pool.connect();
    try {
      const { rows: banks } = await client.query(
        'SELECT id, bank_name FROM withdrawal_bank_options WHERE id = $1 AND is_active',
        [parsed.bankOptionId],
      );

      if (banks.length === 0) {
        return res.status(400).json({ success: false, error: 'unknown or inactive bank option' });
      }

      const { rows } = await client.query(
        'SELECT request_bank_withdrawal($1, $2, $3, $4, $5) AS result',
        [
          telegramUserId,
          parsed.amount,
          banks[0].bank_name,
          parsed.accountNumber,
          parsed.accountName,
        ],
      );

      const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

      if (!result.success) {
        req.log?.warn?.({
          event: 'withdrawal_request_refused',
          uid: req.auth.uid,
          reason: result.error_code,
        });
        return res.status(requestFailureStatus(result.error_code)).json(result);
      }

      // Filing a request does not move money — 007 deducts at payout, not here —
      // but it is the start of a payout, so it is logged with the same weight as
      // the deposit claim it mirrors.
      req.log?.warn?.({
        event: 'withdrawal_requested',
        request_id: result.request_id,
        uid: req.auth.uid,
        amount: parsed.amount,
        bank: banks[0].bank_name,
      });

      res.status(201).json(result);

      // After the response and not awaited, for the same reason as the deposit
      // claim: this is money the player is owed and the request is already
      // recorded. A notification failure must not become their error.
      notifier?.withdrawalRequested({
        telegramUserId: req.auth.telegramUserId,
        amount: parsed.amount,
        bank: banks[0].bank_name,
        accountNumber: parsed.accountNumber,
      });
      return;
    } finally {
      client.release();
    }
  };
}

/**
 * INSUFFICIENT_BALANCE is a 409, not a 400.
 *
 * The request is well-formed; it conflicts with state the client did not know
 * about — most often the player's own earlier request still sitting in the
 * queue. 007 returns `available`, `won_balance` and `already_pending` alongside
 * it precisely so the form can re-render with the real number rather than just
 * saying no. A 400 would invite the client to treat it as a validation bug.
 */
function requestFailureStatus(code) {
  if (code === 'INSUFFICIENT_BALANCE') return 409;
  // The token proved this player exists, so the row having vanished is not a
  // malformed request. Distinguished so it is greppable if it ever happens.
  if (code === 'USER_NOT_FOUND') return 404;
  return 400;
}

/**
 * GET /admin/withdrawals?status=pending — the operator's payout worklist.
 *
 * Joined to telegram_users so the operator sees who they are paying and what
 * that player's balance is, without a second lookup. Runs as app_service, which
 * bypasses RLS; the authorization is requireAdmin on the route.
 */
export function createListWithdrawalsHandler(pool) {
  return async function listWithdrawals(req, res) {
    const status = req.query?.status ?? 'pending';
    if (!['pending', 'processing', 'completed', 'rejected'].includes(status)) {
      return res
        .status(400)
        .json({ error: 'status must be pending, processing, completed or rejected' });
    }

    const limit = Math.min(Number(req.query?.limit) || 50, 200);

    const { rows } = await pool.query(
      `SELECT w.id, w.amount, w.bank_name, w.account_number, w.account_name,
              w.status, w.requested_at, w.processed_at, w.payout_reference,
              w.rejection_reason, w.admin_notes,
              u.telegram_user_id, u.telegram_username, u.telegram_first_name,
              u.won_balance
         FROM withdrawal_requests w
         JOIN telegram_users u ON u.telegram_user_id = w.telegram_user_id
        WHERE w.status = $1
        ORDER BY w.requested_at ASC
        LIMIT $2`,
      [status, limit],
    );

    // Oldest first, as with deposits: a queue people wait in should be served in
    // the order they joined it, so an operator working top-down is fair by
    // default rather than by discipline. It matters more here — this is somebody
    // waiting to be paid.
    return res.json({ status, count: rows.length, requests: rows });
  };
}

/**
 * POST /admin/withdrawals/:id/complete  { payoutReference, note }
 *
 * Called AFTER the operator has actually sent the money.
 *
 * `payoutReference` is REQUIRED and is not defaulted to anything. It is the
 * receipt for a transfer that has already left a real bank account, and 007 puts
 * a unique index on lower(payout_reference) so that recording the same receipt
 * against two requests is refused by the database. Defaulting it — to the
 * request id, to a timestamp, to anything generated — would make every payout
 * trivially unique and disarm that index completely.
 */
export function createCompleteWithdrawalHandler(pool) {
  return async function complete(req, res) {
    const id = req.params?.id;
    if (typeof id !== 'string' || !UUID_RE.test(id)) {
      return res.status(400).json({ success: false, error: 'id must be a uuid' });
    }

    const reference =
      typeof req.body?.payoutReference === 'string' ? req.body.payoutReference.trim() : '';

    if (reference.length < 3 || reference.length > 64) {
      return res.status(400).json({
        success: false,
        error: 'payoutReference is required — enter the reference from the transfer you sent',
      });
    }

    const note = typeof req.body?.note === 'string' ? req.body.note.slice(0, 500) : null;

    let result;
    try {
      const { rows } = await pool.query(
        'SELECT complete_bank_withdrawal($1, $2, $3, $4) AS result',
        [id, req.auth.uid, reference, note],
      );
      result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };
    } catch (err) {
      // 23505 is the unique payout_reference index: this receipt has already
      // been recorded against some request. That is the control which stops one
      // transfer being counted as two payouts, so it must reach the operator as
      // something they can act on rather than as a 500.
      if (err.code === '23505') {
        req.log?.warn?.({
          event: 'duplicate_payout_reference',
          request_id: id,
          admin_uid: req.auth.uid,
        });
        return res.status(409).json({
          success: false,
          error_code: 'DUPLICATE_REFERENCE',
          error: 'That payout reference is already recorded against another request.',
        });
      }

      // 23514 is either the freeze trigger (a decided request being re-decided)
      // or the overdraft guard inside complete_bank_withdrawal. 007 raises rather
      // than returning on the latter deliberately: a silent negative balance is
      // worse than a failed payout somebody has to look at. Surfacing the message
      // is the point — this is the one the operator must actually read.
      if (err.code === '23514') {
        req.log?.error?.({
          event: 'withdrawal_complete_refused_by_constraint',
          request_id: id,
          admin_uid: req.auth.uid,
          detail: err.message,
        });
        return res.status(409).json({
          success: false,
          error_code: 'CONSTRAINT_VIOLATION',
          error: err.message,
        });
      }

      throw err;
    }

    if (!result.success) {
      // NOT_PENDING covers "already decided" and "does not exist" alike, and is
      // a conflict rather than an error: it is what a double-clicked button and
      // a second operator both produce. The correct response is to reload the
      // queue, not to retry.
      const code = result.error_code === 'NOT_PENDING' ? 409 : 400;
      req.log?.warn?.({ event: 'complete_refused', request_id: id, reason: result.error_code });
      return res.status(code).json(result);
    }

    // The most consequential log line this service writes. Money has already
    // left a bank account by the time this runs, and the balance has just moved
    // to match. Logged at warn so it stands out in CloudWatch without a filter,
    // as the second copy of an audit trail the row already carries.
    req.log?.warn?.({
      event: 'withdrawal_completed',
      request_id: id,
      admin_uid: req.auth.uid,
      paid: result.paid,
      telegram_user_id: result.telegram_user_id,
      payout_reference: reference,
    });

    return res.json(result);
  };
}

/**
 * POST /admin/withdrawals/:id/reject  { reason }
 *
 * No balance change: 007 deducts nothing at request time, so there is nothing to
 * refund. The request simply stops counting against available balance, which
 * removes the whole class of refund-went-wrong bugs.
 *
 * `reason` is required here where the deposit path's note is optional. A
 * rejected payout is a player being told no about their own winnings, and
 * "rejected" with no reason is the version of that which generates a support
 * message nobody can answer.
 */
export function createRejectWithdrawalHandler(pool) {
  return async function reject(req, res) {
    const id = req.params?.id;
    if (typeof id !== 'string' || !UUID_RE.test(id)) {
      return res.status(400).json({ success: false, error: 'id must be a uuid' });
    }

    const reason = typeof req.body?.reason === 'string' ? req.body.reason.trim().slice(0, 500) : '';
    if (reason.length < 3) {
      return res.status(400).json({
        success: false,
        error: 'reason is required — the player is shown this',
      });
    }

    const { rows } = await pool.query('SELECT reject_bank_withdrawal($1, $2, $3) AS result', [
      id,
      req.auth.uid,
      reason,
    ]);

    const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

    if (!result.success) {
      return res.status(result.error_code === 'NOT_PENDING' ? 409 : 400).json(result);
    }

    req.log?.warn?.({ event: 'withdrawal_rejected', request_id: id, admin_uid: req.auth.uid });
    return res.json(result);
  };
}
