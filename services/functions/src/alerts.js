/**
 * SNS -> Telegram, so an alarm reaches a person rather than an inbox.
 *
 * WHY THIS EXISTS AT ALL, given SMS was the obvious answer.
 *
 * It was wired, applied, and does not deliver. SNS accepted the subscription
 * and reported it active; the send path underneath refuses at the ACCOUNT
 * level, before any phone number is considered:
 *
 *   aws sns get-sms-sandbox-account-status
 *   UserError: The AWS Access Key Id needs a subscription for the service
 *              (Service: PinpointSmsVoiceV2)
 *
 * SNS SMS is delivered by AWS End User Messaging, which this account is not
 * enrolled in -- so it would have failed for a US number identically. Enrolling
 * is not the end of it either: a new account lands in the SMS sandbox, where
 * only pre-verified numbers receive anything, and +251 wants a registered
 * origination identity on top.
 *
 * So the second channel is Telegram, delivered from THIS service rather than a
 * Lambda. That is not the elegant choice, it is the one that cannot recur: a
 * Lambda is another AWS service to be enrolled in, and the failure being fixed
 * is precisely "the service was not enabled and nothing said so". This
 * container already holds the bot token, already runs, and Caddy already routes
 * /functions/v1/* to it.
 *
 * Email stays. This is a SECOND channel, not a replacement -- if this container
 * is the thing that is broken, email is what still arrives.
 *
 * ------------------------------------------------------------------------
 * THIS ROUTE IS UNAUTHENTICATED, AND IT IS ON THE SERVICE THAT MOVES MONEY.
 *
 * SNS cannot present a bearer token, so the signature IS the authentication.
 * Everything below exists because of that, and none of it is optional:
 *
 *   1. VERIFY THE SIGNATURE against Amazon's certificate. Without it, anybody
 *      who learns the URL can post arbitrary alerts. The damage is not merely
 *      spam -- an operator who learns to distrust these messages is worse off
 *      than one who never had them, and an attacker who can forge "all clear"
 *      can mask a real alarm.
 *
 *   2. PIN THE CERTIFICATE HOST. SigningCertURL is attacker-controlled input
 *      until proven otherwise. Fetching whatever it names would let a forger
 *      supply both the signature and the key that validates it, which is the
 *      same as having no check. The host must be sns.<region>.amazonaws.com.
 *
 *   3. PIN THE SUBSCRIBE HOST for the same reason. Confirmation fetches a URL
 *      out of the request body; unpinned, that is a server-side request forgery
 *      primitive pointed at anything the task role can reach.
 *
 *   4. ALLOWLIST THE TOPIC. A valid signature only proves AWS sent it -- any
 *      AWS account can sign a message with their own topic. The TopicArn is
 *      what proves it is OUR alarm.
 *
 * The route answers 200 to anything it accepts and drops, deliberately. SNS
 * retries non-2xx with backoff and eventually disables the subscription, so
 * answering 4xx to a message we chose not to act on would eventually turn the
 * channel off. Refusals are logged, not signalled.
 */

import crypto from 'node:crypto';
// One implementation, shared with the operator notifier, so a fix to the
// Telegram call reaches both rather than one of them.
import { sendTelegramMessage as sendTelegram } from './notify.js';

/** Hosts Amazon signs from. Anything else is a forgery attempt, not a typo. */
const SNS_HOST = /^sns\.[a-z0-9-]+\.amazonaws\.com$/;

/**
 * The fields, and the ORDER, that Amazon signs. This is not alphabetical by
 * accident -- it is a fixed list per message type, and a wrong order produces a
 * signature mismatch on a perfectly genuine message.
 *
 * Subject is included ONLY when present. CloudWatch alarms do send one, but a
 * bare Notification need not, and including an empty value breaks the digest.
 */
const SIGNED_FIELDS = {
  Notification: ['Message', 'MessageId', 'Subject', 'Timestamp', 'TopicArn', 'Type'],
  SubscriptionConfirmation: [
    'Message',
    'MessageId',
    'SubscribeURL',
    'Timestamp',
    'Token',
    'TopicArn',
    'Type',
  ],
  UnsubscribeConfirmation: [
    'Message',
    'MessageId',
    'SubscribeURL',
    'Timestamp',
    'Token',
    'TopicArn',
    'Type',
  ],
};

