# Bingo Stress Testing Suite

> ## The suite here has still never run. Something else did.
>
> ❌ **Superseded 2026-08-13.** The claim below — that a single `t4g.small`
> running five containers was an unvalidated assumption — is no longer true, but
> it was not this suite that validated it.
>
> **What was measured**, from a GitHub runner via `.github/workflows/load-test.yml`:
>
> ```
> prod, 200 concurrent      764 req/s    0.01% failed
> lobby RPC   median  91ms   p95 245ms
> edge only   median  76ms   p95 107ms
> EC2 CPU peak 78%          RDS connections flat at 20 of ~112
> ```
>
> So CPU is the constraint at roughly 78% for 200 concurrent users, and the
> connection pools — the thing three documents worried about — never were.
>
> **Why a different script.** `k6-spike-test.js` drives `/select-card`, which
> needs a real player JWT per virtual user; that is why it never ran and still
> has not. `k6-ramp.js` drives `get_lobby_data_instant`, the RPC every player
> polls, and needs only the anon key. Something that runs beats something
> comprehensive that does not.
>
> **Do not run this from a laptop.** The first attempt did, and at 400 VUs half
> the requests failed while the origin sat at 25% CPU and Caddy logged 1,115 of
> the 57,026 requests k6 believed it sent. The client ran out of sockets, and the
> result looked exactly like a server falling over.
>
> **`stress-test/.env.example` still names `your-project.supabase.co`**; there is
> no Supabase project. Use `https://api.<domain>` and an anon key.

Comprehensive stress testing framework for testing the bingo application with 400 concurrent users joining within 10-30 seconds.

## Overview

This stress testing suite simulates real-world spike scenarios where hundreds of users join a bingo game simultaneously. It includes:

- **User data generation** for creating test accounts
- **Multiple test scenarios** (spike, sustained, gradual)
- **Real-time monitoring** of database performance
- **Results analysis** with detailed metrics
- **Automated cleanup** of test data

## Prerequisites

1. Node.js 18+ installed
2. K6 load testing tool installed
3. Supabase database configured
4. Environment variables set in `.env` file

### Installing K6

**macOS:**
```bash
brew install k6
```

**Linux:**
```bash
sudo gpg -k
sudo gpg --no-default-keyring --keyring /usr/share/keyrings/k6-archive-keyring.gpg --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C5AD17C747E3415A3642D57D77C6C491D6AC1D69
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update
sudo apt-get install k6
```

**Windows:**
```bash
choco install k6
```

Or download from: https://k6.io/docs/get-started/installation/

## Quick Start

### 1. Generate Test Users (Required First Step)

Create 400 test users with 100 ETB balance each:

```bash
npm run stress:generate
```

Custom values:
```bash
cd stress-test
npx tsx generate-test-users.ts 500 150  # 500 users with 150 ETB each
```

### 2. Run a Stress Test

**Spike Test (400 users in 10 seconds - 40 users/sec):**
```bash
npm run stress:spike
```

**Sustained Test (400 users in 20 seconds - 20 users/sec):**
```bash
npm run stress:sustained
```

**Gradual Test (400 users in 30 seconds - 13 users/sec):**
```bash
npm run stress:gradual
```

**Run All Tests:**
```bash
npm run stress:all
```

### 3. Analyze Results

After running tests, analyze the performance:

```bash
npm run stress:analyze
```

### 4. Monitor Database (During Tests)

In a separate terminal, monitor database in real-time:

```bash
npm run stress:monitor
```

Custom monitoring:
```bash
cd stress-test
npx tsx monitor-database.ts 2 60  # Check every 2 seconds for 60 seconds
```

### 5. Cleanup Test Data

After testing, remove all test users and data:

```bash
npm run stress:cleanup
```

## Complete Test Suite

Run the full automated test suite (recommended for comprehensive testing):

```bash
npm run stress:full-suite
```

