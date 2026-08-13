# Handover — read this before changing anything

**Written 2026-08-09. Substantially corrected 2026-08-11 after the prod
cutover.** For whoever picks this up next, human or agent.

This is a real-money game **in the sense that it is built to hold real money**,
and it does not hold any yet. The wallet is empty on both BSC networks and no
player balance is backed by anything — checked directly, not inferred.

That is a window, not a permanent state, and it is the most useful thing on this
page. Everything that is expensive-to-impossible once the first deposit lands —
load testing to failure, killing the instance to time recovery, restoring a
backup over the live database, removing the blanket table grant — is free right
now. Do it before that changes.

> This paragraph previously read "a deposit was made by TeleBirr... by a real
> person with real birr." It was wrong, and it drove the shape of this whole
> document and of the cutover plan for two days. If a document and the account
> disagree, the account is right.

---

## The five things that will mislead you

Read these first. Each one cost real time or a real incident.

### 1. TWO DOMAINS. `prod` is bingonova.org; `dev` is yisakmesifin.org

| | prod | dev |
|---|---|---|
| domain | **bingonova.org** | **yisakmesifin.org** |
| Cloudflare zone | `9bf80a12…` | `8166779c…` |
| bot | `@BingoNovaaBot` | `@BingoNovaadevelopmentbot` |

**Every command in this document names prod's domain.** Point them at
yisakmesifin.org and you are inspecting dev -- which during a prod incident will
look perfectly healthy and tell you nothing.

`yisakmesifin.org` was prod's until 2026-08-12 and is now dev's, so anything
older than that date naming it as production is stale rather than wrong at the
time.

### `dev` is the rollback, and is going away

**This section said the opposite until 2026-08-11.** It said `dev` was the only
environment and served the live domain, that it must therefore be protected like
production, and that anything reading "dev is disposable" was stale. All of that
was true when it was written and none of it is true now.

Verified in the account, not inferred:

```
terraform state       account/  dev/  prod/
EIP behind the domain fanosbingo-prod-app   3.227.224.76
prod                  5 services 1/1 · 122 migrations · 13 alarms, all OK
dev                   5 services 1/1 · no DNS points at it
```

`api`, `app` and `rt` resolve to Cloudflare and are proxied to **prod**. Measured
rather than assumed: over three minutes, prod's Caddy logged 180 requests and
dev's logged none.

**`dev` is retained deliberately as the rollback**, not because anything needs
it. It keeps its RDS protections for exactly as long as that is true. When it is
destroyed, the S3 dumps under `dev/` survive regardless -- Object Lock holds them
for 30 days past their write, which nothing in the account can override.

**There was never real money in either environment.** The earlier version of this
section said "real birr has moved through it", and that premise drove the whole
shape of this document -- and, for a while, of the cutover plan. The wallet held
zero BNB on both networks, checked directly. If a document and the account
disagree, the account is right; this section is the reason that rule exists.

Two practical consequences, both changed:

- **There is now somewhere to test.** `dev` is stood up, tested against and
  destroyed -- `CUTOVER.md` records the model, and `scripts/seed-dev.sh` takes a
  fresh one from empty to usable in a single step.
- **`dev` manages its own Cloudflare zone again**, since 2026-08-12. This said
  `manage_cloudflare` must stay `false` "permanently", and that reasoning was
  entirely about the two environments sharing an apex -- writing `api`/`app`/`rt`
  would have repointed production. They no longer share one, so it no longer
  would, and the Cloudflare layer stopped being the one part of the stack `dev`
  could not test.

### 2. The account is on the FREE plan, and credits run out before the expiry

```
plan          FREE / ACTIVE
credits       $141.67, falling ~$2.20/day with BOTH environments running
expiry        2027-01-14
```

Two deadlines. **The credits bind first — roughly mid-October 2026**, and every
document quotes the January date. The rate doubled when prod was stood up
alongside dev: one environment burns about $1.30/day, two burn about $2.20.
Retiring dev is the single biggest lever on how long this runs. On a FREE plan, exhausting credits
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
set `backup_retention_period` above 1 in either environment.** It does not fail
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

**Run `npm run typecheck` before shipping SPA changes.** It is a BLOCKING GATE
in CI since 2026-08-13, and main is clean — all eleven findings were read and
either wired up or removed on purpose, which was the condition the advisory
comment set for promoting it.

