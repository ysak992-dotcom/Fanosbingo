# Handover — read this before changing anything

**Written 2026-08-09.** For whoever picks this up next, human or agent.

This is a **real-money game with live players**. A deposit was made by TeleBirr,
approved, spent on a round, and a false bingo claim was correctly refused — all
by a real person with real birr. Treat every change accordingly.

---

## The five things that will mislead you

Read these first. Each one cost real time or a real incident.

### 1. `dev` is the ONLY environment, and it serves the live domain

Verified in the account, not inferred:

```
terraform state       account/  dev/          (nothing else)
EIP behind the domain fanosbingo-dev-app
data                  4 telegram_users · 7 games · 3 deposit_requests
```

**`dev` is the development and staging environment — it is not "production", and
prod is planned.** But it is the only environment that exists, it is what
`api.yisakmesifin.org` resolves to, and real birr has moved through it: a
TeleBirr deposit was approved by an operator, spent on a round, and a false
bingo claim correctly refused.

**So it must be protected like production until prod exists**, and it is:
deletion protection, a required final snapshot, `apply_immediately = false`, and
a `terraform destroy` path guarded twice. That is a consequence of it being the
only copy, not a claim about its status.

Two practical consequences:

- **There is no separate staging.** A change tested here is tested in the place
  players use. Prefer verifying against the account (`simulate-principal-policy`,
  a `--show` dry run, a plan) over trying something to see what happens.
- Anything that reads **"dev is disposable, tear it down"** predates this and is
  stale — the destroy guards will refuse it anyway.

### 2. The account is on the FREE plan, and credits run out before the expiry

```
plan          FREE / ACTIVE
credits       ~$150, falling ~$1.30/day
expiry        2027-01-14
```

Two deadlines. **The credits bind first — roughly late November 2026**, and
every document quotes the January date. On a FREE plan, exhausting credits
**suspends resources**; it does not bill.

**No budget can see this.** Spend is zero because credits absorb the bill before
Cost Explorer sees it (measured: `-0.0000001/day` while credits fell $1.30/day).
The only signal is `aws freetier get-account-plan-state`, published daily by
`.github/workflows/free-tier-runway.yml` and alarmed below $50.

The plan is to stay on FREE. That decision is the operator's and is current.

### 3. RDS point-in-time recovery is capped at **1 day**, and cannot be raised

```
FreeTierRestrictionError: The specified backup retention period exceeds the
maximum available to free tier customers.
```

Retried with `2` and refused identically — the ceiling is exactly 1. **Do not
set `backup_retention_period` above 1 in `environments/dev`.** It does not fail
quietly; it fails the whole apply.

The mitigation is nightly `pg_dump` to S3, kept 30 days
(`.github/workflows/db-backup.yml`). See **[RESTORE.md](RESTORE.md)** before you
need it — especially the part about creating the three roles before restoring.

### 4. A test being green does not mean the code works

Three separate defects shipped here **with passing tests**, because the test
double answered questions the real dependency would have refused:

- a pool double that returned rows for any SQL, so a handler read columns that
  do not exist from a table that does not hold them
- a webhook verifier tested against a Fetch `Request`, when production presents
  an Express `req` with no `.get()` on `headers`
- a CORS allow-list that omitted a header the server reads, so the browser
  stripped it before sending

Guards now exist for each, and **each was verified by reintroducing the exact
bug and watching it fail**. Do the same for any guard you add. A test that
cannot fail is worse than no test.

### 5. `npm run build` does not typecheck

Vite does not run TypeScript. A `ReferenceError` on the main player path passed
`npm run build` and was caught only by `npm run typecheck`.

**Run `npm run typecheck` before shipping SPA changes.** It is advisory in CI
(11 findings, all unused-variable noise) and should be promoted to a gate once
those are read — see Open work.

---

## How to change things

Everything reaches AWS through **one path**: `.github/workflows/terraform.yml`,
via OIDC. There is no AWS access key in this repository.

