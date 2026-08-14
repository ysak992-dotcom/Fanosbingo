/**
 * Tests for upstreams.js.
 *
 * The assertions that matter are not "it calls fetch". They are:
 *
 *   - a down upstream produces 503, because that is what the health check reads
 *     and a probe that always answers 200 is the blindness this replaces
 *   - the response NAMES which upstream is down, because that is the whole
 *     reason this is one endpoint rather than three separate health checks
 *   - a non-200 upstream is treated as UP, deliberately: PostgREST serves
 *     OpenAPI at / and Realtime answers 403 to a request without its tenant
 *     Host, and encoding either quirk here would make the alarm go red on an
 *     upstream version bump
 *   - probes run concurrently, or three 2-second timeouts exceed the health
 *     checker's patience and one slow upstream reads as a dead origin
 *   - the database is checked properly, not just "did the pool exist"
 *
 * Run: node src/upstreams.test.mjs
 */

import { probeHttp, createDeepReadyHandler, parseDefaultGateway, hostAddress } from './upstreams.js';

let failures = 0;
const check = (label, cond) => {
  console.log(`  ${cond ? 'PASS' : 'FAIL'}  ${label}`);
  if (!cond) failures++;
};

/** Minimal express-shaped response recorder. */
function makeRes() {
  return {
    statusCode: null,
    body: null,
    status(c) { this.statusCode = c; return this; },
    json(b) { this.body = b; return this; },
  };
}

const okPool = { query: async () => ({ rows: [{ '?column?': 1 }] }) };
const deadPool = { query: async () => { throw new Error('connection refused'); } };

console.log('\nparseDefaultGateway — where the host actually is');

{
  // Real /proc/net/route from a docker bridge container. The gateway is stored
  // LITTLE-ENDIAN, so 010011AC is 172.17.0.1 -- getting the byte order backwards
  // yields 1.0.17.172, which looks like an address and routes nowhere.
  const table = [
    'Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT',
    'eth0\t00000000\t010011AC\t0003\t0\t0\t0\t00000000\t0\t0\t0',
    'eth0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0',
  ].join('\n');
  check('reads the default route gateway', parseDefaultGateway(table) === '172.17.0.1');
}

{
  // A different bridge subnet must work too -- 172.17.0.1 is a convention, not a
  // guarantee, which is the whole reason this is read rather than hardcoded.
  const table = 'Iface\tDestination\tGateway\n' +
                'eth0\t00000000\t0100A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0';
  check('works on a non-default bridge subnet', parseDefaultGateway(table) === '192.168.0.1');
}

{
  const noDefault = 'Iface\tDestination\tGateway\n' +
                    'eth0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\t0\t0\t0';
  check('no default route -> null', parseDefaultGateway(noDefault) === null);
  check('garbage -> null rather than a wrong address', parseDefaultGateway('') === null);
}

{
  check('hostAddress falls back to loopback when /proc is unreadable',
    hostAddress({ readFile: () => { throw new Error('no /proc'); } }) === '127.0.0.1');
  check('hostAddress uses the gateway when it can read it',
    hostAddress({ readFile: () => 'h\neth0\t00000000\t010011AC\t0003' }) === '172.17.0.1');
}

console.log('\nprobeHttp');

{
  const res = await probeHttp('http://x/', { fetchImpl: async () => ({ status: 200 }) });
  check('a 200 is up', res.up === true && res.status === 200);
}

{
  // The case that matters: Realtime answers 403 without its tenant Host.
  const res = await probeHttp('http://x/', { fetchImpl: async () => ({ status: 403 }) });
  check('a 403 is still UP -- something is listening and speaking HTTP', res.up === true);
}

{
  const res = await probeHttp('http://x/', { fetchImpl: async () => ({ status: 500 }) });
  check('even a 500 is up; this probe asks whether the process exists', res.up === true);
}

{
  const err = new Error('nope');
  err.cause = { code: 'ECONNREFUSED' };
  const res = await probeHttp('http://x/', { fetchImpl: async () => { throw err; } });
  check('a refused connection is DOWN', res.up === false);
  check('and says so as ECONNREFUSED, not a generic error', res.error === 'ECONNREFUSED');
}

{
  const err = new Error('too slow');
  err.name = 'TimeoutError';
  const res = await probeHttp('http://x/', { fetchImpl: async () => { throw err; } });
  check('a timeout is DOWN, and distinguishable from refused', res.up === false && res.error === 'timeout');
}

console.log('\ncreateDeepReadyHandler');