It keeps earning it. On the day it became a gate it caught a call to a function
that does not exist, in a change whose `npm run build` passed.

---

## What is repeatable, and what is not

Everything routine is a workflow. Two things deliberately are not, and the
distinction matters more than the list.

| | how | when |
|---|---|---|
| deploy a service | `deploy-services.yml` | on demand |
| infrastructure | `terraform.yml` | PR plans, dispatch applies |
| schema | `db-migrate.yml` | dry run, then real |
| secrets into SSM | `sync-secrets.yml` | after an apply creates the KMS key |
| **backup** | `db-backup.yml` | nightly 04:00 UTC, **prod** |
| **restore drill** | `db-restore-drill.yml` | monthly, into a temporary instance |
| **controls audit** | `verify.yml` | weekly Monday, **prod** |
| **credit runway** | `free-tier-runway.yml` | daily 05:00 UTC, **prod** |
| **load test** | `load-test.yml` | on demand, never scheduled |
| **recovery drill** | `recovery-drill.yml` | on demand, never scheduled |
| OS image pin | `ami-bump.yml` | weekly, by pull request |

**The two drills are deliberately NOT scheduled.** Load and instance
termination are things you choose to apply while watching. A nightly load test
against production is a nightly outage waiting for the night it finds a limit,
and an unattended recovery drill is an unattended outage.

**Restoring over a LIVE database is deliberately not a workflow.** It destroys
data, and one click is the wrong interface for that. `db-restore-drill.yml`
automates the safe half -- restore into a temporary instance and count the rows.
The live version is in RESTORE.md, has been done once, and should stay a
deliberate act.

Three scripts are run by hand and should stay that way: `seed-dev.sh` (refuses
to run against prod), `seed-bank-options.sh` (prompts, so real account numbers
never reach shell history) and `register-telegram-webhook.sh` (refuses if two
environments share a bot token, because a bot has exactly one webhook and
setWebhook REPLACES rather than rejects).

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

`terraform apply` against an environment **also rolls `caddy` and `functions`** onto
whatever image the SSM pointer names. That is the pointer mechanism working, not
drift — but an infrastructure apply is also a deploy, and it briefly drops the
site (one instance, static host ports, `deployment_minimum_healthy_percent = 0`).
Check `ActiveGames` before applying.

### Verifying, rather than assuming

| Question | Command |
|---|---|
| Can a player reach the site? | `curl -s -o /dev/null -w '%{http_code}' https://api.bingonova.org/healthz` |
| Do alarms reach a human? | `./scripts/verify-alarms.sh prod --fire <alarm>` — **believe the device, not the console** |
| Is a permission actually granted? | `aws iam simulate-principal-policy` — it caught two false pages here |
| Did a backup land? | `aws s3 ls s3://fanosbingo-backups-<account>/prod/` |
| What is the free-tier runway? | `aws freetier get-account-plan-state` |

---

## When something is wrong

Nothing below was written down anywhere before. Both were verified against the
live account on 2026-08-09.

### The site is down

Work outward. Each step rules out a layer.

```bash
# 1. Is it reachable at all, and from outside AWS?
curl -s -o /dev/null -w '%{http_code}\n' https://api.bingonova.org/healthz
aws route53 get-health-check-status --health-check-id <id>   # 16 global probers

# 2. Are the containers running?
aws ecs describe-services --cluster fanosbingo-prod --region us-east-1 \
  --services caddy functions ticker postgrest realtime \
  --query 'services[].[serviceName,runningCount,desiredCount]' --output text

# 3. What did the service say?
aws logs filter-log-events --log-group-name /ecs/fanosbingo-prod \
  --start-time $(( ($(date +%s) - 900) * 1000 )) --filter-pattern '"level":"error"'

# 4. Is the database reachable from the service?
curl -s https://api.bingonova.org/functions/v1/readyz     # 503 = DB unreachable
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
aws ecs describe-services --cluster fanosbingo-prod --region us-east-1 \
  --services functions --query 'services[0].taskDefinition' --output text
aws ecs list-task-definitions --region us-east-1 \
  --family-prefix fanosbingo-prod-functions --status ACTIVE --sort DESC --max-items 5

# Roll back to the previous revision
aws ecs update-service --cluster fanosbingo-prod --region us-east-1 \
  --service functions --task-definition fanosbingo-prod-functions:<previous>
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
>   --task-definition fanosbingo-prod-functions:<bad>
> ```
>
> Otherwise treat the rollback as buying time, and fix forward.