```
infra change   →  PR (plan is commented) → merge → gh workflow run terraform.yml -f action=apply
service change →  PR → merge → gh workflow run deploy-services.yml -f service=<name>
schema change  →  PR → merge → gh workflow run db-migrate.yml -f dry_run=true, then false
```

**Deploy order is migrations → `functions` → `caddy`.** Reversed at the first
step there is a window where a player can mint a balance *and* cash it out.

`terraform apply` against dev **also rolls `caddy` and `functions`** onto
whatever image the SSM pointer names. That is the pointer mechanism working, not
drift — but an infrastructure apply is also a deploy, and it briefly drops the
site (one instance, static host ports, `deployment_minimum_healthy_percent = 0`).
Check `ActiveGames` before applying.

### Verifying, rather than assuming

| Question | Command |
|---|---|
| Can a player reach the site? | `curl -s -o /dev/null -w '%{http_code}' https://api.yisakmesifin.org/healthz` |
| Do alarms reach a human? | `./scripts/verify-alarms.sh dev --fire <alarm>` — **believe the device, not the console** |
| Is a permission actually granted? | `aws iam simulate-principal-policy` — it caught two false pages here |
| Did a backup land? | `aws s3 ls s3://fanosbingo-backups-<account>/dev/` |
| What is the free-tier runway? | `aws freetier get-account-plan-state` |

---

## When something is wrong

Nothing below was written down anywhere before. Both were verified against the
live account on 2026-08-09.

### The site is down

Work outward. Each step rules out a layer.

```bash
# 1. Is it reachable at all, and from outside AWS?
curl -s -o /dev/null -w '%{http_code}\n' https://api.yisakmesifin.org/healthz
aws route53 get-health-check-status --health-check-id <id>   # 16 global probers

# 2. Are the containers running?
aws ecs describe-services --cluster fanosbingo-dev --region us-east-1 \
  --services caddy functions ticker postgrest realtime \
  --query 'services[].[serviceName,runningCount,desiredCount]' --output text

# 3. What did the service say?
aws logs filter-log-events --log-group-name /ecs/fanosbingo-dev \
  --start-time $(( ($(date +%s) - 900) * 1000 )) --filter-pattern '"level":"error"'

# 4. Is the database reachable from the service?
curl -s https://api.yisakmesifin.org/functions/v1/readyz     # 503 = DB unreachable
```

**A green EC2 status check does not mean players can reach you.** The classic
failure here is the instance being replaced and `user_data` failing to
re-associate the Elastic IP: the instance is healthy, the ticker keeps calling
numbers, every internal alarm reads OK, and Cloudflare resolves to an address
attached to nothing. That is what `api-unreachable` exists to catch — it is the
only alarm that looks from outside AWS.

### Rolling back a bad deploy

The circuit breaker only covers a deploy that never becomes healthy. A deploy
that succeeds and is *wrong* needs this:

```bash
# What is running, and what can you go back to?
aws ecs describe-services --cluster fanosbingo-dev --region us-east-1 \
  --services functions --query 'services[0].taskDefinition' --output text
aws ecs list-task-definitions --region us-east-1 \
  --family-prefix fanosbingo-dev-functions --status ACTIVE --sort DESC --max-items 5

# Roll back to the previous revision
aws ecs update-service --cluster fanosbingo-dev --region us-east-1 \
  --service functions --task-definition fanosbingo-dev-functions:<previous>
```

Images are tagged by commit SHA and ECR keeps the last 5, so what is running is
always traceable to a commit.

> **THE TRAP: Terraform will silently undo this.**
>
> `modules/ecs_service` sets the service's task definition to
> `max(terraform's revision, the newest ACTIVE revision)`. A manual rollback to
> an *older* revision is therefore reverted by the next `terraform apply` — and
> an apply happens for unrelated reasons.
>
> To make a rollback stick, **deregister the bad revision** so the one you rolled
> back to becomes the newest:
>
> ```bash
> aws ecs deregister-task-definition --region us-east-1 \
>   --task-definition fanosbingo-dev-functions:<bad>
> ```
>
> Otherwise treat the rollback as buying time, and fix forward.

