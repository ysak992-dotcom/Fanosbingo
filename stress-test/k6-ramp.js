/**
 * Stepped load against the lobby read path.
 *
 * WHY THIS EXISTS ALONGSIDE k6-spike-test.js. That one drives `/select-card`,
 * which needs a real player JWT per virtual user, so it has never run. This one
 * drives what every player hits first and hardest -- `get_lobby_data_instant`,
 * the RPC the lobby polls -- and needs only the anon key. Something that runs is
 * worth more than something comprehensive that does not.
 *
 * STEPPED, NOT SMOOTH. Holding at each level makes the level where behaviour
 * changes visible; a linear ramp averages it away and reports one number that
 * describes no moment of the test.
 *
 * RUN IT FROM CI, NOT A LAPTOP. Measured on 2026-08-13 from a residential
 * connection in Addis: at 400 VUs half the requests failed with status 0 while
 * the origin's CPU peaked at 25% and Caddy logged 1,115 of the 57,026 requests
 * k6 believed it sent. The client was the bottleneck, and the run looked exactly
 * like a server falling over. A runner has the bandwidth and the connection
 * headroom, and removes the ~250ms round trip that otherwise dominates every
 * percentile.
 */
import http from 'k6/http';
import { check } from 'k6';
import { Trend, Rate, Counter } from 'k6/metrics';

const lobby = new Trend('lobby_ms');
const edge = new Trend('edge_ms');
const failed = new Rate('failed');

// WHICH failure, not just how many.
//
// The first prod run reported "72.12% failed" and nothing else, which is not
// something anyone can act on -- it reads identically whether Cloudflare is
// shedding load, the origin is refusing connections, or the client ran out of
// sockets. Those have completely different responses, and the whole point of
// the origin-metrics step is telling them apart.
//
// k6 reports a transport-level failure as status 0, which is the single most
// useful distinction here: 0 means the request never got an answer, while 429
// or 403 means something answered and said no.
const st = {
  ok: new Counter('st_200'),
  s403: new Counter('st_403_forbidden'),
  s429: new Counter('st_429_ratelimited'),
  s5xx: new Counter('st_5xx'),
  s0: new Counter('st_0_no_response'),
  other: new Counter('st_other'),
};

function record(r) {
  const c = r.status;
  if (c === 200) st.ok.add(1);
  else if (c === 403) st.s403.add(1);
  else if (c === 429) st.s429.add(1);
  else if (c >= 500 && c < 600) st.s5xx.add(1);
  else if (c === 0) st.s0.add(1);
  else st.other.add(1);
}

const BASE = __ENV.BASE;
const KEY = __ENV.KEY;
const PEAK = parseInt(__ENV.PEAK || '200', 10);
const HOLD = __ENV.HOLD || '30s';

export const options = {
  stages: [
    { duration: '20s', target: Math.max(1, Math.round(PEAK * 0.1)) },
    { duration: HOLD, target: Math.max(1, Math.round(PEAK * 0.25)) },
    { duration: HOLD, target: Math.max(1, Math.round(PEAK * 0.5)) },
    { duration: HOLD, target: PEAK },
    { duration: '20s', target: 0 },
  ],
  // FAIL THE RUN ON ERRORS, NOT ON LATENCY.
  //
  // A slow lobby is worth knowing about and is not a fault -- this system runs
  // one t4g.small on purpose. Requests that do not complete are a fault, and
  // conflating the two produces a red run nobody can act on.
  thresholds: {
    failed: ['rate<0.01'],
    lobby_ms: ['p(95)<3000'],
  },
};

export default function () {
  const headers = {
    apikey: KEY,
    Authorization: `Bearer ${KEY}`,
    'Content-Type': 'application/json',
  };

  const r = http.post(`${BASE}/rest/v1/rpc/get_lobby_data_instant`, '{}', {
    headers,
    timeout: '30s',
    tags: { name: 'lobby' },
  });
  lobby.add(r.timings.duration);
  record(r);
  failed.add(!check(r, { 'lobby 200': (x) => x.status === 200 }));

  // Caddy answers this itself and touches no upstream, so the gap between the
  // two separates "the edge is slow" from "the database is slow".
  const e = http.get(`${BASE}/healthz`, { timeout: '30s', tags: { name: 'edge' } });
  edge.add(e.timings.duration);
  record(e);
  failed.add(!check(e, { 'edge 200': (x) => x.status === 200 }));
}

export function handleSummary(data) {
  const m = data.metrics;
  const g = (n, p) => {
    const v = m[n]?.values?.[p];
    return v === undefined ? 'n/a' : Math.round(v) + 'ms';
  };
  const n = (k) => m[k]?.values?.count ?? 0;
  const pct = (n) => {
    const v = m[n]?.values?.rate;
    return v === undefined ? 'n/a' : (v * 100).toFixed(2) + '%';
  };

  const lines = [
    `## Load test — peak ${PEAK} VUs`,
    '',
    '| | median | p90 | p95 | max |',
    '|---|---|---|---|---|',
    `| lobby RPC | ${g('lobby_ms', 'med')} | ${g('lobby_ms', 'p(90)')} | ${g('lobby_ms', 'p(95)')} | ${g('lobby_ms', 'max')} |`,
    `| edge (caddy only) | ${g('edge_ms', 'med')} | ${g('edge_ms', 'p(90)')} | ${g('edge_ms', 'p(95)')} | ${g('edge_ms', 'max')} |`,
    '',
    `- requests: **${m.http_reqs?.values?.count ?? 'n/a'}** (${Math.round(m.http_reqs?.values?.rate ?? 0)}/s)`,
    `- failed: **${pct('failed')}**`,
    '',
    '| status | count | means |',
    '|---|---|---|',
    `| 200 | ${n('st_200')} | served |`,
    `| 429 | ${n('st_429_ratelimited')} | rate limited at the edge — a control working, not a fault |`,
    `| 403 | ${n('st_403_forbidden')} | refused by Cloudflare (bot/browser check) |`,
    `| 5xx | ${n('st_5xx')} | the origin answered and failed |`,
    `| 0 | ${n('st_0_no_response')} | **no answer at all** — client sockets or the edge, not the origin |`,
    `| other | ${n('st_other')} | |`,
    '',
    '> `edge` touches no upstream, so the gap between the two rows is the database',
    '> path rather than the edge. A failure rate above zero with FLAT latency means',
    '> requests are being refused rather than queued — check where, before assuming',
    '> the origin.',
    '',
  ].join('\n');

  return { stdout: lines + '\n', 'summary.md': lines };
}