function stringToSign(msg) {
  const fields = SIGNED_FIELDS[msg.Type];
  if (!fields) return null;

  let out = '';
  for (const field of fields) {
    // `in` rather than a truthiness check: Subject is optional, but an EMPTY
    // subject that was present when signed must still be included.
    if (!(field in msg) || msg[field] === undefined || msg[field] === null) continue;
    out += `${field}\n${msg[field]}\n`;
  }
  return out;
}

/**
 * Fetches and caches Amazon's signing certificate.
 *
 * Cached because a burst of alarms would otherwise fetch the same certificate
 * once per message, and because the fetch is on the path of a message we have
 * not yet authenticated -- an unauthenticated caller should not be able to make
 * us issue outbound requests at will.
 */
function createCertCache(fetchImpl) {
  const certs = new Map();

  return async function getCert(url) {
    const parsed = new URL(url);

    // Pinned. See point 2 in the header.
    if (parsed.protocol !== 'https:' || !SNS_HOST.test(parsed.hostname)) {
      throw new Error(`refusing to fetch a signing certificate from ${parsed.hostname}`);
    }

    const cached = certs.get(url);
    if (cached) return cached;

    const res = await fetchImpl(url);
    if (!res.ok) throw new Error(`certificate fetch failed: HTTP ${res.status}`);
    const pem = await res.text();

    // Bounded, so a compromised or confused endpoint cannot grow this without
    // limit. Amazon rotates certificates rarely; a handful is generous.
    if (certs.size >= 8) certs.clear();
    certs.set(url, pem);
    return pem;
  };
}

/**
 * True only if the message is genuinely from Amazon.
 *
 * SignatureVersion 1 is SHA1, 2 is SHA256. Both are accepted because Amazon
 * still emits 1 for some topics; the version is read from the message rather
 * than assumed, and anything else is refused rather than defaulted.
 */
async function verifySignature(msg, getCert) {
  const payload = stringToSign(msg);
  if (!payload) return { ok: false, reason: 'unknown message type' };

  const algorithm =
    msg.SignatureVersion === '1'
      ? 'RSA-SHA1'
      : msg.SignatureVersion === '2'
        ? 'RSA-SHA256'
        : null;

  if (!algorithm) return { ok: false, reason: `unsupported SignatureVersion ${msg.SignatureVersion}` };
  if (typeof msg.Signature !== 'string') return { ok: false, reason: 'no signature' };

  let pem;
  try {
    pem = await getCert(msg.SigningCertURL);
  } catch (err) {
    return { ok: false, reason: err.message };
  }

  const verifier = crypto.createVerify(algorithm);
  verifier.update(payload, 'utf8');

  let valid = false;
  try {
    valid = verifier.verify(pem, msg.Signature, 'base64');
  } catch (err) {
    return { ok: false, reason: `verify threw: ${err.message}` };
  }

  return valid ? { ok: true } : { ok: false, reason: 'signature mismatch' };
}

/**
 * Renders a CloudWatch alarm as something readable on a phone.
 *
 * PLAIN TEXT, no parse_mode. Telegram's Markdown and HTML modes reject a
 * message whose entities do not balance, so an alarm description containing an
 * underscore or an angle bracket would fail to send -- silently, from the
 * operator's point of view, and precisely when an alarm is firing. The
 * formatting is not worth a delivery failure.
 */
function renderAlarm(body, subject) {
  let alarm;
  try {
    alarm = JSON.parse(body);
  } catch {
    // Not every notification is a CloudWatch alarm. Anything else is passed
    // through rather than dropped -- a message we did not anticipate is still
    // a message somebody chose to send here.
    return `${subject ? subject + '\n\n' : ''}${String(body).slice(0, 3500)}`;
  }

  if (!alarm || typeof alarm !== 'object' || !alarm.AlarmName) {
    return `${subject ? subject + '\n\n' : ''}${String(body).slice(0, 3500)}`;
  }

  const state = alarm.NewStateValue;
  const mark = state === 'ALARM' ? '🔴' : state === 'OK' ? '🟢' : '⚪';

  const lines = [
    `${mark} ${state} — ${alarm.AlarmName}`,
    '',
    alarm.AlarmDescription || '(no description)',
  ];

  if (alarm.NewStateReason) lines.push('', alarm.NewStateReason.slice(0, 800));
  if (alarm.StateChangeTime) lines.push('', alarm.StateChangeTime);

  return lines.join('\n').slice(0, 3900); // Telegram caps a message at 4096.
}