This will:
1. Cleanup old data
2. Generate 400 test users
3. Run spike test
4. Analyze spike results
5. Cleanup and regenerate users
6. Run sustained test
7. Analyze sustained results
8. Save all logs to files

Results are saved in:
- `stress-test/results-spike.log`
- `stress-test/analysis-spike.log`
- `stress-test/results-sustained.log`
- `stress-test/analysis-sustained.log`

## Test Scenarios Explained

### Spike Test (10 seconds)
- **Target:** 40 users/second burst
- **Total:** 400 users in 10 seconds
- **Use case:** Simulates viral marketing campaigns, coordinated game starts
- **Thresholds:**
  - 95% of requests < 2000ms
  - 99% of requests < 5000ms
  - Error rate < 10%

### Sustained Test (20 seconds)
- **Target:** 20 users/second steady
- **Total:** 400 users in 20 seconds
- **Use case:** Popular game during peak hours
- **Thresholds:**
  - 95% of requests < 1500ms
  - 99% of requests < 3000ms
  - Error rate < 5%

### Gradual Test (30 seconds)
- **Target:** 13 users/second gradual
- **Total:** 400 users in 30 seconds
- **Use case:** Normal high-traffic scenario
- **Thresholds:**
  - 95% of requests < 1000ms
  - 99% of requests < 2000ms
  - Error rate < 2%

## Understanding the Metrics

### K6 Metrics

- **http_req_duration:** Time taken for HTTP requests
- **card_selection_duration:** Time to select a bingo card
- **lobby_load_duration:** Time to load lobby data
- **card_selection_errors:** Rate of failed card selections
- **successful_card_selections:** Number of successful selections
- **failed_card_selections:** Number of failed selections

### Analysis Report Metrics

- **Success Rate:** Percentage of users who successfully selected cards
- **Card Utilization:** How many unique cards were selected (max 75)
- **Average Throughput:** Players processed per second
- **Duplicate Selections:** Users who tried to select already-taken cards
- **Balance Analysis:** Track virtual currency flow

## Files and Structure

```
stress-test/
├── README.md                    # This file
├── generate-test-users.ts       # Create test user accounts
├── cleanup-test-data.ts         # Remove test data
├── monitor-database.ts          # Real-time database monitoring
├── analyze-results.ts           # Post-test analysis
├── k6-spike-test.js            # K6 spike test scenario
├── k6-sustained-test.js        # K6 sustained test scenario
├── k6-gradual-test.js          # K6 gradual test scenario
├── run-test.sh                 # Test runner script
└── full-test-suite.sh          # Complete automated suite
```

## Test User Details

- **ID Range:** 900,000,000 - 900,000,399
- **Usernames:** testuser0 - testuser399
- **Names:** Test User 0 - Test User 399
- **Initial Balance:** Configurable (default 100 ETB)

These IDs are chosen to not conflict with real users and can be easily filtered for cleanup.

## Troubleshooting

### Issue: K6 not found
**Solution:** Install K6 following the prerequisites section above

### Issue: No active game found
**Solution:** Ensure a waiting game exists in the database before running tests. The lobby should automatically create one, or manually create via Admin panel.

### Issue: Test users already exist
**Solution:** Run cleanup first: `npm run stress:cleanup`

### Issue: Connection errors
**Solution:**
- Check `.env` file has correct Supabase credentials
- Verify Supabase project is running
- Check connection pool settings in Supabase dashboard

### Issue: High error rates
**Solution:**
- Reduce test load (fewer users or longer duration)
- Check database performance indexes
- Review Supabase logs for errors
- Verify RLS policies are optimized

## Performance Targets

### Acceptable Performance
- ✅ Success rate > 95%
- ✅ P95 latency < 2000ms
- ✅ Error rate < 5%
- ✅ No database connection pool exhaustion

### Optimal Performance
- 🎯 Success rate > 99%
- 🎯 P95 latency < 1000ms
- 🎯 Error rate < 1%
- 🎯 Throughput > 30 users/second

