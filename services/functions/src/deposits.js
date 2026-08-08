/**
 * Deposit claims: the player side and the operator side.
 *
 * WHY THESE ARE ROUTES AND NOT PostgREST.
 *
 * Reading your own claims IS plain data access — db/20-post/006 gives
 * `authenticated` a SELECT policy scoped to `player_id = auth.uid()`, so the Mini
 * App fetches its own history straight from PostgREST and there is deliberately
 * no route for it.
 *
 * Creating one is not. An INSERT policy with
 * `WITH CHECK (player_id = auth.uid())` would look sufficient and is not: the row
 * also carries `status`, `credited_amount`, `decided_by` and `decided_at`, so the
 * check would have to pin every one of them as well, and a field added later
 * without updating the policy is a player-writable field on a money record. The
 * server constructing the row means the player supplies exactly three values and
 * cannot reach the rest — the same reasoning as select-card.
 *
 * Approving is not, obviously: `approve_deposit_request` takes an admin id and
 * does not verify it, which is why 006 revoked EXECUTE from `authenticated`.
 *
 * WHAT THE OPERATOR IS ACTUALLY DOING, because the UI should not obscure it:
 * reading their own bank statement and deciding whether the money arrived. The
 * queue is a worklist, not an oracle. Nothing here tells them a claim is genuine
 * — `claimed_amount` is what the player typed, and the whole point of
 * `credited_amount` being a separate field is that the operator types what they
 * actually see.
 */

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Reference numbers are transcribed by hand from an SMS or a receipt, so they
 * arrive with stray spaces and inconsistent case. Trimmed here; the uniqueness
 * index lowercases, so casing is already handled at the database.
 */
export function validateClaim(body) {
  const bankOptionId = body?.bankOptionId;
  const reference = typeof body?.referenceNumber === 'string' ? body.referenceNumber.trim() : '';
  const amount = body?.claimedAmount;

  if (typeof bankOptionId !== 'string' || !UUID_RE.test(bankOptionId)) {
    return { ok: false, error: 'bankOptionId must be a uuid' };
  }
  if (reference.length < 3 || reference.length > 64) {
    return { ok: false, error: 'referenceNumber must be between 3 and 64 characters' };
  }
  if (!Number.isInteger(amount) || amount <= 0) {
    return { ok: false, error: 'claimedAmount must be a positive integer' };
  }
  return { ok: true, bankOptionId, reference, amount };
}

/** POST /deposits/claim — a player says they have transferred money. */
export function createDepositClaimHandler(pool, notifier) {
  return async function claim(req, res) {
    const parsed = validateClaim(req.body);
    if (!parsed.ok) return res.status(400).json({ success: false, error: parsed.error });

    const client = await pool.connect();
    try {
      // The bank must be one WE published and still accept. Taking bank_name from
      // the request instead would let a claim name an account that was never
      // ours, which the operator would then have to disprove.
      const { rows: banks } = await client.query(
        'SELECT id, bank_name FROM bank_options WHERE id = $1 AND is_active',
        [parsed.bankOptionId],
      );

      if (banks.length === 0) {
        return res.status(400).json({ success: false, error: 'unknown or inactive bank option' });
      }

      const { rows } = await client.query(
        `INSERT INTO deposit_requests
           (player_id, bank_option_id, bank_name, reference_number, claimed_amount)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id, status, created_at`,
        [req.auth.uid, banks[0].id, banks[0].bank_name, parsed.reference, parsed.amount],
      );

      res.status(201).json({ success: true, request: rows[0] });

      // AFTER the response, and not awaited. Notifying is not part of filing a
      // claim: the row is committed and the player is answered, so an
      // unreachable api.telegram.org must not turn their deposit into an error.
      // See src/notify.js -- it swallows its own failures into the log, and the
      // pending-deposit alarm remains the backstop.
      notifier?.depositClaimed({
        telegramUserId: req.auth.telegramUserId,
        amount: parsed.amount,
        bank: banks[0].bank_name,
        reference: parsed.reference,
      });
      return;
    } catch (err) {
      // 23505 is the (bank_name, lower(reference_number)) index. It is the
      // control that stops one transfer being credited twice, so it fires on the
      // normal case of a player resubmitting as well as on a second player
      // claiming the same reference. Answered as a conflict with a message the
      // first case can act on; the second is the operator's to notice.
      if (err.code === '23505') {
        req.log?.warn?.({ event: 'duplicate_deposit_reference', uid: req.auth.uid });
        return res.status(409).json({
          success: false,
          error: 'That transaction reference has already been submitted.',
        });
      }
      throw err;
    } finally {
      client.release();
    }
  };
}