{
  const handler = createDeepReadyHandler(okPool, { host: '10.0.0.1', fetchImpl: async () => ({ status: 200 }) });
  const res = makeRes();
  await handler({}, res);
  check('everything up -> 200', res.statusCode === 200);
  check('and ready is true with nothing listed down', res.body.ready === true && res.body.down.length === 0);
}

{
  // postgrest down, realtime up. Distinguished by URL so the test proves the
  // handler probes them separately rather than once.
  const handler = createDeepReadyHandler(okPool, {
    host: '10.0.0.1',
    fetchImpl: async (url) => {
      if (String(url).includes('3000')) {
        const e = new Error('x'); e.cause = { code: 'ECONNREFUSED' }; throw e;
      }
      return { status: 200 };
    },
  });
  const res = makeRes();
  await handler({}, res);
  check('postgrest down -> 503', res.statusCode === 503);
  check('and names postgrest, not just "not ready"', res.body.down.length === 1 && res.body.down[0] === 'postgrest');
  check('while realtime is still reported up', res.body.checks.realtime.up === true);
}

{
  const handler = createDeepReadyHandler(okPool, {
    host: '10.0.0.1',
    fetchImpl: async (url) => {
      if (String(url).includes('4000')) {
        const e = new Error('x'); e.name = 'TimeoutError'; throw e;
      }
      return { status: 200 };
    },
  });
  const res = makeRes();
  await handler({}, res);
  check('realtime down -> 503, and named', res.statusCode === 503 && res.body.down[0] === 'realtime');
}

{
  const handler = createDeepReadyHandler(deadPool, { host: '10.0.0.1', fetchImpl: async () => ({ status: 200 }) });
  const res = makeRes();
  await handler({}, res);
  check('database down -> 503 even with both upstreams up', res.statusCode === 503);
  check('and names the database', res.body.down.includes('database'));
}

{
  // Everything down at once still answers, and lists all three -- a page that
  // says "postgrest" when in fact the whole box is gone would send somebody to
  // the wrong place.
  const handler = createDeepReadyHandler(deadPool, {
    host: '10.0.0.1',
    fetchImpl: async () => { const e = new Error('x'); e.cause = { code: 'ECONNREFUSED' }; throw e; },
  });
  const res = makeRes();
  await handler({}, res);
  check('all three down -> all three named', res.body.down.length === 3);
}

{
  // CONCURRENCY. Serially this is 300ms; concurrently it is ~100ms. Asserted
  // with a generous bound so a loaded CI runner does not fail it spuriously,
  // but 300ms would be impossible to hit if the probes were sequential.
  const slow = async () => {
    await new Promise((r) => setTimeout(r, 100));
    return { status: 200 };
  };
  const handler = createDeepReadyHandler(
    { query: async () => { await new Promise((r) => setTimeout(r, 100)); return { rows: [] }; } },
    { host: '10.0.0.1', fetchImpl: slow },
  );
  const started = Date.now();
  const res = makeRes();
  await handler({}, res);
  const elapsed = Date.now() - started;
  check(`three 100ms probes complete in under 250ms (took ${elapsed}ms)`, elapsed < 250);
}

{
  // The failure is LOGGED with detail, because the alarm only carries a status
  // code. This is where "which one, and why" is recorded.
  let logged = null;
  const handler = createDeepReadyHandler(okPool, {
    host: '10.0.0.1',
    fetchImpl: async () => { const e = new Error('x'); e.cause = { code: 'ECONNREFUSED' }; throw e; },
  });
  await handler({ log: { error: (f) => { logged = f; } } }, makeRes());
  check('a failure is logged with the down list', logged?.event === 'deep_readiness_failed' && logged.down.length === 2);
}

{
  // THE REGRESSION TEST. The first version probed 127.0.0.1, which is this
  // container's own namespace in bridge mode -- so it reported both upstreams
  // down while both were serving.
  const seen = [];
  const handler = createDeepReadyHandler(okPool, {
    host: '172.17.0.1',
    fetchImpl: async (url) => { seen.push(String(url)); return { status: 200 }; },
  });
  await handler({}, makeRes());
  check('probes the HOST gateway, not the container loopback',
    seen.every((u) => u.includes('172.17.0.1')) && !seen.some((u) => u.includes('127.0.0.1')));
  check('and reaches both upstream ports',
    seen.some((u) => u.includes(':3000')) && seen.some((u) => u.includes(':4000')));
}

console.log(failures === 0 ? '\nAll upstream tests passed.' : `\n${failures} FAILED.`);
process.exit(failures === 0 ? 0 : 1);