## Advanced Usage

### Custom Test Duration

Modify the K6 test files to change duration:

```javascript
export const options = {
  scenarios: {
    spike_custom: {
      executor: 'constant-arrival-rate',
      rate: 50,           // Users per second
      timeUnit: '1s',
      duration: '15s',    // Total duration
      preAllocatedVUs: 60,
      maxVUs: 600,
    },
  },
};
```

### Custom Monitoring Intervals

```bash
cd stress-test
npx tsx monitor-database.ts <interval_seconds> <duration_seconds>

# Example: Check every 1 second for 120 seconds
npx tsx monitor-database.ts 1 120
```

### Parallel Tests

Run monitoring in one terminal:
```bash
npm run stress:monitor
```

Run test in another:
```bash
npm run stress:spike
```

### Generate More Users

```bash
cd stress-test
npx tsx generate-test-users.ts 1000 200  # 1000 users with 200 ETB
```

## CI/CD Integration

Add to your CI pipeline:

```yaml
stress-test:
  script:
    - npm install
    - npm run stress:generate
    - npm run stress:spike
    - npm run stress:analyze
    - npm run stress:cleanup
  artifacts:
    paths:
      - stress-test/*.log
```

## Safety Notes

- ⚠️ Always run cleanup after tests to avoid database bloat
- ⚠️ Test users have IDs starting with 900000000 - don't use this range for real users
- ⚠️ Tests create real database load - avoid running on production during peak hours
- ⚠️ Monitor your Supabase quotas to avoid unexpected charges

## Support

If you encounter issues:

1. Check this README for troubleshooting
2. Review K6 output for specific errors
3. Check Supabase logs in dashboard
4. Run analysis to identify bottlenecks
5. Verify all prerequisites are met

## Next Steps

After successful stress testing:

1. **Identify Bottlenecks:** Use analysis report to find slow operations
2. **Optimize Database:** Add indexes, optimize queries
3. **Scale Infrastructure:** Increase connection pool, add read replicas
4. **Implement Caching:** Add Redis for frequently accessed data
5. **Rate Limiting:** Protect against abuse
6. **Monitor Production:** Set up alerts for performance degradation

---

## What these scripts can and cannot measure

Added 2026-07-31, after the auth model changed underneath them.

**`k6` is NOT installed by `npm install`.** The `k6: ^0.0.0` entry in the root
`package.json` is the official autocomplete **stub** — its own description reads
*"Dummy package for autocompleting k6 scripts"*. It gives you type hints and no
binary, which is why `npm run stress:spike` has always failed with
`k6: command not found`. Use the install instructions above. `run-test.sh` now
checks and says this rather than failing obscurely.

**The card-selection leg will 401 on every request.** These scripts post to
`/functions/v1/select-card` with `VITE_SUPABASE_ANON_KEY`. That route now requires
a player JWT and derives the identity, the display name and the card layout from
it, so the anon key is correctly rejected.

The run is still worth doing — the lobby leg exercises the read path, which is
most of a lobby's traffic — but read the right metric:

> the scripts record selection **duration before checking status**, and a 401 is
> fast. So `card_selection_duration` stays green while `card_selection_errors`
> breaches its threshold. **Read the error rate, not the latency**, until a token
> is wired in.

To measure the write path properly, mint a player token the way
`services/functions/src/auth.js` does and send it as the bearer. `scripts/mint-anon-key.mjs`
is the pattern for reading the signing secret out of SSM.

**Capacity data exists as of 2026-08-13** -- see the notice at the top of this
file. `t4g.small` serves 764 req/s at 200 concurrent with CPU at 78%, measured
from a runner via `load-test.yml`. It came from `k6-ramp.js`, not from this
suite: `k6-spike-test.js` targets 400 concurrent and still has not run at that
target, because it drives `/select-card` and needs a real player JWT per virtual
user -- which is exactly what the paragraph above explains how to mint.