### Getting a shell, and reaching the database

There is no SSH and no bastion, by design. Both go through SSM.

```bash
aws ecs execute-command --cluster fanosbingo-dev --region us-east-1 \
  --task <task-arn> --container functions --interactive --command /bin/sh

source scripts/db-tunnel.sh dev     # exports DATABASE_URL, forwards to :15432
psql "$DATABASE_URL" -c 'SELECT 1'
stop_db_tunnel
```

Every SSM session is a CloudTrail event attributable to an IAM principal, which
is the reason it is the only path in.

---

## Open work

Ordered by what I would do next. None is blocked on anything except the last.

### 1. "Back to lobby" does not work — **STILL BROKEN after three attempts**

**Confirmed still broken by the operator on 2026-08-09**, after all three fixes
below were deployed. Do not assume any of them worked. Reproduce it first.

**Symptom.** In a running round the player sees the "Spectator Mode" panel with a
**Back to lobby** button. Tapping it does not return to the lobby — the view
stays in the game, and in at least one observation flipped to showing the
player's own card and a BINGO button.

**Three hypotheses, all deployed, none sufficient.** Listed so you do not spend
the time again:

1. *"There is no exit at all."* — `GameRoom`'s only exit was automatic
   (`onReturnToLobby` fires when the game **finishes**). Added a Back button for
   spectators. Commit `cf8e9fd`. **Did not fix it.**

2. *"The auto-enter effect overrides the exit."* — `App.tsx` polls every 10s and,
   for any `playing` game, does `setGameId(...)` + `setGameStarted(true)`
   unconditionally, undoing the handler within seconds. Added a
   `dismissedGameIdRef` so a deliberate exit is honoured — but **only for
   somebody with no player row**, since a player should stay in the round they
   paid for. Commit `00b4e00`. **Did not fix it**, because the operator testing
   it *was* a player in that round.

3. *"A player should never be offered Watch in the first place."* — the banner was
   shown whenever a round was `playing`, including to somebody already holding a
   card; and `handleSpectateGame` sets `gameId` but **not** `playerId`, so a
   player tapping Watch renders as a fake spectator. Hid the banner via
   `isAlreadyInThisGame` in `Lobby.tsx`. Commit `bf4fa1d`. **Did not fix it.**

**What is therefore still unexplained.** With (3) deployed, a player should never
reach the spectator panel at all — yet the panel is still being seen.

### Fourth hypothesis, added 2026-08-10 — and it is structural

Of the four possibilities listed here previously, three can now be ruled out by
reading, and the one that survives is the one marked unchecked: **the panel is
reached through the auto-enter effect, not the Watch button.** Not merely
possible — unavoidable, at every round transition.

`App.tsx:145` picks the game to enter like this:

```js
.from('games').select('id').eq('status', 'playing')
.order('created_at', { ascending: false }).limit(1)
```

**The newest playing game. Never "the game this user is in."** The `players`
lookup three lines later is then scoped to *that* game. So:

1. A player is in game A. Game B is created and starts.
2. The poll picks B, finds no `players` row for them in B, and does
   `setPlayerId(null)` — for somebody who is genuinely playing, in A.
3. It then does `setGameId(B)`, `setGameStarted(true)`, pulling them out of the
   round they paid for and into one they are not in.
4. `GameRoom` renders `isSpectator` from `!playerId || !currentPlayer`, so they
   get the Spectator Mode panel.

That alone explains the symptom without the dismissal logic being wrong at all.
It also explains the observation nothing else did — *"flipped to showing the
player's own card and a BINGO button"* — because when the newest playing game
happens to be theirs, `playerId` populates and the card renders.

