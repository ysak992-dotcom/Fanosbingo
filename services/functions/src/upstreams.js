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
 *
 * WHERE THE UPSTREAMS ACTUALLY ARE, which the first version of this got wrong.
 *
 * It defaulted to http://127.0.0.1:3000 and :4000, copied from the Caddyfile.
 * Caddy reaches them there because Caddy runs in HOST network mode -- it has to,
 * to own :443 on the instance. This service runs in BRIDGE mode, so 127.0.0.1 is
 * its OWN namespace and those ports are not in it. Deployed to dev, the endpoint
 * duly reported both upstreams down with ECONNREFUSED while both were serving
 * 200 through Caddy: a health check that fails when everything is fine, which is
 * worse than the blindness it replaced.
 *
 * A bridge container reaches the host at its DEFAULT GATEWAY -- the docker
 * bridge address, conventionally 172.17.0.1 but not guaranteed. It is read from
 * /proc/net/route rather than hardcoded, so a different bridge subnet does not
 * silently reproduce this bug.
 *
 * Both URLs stay overridable by environment variable, which is what the tests
 * use and what a future move to awsvpc or Fargate would need.
 */

import fs from 'node:fs';

/** Long enough for a loaded box, short enough that the probe cannot hang. */
const DEFAULT_TIMEOUT_MS = 2_000;

/**
 * The host, as seen from inside a bridge-networked container: its default
 * gateway.
 *
 * /proc/net/route stores the gateway as LITTLE-ENDIAN hex, so 010011AC is
 * 172.17.0.1 and not 1.0.17.172. Getting that backwards produces an address
 * that looks plausible and routes nowhere, which is why the byte order is
 * asserted in the tests rather than assumed.
 *
 * Exported for the tests; the file is read through a parameter so they need no
 * fixture on disk.
 */
export function parseDefaultGateway(routeTable) {
  for (const line of String(routeTable).split('\n').slice(1)) {
    const f = line.trim().split(/\s+/);
    // Destination 00000000 is the default route. Gateway 00000000 means the
    // interface is directly connected and has no gateway to speak of.
    if (f.length > 2 && f[1] === '00000000' && f[2] !== '00000000') {
      const hex = f[2];
      return [6, 4, 2, 0].map((i) => parseInt(hex.substr(i, 2), 16)).join('.');
    }
  }
  return null;
}

/**
 * Falls back to 127.0.0.1 rather than throwing. A container that cannot read
 * its own route table should still start and still answer -- the probe then
 * reports the upstreams down, which is visible, where a crash on boot is a
 * service that never comes up at all.
 */
export function hostAddress({ readFile = () => fs.readFileSync('/proc/net/route', 'utf8') } = {}) {
  try {
    return parseDefaultGateway(readFile()) ?? '127.0.0.1';
  } catch {
    return '127.0.0.1';
  }
}

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
 * @param {string}   [opts.host]  the host address to probe. Pinned by the tests
 *                                so they do not depend on the route table of
 *                                whatever machine runs them; resolved from the
 *                                container's default gateway otherwise.
 */
export function createDeepReadyHandler(pool, { urls = {}, timeoutMs, fetchImpl, host } = {}) {
  // Resolved ONCE at construction. The gateway does not change while the
  // container lives, and reading /proc on every health check would be a syscall
  // per probe for a value that cannot move.
  const hostIp = host ?? hostAddress();

  const postgrestUrl =
    urls.postgrest ?? process.env.POSTGREST_PROBE_URL ?? `http://${hostIp}:3000/`;
  const realtimeUrl =
    urls.realtime ?? process.env.REALTIME_PROBE_URL ?? `http://${hostIp}:4000/`;

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