/**
 * @param {object}   opts
 * @param {string}   opts.botToken
 * @param {string}   [opts.chatId]          absent disables sending, not the route
 * @param {string[]} opts.allowedTopicArns  see point 4 in the header
 * @param {Function} [opts.fetchImpl]       injected for tests
 */
export function createSnsAlertHandler({ botToken, chatId, allowedTopicArns, fetchImpl = fetch }) {
  const getCert = createCertCache(fetchImpl);
  const allowed = new Set(allowedTopicArns.filter(Boolean));

  return async function snsAlertHandler(req, res) {
    // SNS posts with Content-Type text/plain, so express.json() leaves this
    // alone and the route parses the raw body itself. A body that is already an
    // object (a test, or a future content-type change) is accepted as-is.
    let msg;
    try {
      msg = typeof req.body === 'string' ? JSON.parse(req.body) : req.body;
    } catch {
      req.log?.warn?.({ event: 'sns_unparseable_body' });
      return res.status(400).json({ error: 'bad request' });
    }

    if (!msg || typeof msg !== 'object' || typeof msg.Type !== 'string') {
      req.log?.warn?.({ event: 'sns_not_a_message' });
      return res.status(400).json({ error: 'bad request' });
    }

    // Topic first: it is a string comparison, where verification costs a
    // network fetch and an RSA operation. An unauthenticated caller should not
    // be able to make us do the expensive one.
    if (!allowed.has(msg.TopicArn)) {
      req.log?.warn?.({ event: 'sns_topic_not_allowed', topic_arn: msg.TopicArn });
      return res.status(200).json({ ok: true });
    }

    const verdict = await verifySignature(msg, getCert);
    if (!verdict.ok) {
      // Logged loudly. A signature failure on an allowlisted topic is either a
      // forgery attempt or a genuine break in this code -- both worth seeing.
      req.log?.error?.({
        event: 'sns_signature_rejected',
        reason: verdict.reason,
        message_id: msg.MessageId,
      });
      return res.status(403).json({ error: 'forbidden' });
    }

    if (msg.Type === 'SubscriptionConfirmation') {
      try {
        const url = new URL(msg.SubscribeURL);
        // Pinned. See point 3 in the header.
        if (url.protocol !== 'https:' || !SNS_HOST.test(url.hostname)) {
          req.log?.error?.({ event: 'sns_subscribe_url_rejected', host: url.hostname });
          return res.status(403).json({ error: 'forbidden' });
        }
        await fetchImpl(msg.SubscribeURL);
        req.log?.warn?.({ event: 'sns_subscription_confirmed', topic_arn: msg.TopicArn });
      } catch (err) {
        req.log?.error?.({ event: 'sns_confirm_failed', error: err.message });
      }
      return res.status(200).json({ ok: true });
    }

    if (msg.Type === 'UnsubscribeConfirmation') {
      // Not acted on, but never silent: this channel going away is exactly the
      // kind of change that should not happen unnoticed.
      req.log?.error?.({ event: 'sns_unsubscribe_received', topic_arn: msg.TopicArn });
      return res.status(200).json({ ok: true });
    }

    if (!chatId) {
      req.log?.warn?.({ event: 'sns_no_chat_id_configured' });
      return res.status(200).json({ ok: true });
    }

    try {
      await sendTelegram(fetchImpl, botToken, chatId, renderAlarm(msg.Message, msg.Subject));
      req.log?.warn?.({ event: 'alert_forwarded', message_id: msg.MessageId });
    } catch (err) {
      // 200 even on failure. SNS retries non-2xx and eventually DISABLES the
      // subscription, so a Telegram outage would cost the channel permanently.
      // Email still carried this alarm; the log carries the failure.
      req.log?.error?.({ event: 'alert_forward_failed', error: err.message });
    }

    return res.status(200).json({ ok: true });
  };
}

export const __testing = { stringToSign, renderAlarm, verifySignature, createCertCache };