### Getting a shell, and reaching the database

There is no SSH and no bastion, by design. Both go through SSM.

```bash
aws ecs execute-command --cluster fanosbingo-prod --region us-east-1 \
  --task <task-arn> --container functions --interactive --command /bin/sh

source scripts/db-tunnel.sh prod     # exports DATABASE_URL, forwards to :15432
psql "$DATABASE_URL" -c 'SELECT 1'
stop_db_tunnel
```

Every SSM session is a CloudTrail event attributable to an IAM principal, which
is the reason it is the only path in.

---

## Open work

**Nothing here is blocked on code.** Everything an engineer could do without a
decision from the operator has been done; what remains needs either a person at
a keyboard or a commercial choice.

### 1. Nobody has played a full round on prod — **the only untested thing that matters**

Deposit, approve, join, play, claim. prod has bank options, an admin, a working
bot, a login widget, measured capacity and measured recovery. Every check in this
repository is infrastructure; none of them tells you the game works.

It needs a real Telegram account, so it cannot be automated from here.

### 2. Decide when to retire `dev`

It has earned its place: four SPA bugs, the blanket-grant change and both drills
were found or proven there. It also costs roughly six weeks of runway -- two
environments burn about $2.2/day against $145 remaining, so mid-October rather
than early December.

Retiring it is a short PR plus two applies, and `CUTOVER.md` Phase 3 lists the
order. The `dev/` dumps in S3 survive the teardown regardless: Object Lock holds
them 30 days past their write.

### 3. `DepositManagement` authenticates as nobody

It reads `deposit_transactions` through `supabase.from()` under RLS alone, and
its one authenticated call sends `VITE_SUPABASE_ANON_KEY` as the bearer. It
returns nothing today only because the table is empty, so it is **untested rather
than working**.

The `adminKey` prop was the unwired half of this, and removing it from the
destructuring during the typecheck cleanup removed the compiler's flag on it. See
the caveat in AGENTS.md §"The SPA typecheck findings". It belongs with replacing
the shared admin string, not before it.

### 4. The Cloudflare rate-limit rule still does not enforce

Applies cleanly, reports `enabled: true`, and the load test sent 99,392 requests
at up to 764/s from one IP for **429 x 0**. Not proof of a misconfiguration --
the rule may not match that path -- but it is not limiting anything. Do not count
it as a control until someone reads the dashboard's rate-limiting analytics.

---

## Recently closed, kept as a record

Each of these was open a week ago. The reasoning is in the linked commits; what
matters here is that none of them is still work.

| | closed |
|---|---|
| "Back to lobby" | 2026-08-13, after four attempts and three wrong ones. Confirmed by the operator |
| Two stale `settings` rows | 2026-08-13 on both environments. **They come from the migrations**, so a freshly migrated environment inherits them again -- and restoring an old backup rolls them back, which happened to dev on the 13th |
| `npm run typecheck` as a gate | 2026-08-13, blocking, main clean at zero findings |
| `npm run lint` in CI | 2026-08-13, blocking on errors |
| Zero capacity data | 2026-08-13. prod: **764 req/s at 200 concurrent**, lobby p95 245ms, CPU 78%, RDS connections flat at 20 of ~112. `load-test.yml` |
| Unmeasured MTTR | 2026-08-13. prod **194s**, dev 99s, Elastic IP re-attached so Cloudflare needs no DNS change. `recovery-drill.yml` |
| Restore never proven | 2026-08-13, over a live database: 190s, data rolled back, stack answering after. RESTORE.md |
| The blanket table grant | 2026-08-13, on both environments. It existed only for `012` to revoke, and the gap was a window as long as a migration run |

### Deferred on cost, by the operator's decision

Not oversight — recorded so nobody re-derives them:

- **GuardDuty** — a few dollars a month; the detection that would catch misuse
  of the admin IAM user
- **AWS SMS alerting** — built, applied, and delivers nothing: the account is not
  enrolled in AWS End User Messaging. **Not** a restriction on Ethiopian
  numbers; it would fail for a US number identically
- **Backup retention > 1 day, Multi-AZ, a second instance** — all need the paid
  plan

### Untouched by request

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
