/**
 * Tests for the operator notifier.
 *
 * The assertion that matters is NOT that a message is formatted nicely. It is
 * that notifying can never damage the thing it is notifying about:
 *
 *   - a Telegram outage must not reject, throw, or produce an unhandled
 *     rejection, because the call site has already committed a player's deposit
 *     and answered them
 *   - an unconfigured chat id must be a no-op, not an error
 *   - the full bank account number must not be sent to a chat
 *
 * Run: node src/notify.test.mjs
 */

import { createOperatorNotifier } from './notify.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

console.log('\noperator notifier');

const capture = ({ ok = true } = {}) => {
  const sent = [];
  const impl = async (url, init) => {
    sent.push({ url, body: JSON.parse(init.body) });
    return { ok, status: ok ? 200 : 500, text: async () => 'err' };
  };
  impl.sent = sent;
  return impl;
};

// --- the happy path -------------------------------------------------------
{
  const f = capture();
  const n = createOperatorNotifier({ botToken: 'tok', chatId: '42', fetchImpl: f });

  n.depositClaimed({ telegramUserId: 424946351, amount: 50, bank: 'Telebirr', reference: 'Fhhg' });
  await sleep(10);

  check('sends one message', f.sent.length === 1);
  check('to the configured chat', f.sent[0].body.chat_id === '42');
  check('naming the amount and bank', /50 birr via Telebirr/.test(f.sent[0].body.text));
  check('and the reference the operator matches against', /Fhhg/.test(f.sent[0].body.text));
  check('using the bot token', f.sent[0].url.includes('/bottok/sendMessage'));
}

// --- the account number is truncated --------------------------------------
{
  const f = capture();
  const n = createOperatorNotifier({ botToken: 'tok', chatId: '42', fetchImpl: f });

  n.withdrawalRequested({
    telegramUserId: 1, amount: 100, bank: 'CBE', accountNumber: '1000123456789',
  });
  await sleep(10);

  const text = f.sent[0].body.text;
  check('shows only the last four digits', text.includes('...6789'));
  check(
    'and NOT the full account number -- this lands on a phone screen',
    text.includes('1000123456789') === false,
  );
}

// --- a Telegram outage must not touch the caller --------------------------
//
// The call site has already committed a deposit and answered the player. If
// this can reject, an unreachable Telegram becomes their failed deposit.
{
  const f = capture({ ok: false });
  const logged = [];
  const n = createOperatorNotifier({
    botToken: 'tok', chatId: '42', fetchImpl: f,
    log: (level, msg) => logged.push(`${level}:${msg}`),
  });

  let threw = false;
  let unhandled = null;
  const onUnhandled = (err) => { unhandled = err; };
  process.on('unhandledRejection', onUnhandled);

  try { n.depositClaimed({ telegramUserId: 1, amount: 1, bank: 'X', reference: 'r' }); }
  catch { threw = true; }
  await sleep(30);
  process.off('unhandledRejection', onUnhandled);

  check('a failing send does not throw', threw === false);
  check('and produces NO unhandled rejection', unhandled === null);
  check('but is logged', logged.some((l) => l.startsWith('warn:')));
}

// --- a thrown fetch (DNS failure, offline) --------------------------------
{
  const boom = async () => { throw new Error('getaddrinfo ENOTFOUND api.telegram.org'); };
  const logged = [];
  const n = createOperatorNotifier({
    botToken: 'tok', chatId: '42', fetchImpl: boom,
    log: (level, msg) => logged.push(`${level}:${msg}`),
  });

  let unhandled = null;
  const onUnhandled = (err) => { unhandled = err; };
  process.on('unhandledRejection', onUnhandled);
  n.withdrawalRequested({ telegramUserId: 1, amount: 1, bank: 'X', accountNumber: '1234' });
  await sleep(30);
  process.off('unhandledRejection', onUnhandled);

  check('a network failure is swallowed too', unhandled === null);
  check('and logged', logged.length === 1);
}

// --- unconfigured ---------------------------------------------------------
{
  const f = capture();
  const n = createOperatorNotifier({ botToken: 'tok', chatId: undefined, fetchImpl: f });
  check('reports itself disabled', n.enabled === false);
  n.depositClaimed({ telegramUserId: 1, amount: 1, bank: 'X', reference: 'r' });
  await sleep(10);
  check('and sends nothing rather than erroring', f.sent.length === 0);
}

console.log(failures ? `\n${failures} assertion(s) failed.` : '\nAll notifier tests passed.');
process.exit(failures ? 1 : 0);