/**
 * GET /admin/deposits?status=pending — the operator's worklist.
 *
 * Joined to telegram_users so the operator can see WHO is claiming without a
 * second lookup. Runs as app_service, which bypasses RLS — the authorization is
 * requireAdmin on the route.
 */
export function createListDepositsHandler(pool) {
  return async function listDeposits(req, res) {
    const status = req.query?.status ?? 'pending';
    if (!['pending', 'approved', 'rejected'].includes(status)) {
      return res.status(400).json({ error: 'status must be pending, approved or rejected' });
    }

    const limit = Math.min(Number(req.query?.limit) || 50, 200);

    const { rows } = await pool.query(
      `SELECT d.id, d.bank_name, d.reference_number, d.claimed_amount, d.credited_amount,
              d.status, d.created_at, d.decided_at, d.admin_note,
              u.telegram_user_id, u.telegram_username, u.telegram_first_name,
              u.deposited_balance, u.won_balance
         FROM deposit_requests d
         JOIN telegram_users u ON u.id = d.player_id
        WHERE d.status = $1
        ORDER BY d.created_at ASC
        LIMIT $2`,
      [status, limit],
    );

    // Oldest first for `pending`: a queue people wait in should be served in the
    // order they joined it, and the operator working top-down is then fair by
    // default rather than by discipline.
    return res.json({ status, count: rows.length, requests: rows });
  };
}

/**
 * POST /admin/deposits/:id/approve  { actualAmount, note }
 *
 * `actualAmount` is required and is NOT defaulted to the claimed amount. The
 * whole reason the two are separate columns is that the operator is reading a
 * bank statement; defaulting would quietly turn "what the player typed" into
 * "what we credited" every time somebody pressed the button without looking.
 */
export function createApproveDepositHandler(pool) {
  return async function approve(req, res) {
    const id = req.params?.id;
    if (typeof id !== 'string' || !UUID_RE.test(id)) {
      return res.status(400).json({ success: false, error: 'id must be a uuid' });
    }

    const amount = req.body?.actualAmount;
    if (!Number.isInteger(amount) || amount <= 0) {
      return res.status(400).json({
        success: false,
        error: 'actualAmount is required — enter the amount shown on the statement',
      });
    }

    const note = typeof req.body?.note === 'string' ? req.body.note.slice(0, 500) : null;

    const { rows } = await pool.query(
      'SELECT approve_deposit_request($1, $2, $3, $4) AS result',
      [id, amount, req.auth.uid, note],
    );

    const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

    if (!result.success) {
      // NOT_PENDING covers both "already decided" and "does not exist", and is a
      // conflict rather than an error: it is exactly what a double-clicked button
      // or a second operator produces, and the correct response is to reload the
      // queue rather than to retry.
      const code = result.error_code === 'NOT_PENDING' ? 409 : 400;
      req.log?.warn?.({ event: 'approve_refused', request_id: id, reason: result.error_code });
      return res.status(code).json(result);
    }

    // Logged at warn so it stands out in CloudWatch without a filter. Crediting
    // a balance is the most consequential thing this service does, and the log is
    // the second copy of the audit trail the row already carries.
    req.log?.warn?.({
      event: 'deposit_approved',
      request_id: id,
      admin_uid: req.auth.uid,
      credited: result.credited,
      claimed: result.claimed,
      mismatch: result.credited !== result.claimed,
    });

    return res.json(result);
  };
}

/** POST /admin/deposits/:id/reject  { note } */
export function createRejectDepositHandler(pool) {
  return async function reject(req, res) {
    const id = req.params?.id;
    if (typeof id !== 'string' || !UUID_RE.test(id)) {
      return res.status(400).json({ success: false, error: 'id must be a uuid' });
    }

    const note = typeof req.body?.note === 'string' ? req.body.note.slice(0, 500) : null;

    const { rows } = await pool.query(
      'SELECT reject_deposit_request($1, $2, $3) AS result',
      [id, req.auth.uid, note],
    );

    const result = rows[0]?.result ?? { success: false, error_code: 'INTERNAL_ERROR' };

    if (!result.success) {
      return res.status(result.error_code === 'NOT_PENDING' ? 409 : 400).json(result);
    }

    req.log?.warn?.({ event: 'deposit_rejected', request_id: id, admin_uid: req.auth.uid });
    return res.json(result);
  };
}