**And it explains why Back appears dead.** The dismissal is scoped to one game
id, so tapping Back works until the next game starts, at which point
`dismissedGameIdRef.current` no longer equals `activeGameId` and the effect
force-enters again. In a lobby that starts rounds continuously, that is
indistinguishable from the button doing nothing.

Ruled out while establishing this, so nobody re-checks them:

- **`maybeSingle()` returning null on duplicates** — `players` carries
  `UNIQUE (game_id, telegram_user_id)`, so there cannot be two rows to trip on.
- **Hypothesis 3 not actually deployed** — `Lobby.tsx:1023` does gate the banner
  on `!isAlreadyInThisGame`. It works, and it is irrelevant: the panel is not
  reached through that banner.
- **Concurrent `playing` games being impossible** — `db/20-post/002` says the
  opposite in its own comment, having been written to survive "two concurrent
  games".

Still unchecked, and cheap to eliminate first: **the deployed bundle was not the
one tested.** The Mini App caches aggressively and the entry hash changes on each
build.

**The fix is the one the design question below already names**, and it is small:
prefer the game the user has a `players` row in, and fall back to "newest
playing" only for somebody with no row anywhere — for whom entry should be
explicit rather than automatic.

> **Do not ship it blind.** Three fixes have already gone straight to the busiest
> player path, in the environment players use, because there is nowhere else to
> put them. **This one waits for the cutover** — `prod` serving the domain and
> `dev` rebuildable on demand (`CUTOVER.md`, `scripts/seed-dev.sh`) is exactly
> what makes a fourth attempt testable instead of a fourth guess.

**How I would approach it next, in this order:**

1. **Reproduce with the console open**, and log `playerId`, `currentPlayer`,
   `isSpectator`, `dismissedGameIdRef.current` and `activeGameId` on every render
   and every poll. Every hypothesis above is distinguishable from those five
   values, and none of them can be settled by reading the code — I tried three
   times and was wrong three times.
2. Establish **how the panel is being reached**: the Watch button, or the
   auto-enter effect. They are different bugs.
3. Only then change code.

**The deeper design question**, worth settling before patching further: `App.tsx`
force-enters *everyone* into a running game on a 10-second poll. That is right
for a player with a card and wrong for everyone else, and every attempt above is
working around it rather than fixing it. Consider making entry explicit — a
player is entered because they joined, not because a poll noticed a game — and
the button follows naturally.

**Files:** `src/App.tsx` (auto-enter effect ~line 122, `handleReturnToLobby`,
`handleSpectateGame`), `src/components/Lobby.tsx` (watch banner,
`isAlreadyInThisGame`), `src/components/GameRoom.tsx` (`isSpectator`, the
spectator panel and its Back button).

### 2. Two `settings` rows still hold inherited values — **operator action**

Verified against the database on 2026-08-09, not inferred:

```
game_url              = https://multiplayer-bingo-we-5btk.bolt.host/
telegram_bot_username = Habeshabingo91bot          (the bot is @BingoNovaaBot)
```

Both are editable in **Admin → Settings**. The panel was saved on 2026-08-08 but
these two fields were not changed, so a `setting_updated` log line is not
evidence that a value is current — check the row.

`game_url` is now **refused** by the bot because `bolt.host` is not a host this
deployment serves, so `/start` falls back to `app.<domain>` and logs
`game_url_rejected`. Nothing is broken. But the row should be corrected to the
URL you actually want players sent to, and until it is, that setting does
nothing.

> **The table is keyed on `id`, not `key`.** Anything querying
> `WHERE key = '...'` throws `column "key" does not exist`. The webhook did
> exactly that and the error was swallowed by a fallback, so the setting was
> silently ignored while a comment claimed the operator could change the link
> without a deploy.

### 2. Promote `npm run typecheck` to a CI gate

