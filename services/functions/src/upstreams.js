/**
 * Deep readiness: is the whole origin actually serving, not just answering?
 *
 * WHAT WAS BLIND, AND IT WAS MOST OF THE STACK.
 *
 * The only alarm that looks from outside AWS is a Route 53 health check on
 * api.<domain>/healthz, and services/caddy/Caddyfile answers that path itself
 * with `respond "ok" 200`. That is deliberate and correct for what it is -- a
 * reachability statement that stays useful while an upstream is down. But
 * nothing else covered the upstreams, and there are no ECS RunningTaskCount
 * alarms, so the coverage was:
 *
 *   ticker down      game-loop-stalled fires        (the metric it publishes)
 *   caddy/instance   api-unreachable fires          (this check, and EC2 status)
 *   postgrest down   NOTHING. The SPA's entire data path is dead, silently.
 *   realtime down    NOTHING. No live game updates, silently.
 *   functions down   NOTHING. No login, no deposits, no withdrawals, silently.
 *
 * Three of the five services could stop and no alarm anywhere would say so.
 *
 * WHY ONE ENDPOINT RATHER THAN THREE HEALTH CHECKS.
 *
 * A Route 53 health check against a non-AWS endpoint is $0.50/mo, so covering
 * the three upstreams separately is $1.50/mo against a $32 budget -- affordable,
 * but it buys less. Three checks report three booleans from outside; this
 * reports WHICH upstream is down, in the response body, from inside the box
 * where the answer is unambiguous. One check, and a page that already says what
 * broke.
 *
 * The coupling is real and is the right way round: if this service is down, the
 * check fails. That is not a false positive -- functions being down IS an
 * outage, and it was one of the three nothing covered.
 *
 * WHY ANY HTTP RESPONSE COUNTS AS ALIVE.
 *
 * Deliberately NOT "returns 200". PostgREST at / serves an OpenAPI document, and
 * Realtime resolves its tenant from the Host subdomain and answers 403 to
 * anything else -- so a status check here would encode two upstream quirks that
 * are not this file's business, and would go red on a version bump that changed
 * either. A TCP connection accepted and an HTTP response produced is exactly the
 * claim being made: the container is up and serving. A dead or crash-looping
 * container refuses the connection, which is what this detects.
 *
 * The database is checked properly, because that one this service does own.
 */

/** Long enough for a loaded box, short enough that the probe cannot hang. */
const DEFAULT_TIMEOUT_MS = 2_000;

/**
 * Is something listening and speaking HTTP at this URL?
 *
 * AbortSignal.timeout rather than a race with a setTimeout: it cancels the
 * underlying socket, so a probe against a black-holed address does not leave a
 * connection open every time it runs.
 *
 * @param {string}    url
 * @param {object}    [opts]
 * @param {number}    [opts.timeoutMs]
 * @param {typeof fetch} [opts.fetchImpl]  injected by the tests; real fetch otherwise
 */
export async function probeHttp(url, { timeoutMs = DEFAULT_TIMEOUT_MS, fetchImpl = fetch } = {}) {
  const started = Date.now();
  try {
    const res = await fetchImpl(url, {
      method: 'GET',
      signal: AbortSignal.timeout(timeoutMs),
    });
    // Any status at all. See the header for why this is not `res.ok`.
    return { up: true, status: res.status, ms: Date.now() - started };
  } catch (err) {
    return {
      up: false,
      // `TimeoutError` and `ECONNREFUSED` mean different things to whoever is
      // woken up: one is a container that is wedged, the other is one that is
      // not running.
      error: err?.name === 'TimeoutError' ? 'timeout' : (err?.cause?.code ?? err?.name ?? 'error'),
      ms: Date.now() - started,
    };
  }
}

/**
 * GET /readyz/deep -> 200 when every upstream answers, 503 when one does not.
 *
 * The status code is what the health check reads; the body is what the person
 * reading the alarm needs. Both are produced by the same probe, so they cannot
 * disagree.
 *
 * Probes run CONCURRENTLY. Serially, three 2-second timeouts would take six
 * seconds and exceed the health checker's own patience, turning "one upstream is
 * slow" into "the origin is down".
 *
 * @param {import('pg').Pool} pool
 * @param {object}   [opts]
 * @param {{ postgrest?: string, realtime?: string }} [opts.urls]  overridden in tests
 * @param {number}   [opts.timeoutMs]
 * @param {typeof fetch} [opts.fetchImpl]
 */
export function createDeepReadyHandler(pool, { urls = {}, timeoutMs, fetchImpl } = {}) {
  const postgrestUrl = urls.postgrest ?? 'http://127.0.0.1:3000/';
  const realtimeUrl = urls.realtime ?? 'http://127.0.0.1:4000/';

  return async function deepReady(req, res) {
    const [database, postgrest, realtime] = await Promise.all([
      (async () => {
        const started = Date.now();
        try {
          await pool.query('SELECT 1');
          return { up: true, ms: Date.now() - started };
        } catch (err) {
          return { up: false, error: err.message, ms: Date.now() - started };
        }
      })(),
      probeHttp(postgrestUrl, { timeoutMs, fetchImpl }),
      probeHttp(realtimeUrl, { timeoutMs, fetchImpl }),
    ]);

    const checks = { database, postgrest, realtime };
    const down = Object.entries(checks)
      .filter(([, v]) => !v.up)
      .map(([k]) => k);

    if (down.length > 0) {
      // Logged at error, with the detail, because the alarm this drives says
      // only that the endpoint stopped answering 200. This is where "which one"
      // is recorded.
      req?.log?.error?.({ event: 'deep_readiness_failed', down, checks });
    }

    return res.status(down.length === 0 ? 200 : 503).json({
      ready: down.length === 0,
      down,
      checks,
    });
  };
}