It just caught a runtime crash on the busiest code path while `npm run build`
passed. 11 findings remain, all `TS6133` unused declarations. Read each — one of
them found dead spectator plumbing that turned out to be a real feature gap —
then make the job blocking.

### 3. Nothing lints the SPA in CI

`npm run lint` exists; no workflow runs it. Same gap that was already fixed for
`scripts/`. One pre-existing error (`recentActivity` in `Admin.tsx`).

### 4. Zero capacity data

`stress-test/k6-spike-test.js` targets 400 concurrent and **has never run**; the
`k6` npm entry is an autocomplete stub, so `npm run stress:*` cannot work as
written. You do not know what breaks first: the pool is `max: 5` on a
`t4g.small` shared with four other containers.

Load-testing means load-testing **production**. Do it small and off-peak.

### 5. Deferred on cost, by the operator's decision

Not oversight — recorded so nobody re-derives them:

- **GuardDuty** — a few dollars a month; the detection that would catch misuse
  of the admin IAM user
- **AWS SMS alerting** — built, applied, and delivers nothing: the account is not
  enrolled in AWS End User Messaging. **Not** a restriction on Ethiopian
  numbers; it would fail for a US number identically
- **Backup retention > 1 day, Multi-AZ, a second instance** — all need the paid
  plan

### 6. Untouched by request

An IAM user holds `AdministratorAccess` with a console password. Its MFA state
is worth checking (`aws iam get-credential-report`) — it bypasses every control
in `infra/environments/account`. **The operator asked that this be left alone.**

---

## What exists now that the older documents do not mention

Built 2026-08-08/09. If a document contradicts this list, this list is right.

| | |
|---|---|
| Second factor on money actions | TOTP on the **action**, not the login. Approve a deposit / complete a withdrawal require a code; reads and settings do not. Enrol at **Admin → Settings → Security**. `db/20-post/016` |
| Nightly backups | `pg_dump` → S3, 30 days, alarmed on absence. [RESTORE.md](RESTORE.md) |
| Operator notifications | A deposit claim or withdrawal request reaches Telegram in seconds. The 4-hour queue alarms remain as the backstop |
| The bot answers | `/start` and `/help`, with a `web_app` button that opens the Mini App **inside** Telegram |
| External health check | Route 53 probes `api.<domain>/healthz` from outside AWS. **Creates no DNS** — Cloudflare stays authoritative |
| Free-tier runway alarm | The only alarm no budget can replace |
| Spectator mode | Reachable for the first time — see Open work #1 |
| Alarms | 17 in the account; delivery is **email + Telegram** |

---

## Inherited documents

`SPECTATOR_MODE_IMPLEMENTATION.md`, `CRYPTO_DEPOSIT_SETUP.md`,
`REALTIME_ARCHITECTURE.md`, `USER_SMS_SUBMISSIONS_GUIDE.md` and their siblings
predate the AWS rebuild and describe a **hosted Supabase project that does not
exist here**. Most carry a banner saying so.

Their *design reasoning* is often still worth reading. Their *operational steps*
are not — anything mentioning `supabase.co`, edge-function deployment or
`SUPABASE_URL` does not apply.

Current state lives in: **[README.md](README.md)** ·
**[AGENTS.md](AGENTS.md)** · **[infra/README.md](infra/README.md)** ·
**[RESTORE.md](RESTORE.md)** · this file.

---

## The habit that would have saved the most time

Nearly every defect in the last two days was found by **running the system**,
not by reading it — and several were introduced by assuming rather than
checking:

- a workflow moved to a scoped role without verifying the role could still do
  what the workflow needed. **Twice**, one commit apart, each producing a false
  "backup FAILED" about a backup that had succeeded
- a `sed` that produced invalid JSON and reported "could not parse"
- a confirmation step that reported a field which cannot answer the question it
  was labelled with

When you change *who* runs something, re-verify *everything* it does. When you
add a check, prove it fails on the bug it exists to catch. And when a document
and the account disagree, **the account is right** — go and look.
