# Fanos Bingo

> ## 👉 New here? Read **[HANDOVER.md](HANDOVER.md)** first.
>
> It is the current state of the system in one page: what is live, what will
> mislead you, and what is left. Five things in particular are not obvious and
> have each cost real time —
>
> - **`dev` IS production.** Prod has never been applied; there is no staging.
> - **The FREE plan's credits run out ~Nov 2026**, before the Jan 2027 expiry,
>   and **no budget can see it** — credits absorb the bill before Cost Explorer.
> - **RDS PITR is capped at 1 day** and cannot be raised; setting it higher
>   fails the whole apply. Nightly dumps cover the gap — see [RESTORE.md](RESTORE.md).
> - **A green test here has three times meant broken code**, because the double
>   answered what the real dependency would refuse.
> - **`npm run build` does not typecheck.** Run `npm run typecheck`.


A real-time, multiplayer bingo game built as a Telegram Mini App with full on-chain integration on Binance Smart Chain (BSC). Players compete in live bingo rounds where the prize pool is distributed transparently through smart contracts.

---

## Table of Contents

- [Project status](#project-status)
- [Running it](#running-it)
- [What is left](#what-is-left)
- [Overview](#overview)
- [How It Works](#how-it-works)
- [Game Mechanics](#game-mechanics)
- [Blockchain Integration](#blockchain-integration)
- [Deposits](#deposits)
- [Withdrawals](#withdrawals)
- [Telegram Bot](#telegram-bot)
- [Admin Panel](#admin-panel)
- [Architecture](#architecture)
- [Vision](#vision)

---

## Project status

**Self-hosted on AWS, ~$30/month.** The server side was originally a hosted
Supabase project belonging to the upstream repository this is forked from. It is
being rebuilt on infrastructure this project owns.

**The game runs.** It loads inside Telegram at
[app.yisakmesifin.org](https://app.yisakmesifin.org), the board renders and the
countdown ticks — driven by a server-side game loop, not by a browser tab.

| Layer | State |
|---|---|
| Infrastructure (VPC, RDS, ECS, KMS, CloudTrail) | live in **dev**, Terraform, applied through CI |
| Database | PostgreSQL 16 on RDS, **120 migrations applied to dev**, PITR, restore drilled monthly |
| API (PostgREST) · realtime · game loop · TLS | running |
| Auth service | running — Telegram `initData` verified, JWT enforced by RLS |
| Mini App | served from Caddy at `app.<domain>`, built into the image |
| Joining and claiming | **working** — `/select-card` and `/claim-bingo`, identity and card layout derived server-side |
| Bank deposit (TeleBirr / CBE) | **working** — player claims, operator approves against their own statement. No wallet, no contract |
| Bank withdrawal | **working** — player requests, operator pays by hand and records the reference. `db/20-post/007` + `/withdrawals/*` |
| Backups | **nightly `pg_dump` to S3, kept 30 days**, alarmed on absence. RDS point-in-time recovery is capped at **1 day** by the account plan, so these are the only recovery point older than 24 hours. See [RESTORE.md](RESTORE.md) |
| Operator notifications | **per claim, to Telegram** — a deposit claim or withdrawal request reaches the operator in seconds. The 4-hour queue alarms remain as the backstop |
| Telegram bot | **answers `/start` and `/help`** with a button that opens the Mini App inside Telegram |
| Admin | Telegram identity + `is_admin`, **plus TOTP on money actions** (approve a deposit, complete a withdrawal). **Reachable two ways:** `t.me/BingoNovaaBot/app?startapp=admin` in Telegram, or the Login Widget at `app.<domain>/admin` in a browser. Bootstrap route promotes only the first admin, then disarms |
| Alerting | **working, and proven** — 17 alarms in the account (13 per-environment, 2 account-wide detections, 2 created by the ECS capacity provider), verified to reach a human by `scripts/verify-alarms.sh`. Delivery is **email + Telegram**; SMS was built and does not deliver on this account. Until 2026-08-01 **no per-environment alarm could deliver at all**; see `modules/kms` |
| Currency | **whole birr, integer, labelled ብር.** One row value = one birr. There is no sub-unit and no divisor |
| Database authorization | **enforced** — EXECUTE is an allowlist, `telegram_users` is owner-scoped, game state is read-only to clients, verified by `probe-public-access.sh` |
| Crypto (wallet login, BNB deposit/withdrawal) | **deferred, not removed** — every surface is behind `VITE_CRYPTO_ENABLED`, off by default. Ethiopian players overwhelmingly do not hold cryptocurrency, so birr is the currency that matters. Code, contract and KMS key all retained |
| Smart contract | **not deployed** — and not on the critical path while crypto is deferred |
| Production | Terraform written, plans cleanly, **never applied**. It inherits every fix below, so its first apply starts from a corrected baseline |

**The money round trip is closed:** deposit by bank, play, withdraw by bank. That is
the whole loop, with no wallet anywhere in it.

> **Deploy order matters once.** `db/20-post/008` closes a path that let any
> authenticated player mint an arbitrary `won_balance` with a single `PATCH` on
> `games` — a permissive inherited policy plus a blanket table grant plus a
> payout trigger that reads `winner_ids` straight from the update. That balance
> previously had no exit; the bank withdrawal routes give it one. **Apply `008`
> before deploying them.**

---

## Handover — read this first

> **Superseded for current state by [HANDOVER.md](HANDOVER.md)** (2026-08-09).
> This section is the 2026-08-01/02 snapshot and is kept because its task
> ordering and its "things that will bite you" are still accurate. Where the two
> disagree, HANDOVER.md is newer.

Everything below was found or built on **2026-08-01/02**. dev is fully deployed
and has been exercised by a real player with real money; **prod has never been
applied**.

### What has actually been proven end to end

A real deposit was made by TeleBirr, approved by an operator, spent on a game,
and the claim was correctly refused. Each of those exercised a path that had
previously only been tested against a fixture or with `curl`.

```
✅ deposit by bank → operator approves → balance credited
✅ join a game     → stake deducted, split across balances correctly
✅ claim bingo     → atomic_claim_bingo checked the card and refused a false claim
⬜ win → withdraw → operator pays        ← THE ONE UNTESTED LEG
```

**Closing that last leg is the highest-value next task**, and it is the gate
before prod. It needs a non-zero `won_balance`, which means either winning a game
or setting one through the SSM tunnel. Then **Withdraw** enables, a request is
filed, and the operator pays it from the admin queue — which exercises
`request_bank_withdrawal`, the pending-balance arithmetic in `WalletSummary`,
`complete_bank_withdrawal`, and the unique payout-reference guard in `007`.

### Tasks left, in the order I would do them

| # | Task | Why it is where it is |
|---|---|---|
| 1 | **Close the withdrawal leg** (above) | The only untested money path. Gate before prod |
| 2 | **Fix two stale `settings` rows** | `telegram_bot_username` says `Habeshabingo91bot` (the bot is `BingoNovaaBot`); `game_url` still points at `multiplayer-bingo-we-5btk.bolt.host`. Both editable in the admin Settings form |
| 3 | **Amharic labels on money actions** | `DEPOSIT (ገቢ)` / `WITHDRAW (ወጪ)`. Deliberately **not** done by me — getting a money verb subtly wrong in a language you do not speak is worse than leaving it in English. Ask the operator for exact wording |
| 4 | **Prod's first apply** | After 1. Requires the `prod` GitHub Environment reviewers (already configured) and `PROD_APPLY_ENABLED` (deliberately unset) |
| 5 | ~~**Telegram bot webhook**~~ | **Closed 2026-08-08.** `/start` and `/help` answer with a `web_app` button. Secret token checked strictly; registration is `scripts/register-telegram-webhook.sh`, run *after* deploy |
| 6 | **Root-cause the blanket table grant** | `db/20-post/001_rds_deltas.sql:121` grants `authenticated` write on every table. `012` neutralises it for all current and future tables, but the grant itself remains. Removing it has a regression surface of the whole schema |
| 7 | ~~**Admin auth is single-factor**~~ | **Closed 2026-08-08.** TOTP on the *action* — approving a deposit and completing a withdrawal require a code; reads and settings do not. Not enforced until the operator enrols, so it cannot lock the queue on deploy. `decided_by` on every approval remains the audit trail |
| 8 | **Reinstate `unhealthy_status 5xx`** in the Caddyfile, and the crypto path | Both are explicitly Stage-2 items. See the Caddyfile comments and `src/lib/features.ts` |

### Things that will bite you if you do not know them

- **Money is whole birr.** One integer in the database is one birr. There is no
  sub-unit. `formatBalance.ts` used to divide by 100 (a BNB leftover) and showed
  a player `0.40` for a balance of 40 — while the operator's queue printed `40`.
  Fixed 2026-08-02. Do not reintroduce a divisor; if crypto returns it needs a
  **real rate**, not a compiled-in constant.
- **Deploy order is migrations → `functions` → `caddy`.** Reversed at the first
  step there is a window where a player can mint a balance *and* cash it out.
- **`terraform apply` against dev also rolls `caddy` and `functions`** onto
  whatever image the SSM pointer names. That is the pointer mechanism working,
  not drift — but it means an infrastructure apply is also a deploy.
- **Crypto is deferred, not deleted.** Everything is behind
  `VITE_CRYPTO_ENABLED`, off by default, which cuts first load from 168.6 KB to
  100.0 KB gzipped. `db/20-post/010` closes `get_or_create_wallet_user` while it
  has no caller — **delete that migration in the same change that flips the
  flag.**
- **The admin panel is reachable two ways**, and neither is typing `/admin` in a
  browser without logging in — see the table above.

### The pattern this codebase keeps producing

**Things that report success while doing nothing.** A budget filter that rendered
as literal text and matched nothing. `ALTER DEFAULT PRIVILEGES ... REVOKE` that
wrote no ACL row. Four assertions that passed vacuously. An alarm that changed
state correctly and could not encrypt its own notification. None errored; every
one reported success.

The defence is the same every time: **execute the control, do not inspect its
configuration.** `SET ROLE anon` and query the table. Create a table and ask
whether it is writable. Fire the alarm and wait for the email. And when a lesson
is written down, **grep for the other place it applies** — `environments/account`
carried the CloudWatch key-policy statement, with a comment saying exactly what
its absence costs, while `modules/kms` went without it.

**Four of the defects fixed here were found by a human using the app on a phone**,
not by tests, typechecks, or bundle inspection: a clipped input field, a label
advertising a feature that did not exist, a deposit pending for a day, and the
100× currency error. `AGENTS.md` §5 and §6 have the full list.

### Routes the SPA no longer calls

The inherited Deno function names are not being ported. Each was resolved by
asking the question in `AGENTS.md` §7 — "why can RLS not do this?" — and most
answered "it can":

| Route | Resolution |
|---|---|
| `get-card-layouts` · `force-finish-game` | deleted; `get_all_card_layouts()` and `game_tick()` already did the work |
| `submit-deposit` · `record-withdrawal` · `manage-bnb-withdrawal` · `claim-winnings-to-contract` · `get-withdrawal-wallet-info` · `monitor-deposits` | crypto, deferred with the flag |
| `deselect-card` | rebuilt as `/deselect-card` + `release_card()`. RLS could not express "only while selection is open" — that condition lives on the `games` row |
| `update-settings` | rebuilt as `/admin/settings` + `admin_update_setting()`, **minus `telegram_bot_token`**. Writing that key back would have undone `db/20-post/003`, which redacted it after `curl /rest/v1/settings` returned a live one anonymously. It signs every player's login; it lives in SSM |
| `setup-telegram-webhook` | **not built.** The button that claimed to do it POSTed a 404 and did nothing. Now says so, rather than failing silently. The receiving route must verify `X-Telegram-Bot-Api-Secret-Token` strictly, and `setWebhook` must be re-registered with that secret **before** the check ships |

Engineering detail, decisions and their reasons live in **[AGENTS.md](AGENTS.md)**.
Read it before changing anything; most of it was learned expensively.

> **The other markdown files in this directory are inherited from the upstream
> project** and describe its Supabase deployment, which does not exist here. Each
> carries a banner saying so. Their design reasoning is often still worth
> reading; their setup steps are not. Do not follow an instruction from one
> without checking it against the three documents above.

### Security posture, in one paragraph

Authorization is enforced by the **database**, not by application code
remembering to check. A player proves their Telegram identity once, receives a
short-lived JWT whose claims match what PostgREST expects, and every subsequent
query runs under row-level security as that player. The hot wallet is a
**non-exportable KMS key** — no plaintext copy has ever existed — and exactly one
IAM role may ask it to sign, with a CloudTrail alarm on anything else. The origin
accepts traffic only from Cloudflare's published ranges.

That was true of the HTTP layer, which was rebuilt, and **not** of the database
underneath it until `db/20-post/004` — the SQL migrations were inherited wholesale
from a Supabase deployment where the edge functions used the service-role key and
RLS was decorative, so a permissive policy and a blanket `GRANT EXECUTE` survived
into a system that depends on neither being there. Both were found by `curl`, not
by review.

`004` is applied and `scripts/probe-public-access.sh` reports no exposures.
EXECUTE is now an allowlist rather than a blanket grant, so a function added in
future is not reachable by omission.

---

## Running it

Nothing reaches AWS except through GitHub Actions. There are no manual
`terraform apply` runs.

```bash
# infrastructure
gh workflow run terraform.yml -f environment=dev -f action=plan
gh workflow run terraform.yml -f environment=dev -f action=apply

# ship a service (build -> ECR -> SSM pointer -> rolling deploy)
gh workflow run deploy-services.yml -f service=functions -f environment=dev

# database migrations, through an SSM tunnel (RDS has no public endpoint)
gh workflow run db-migrate.yml -f environment=dev -f dry_run=true

# prove the security controls still work (also runs weekly on its own)
gh workflow run verify.yml -f environment=dev
```

Local checks that need no AWS:

```bash
npm --prefix services/functions install
npm run test:functions        # 263 assertions, 10 suites
./scripts/test-migrations.sh   # applies db/20-post to a throwaway postgres, twice
node scripts/check-migrations.mjs
terraform fmt -check -recursive infra/
```

### Deploy order, and the one case where it matters

Most of the time these three are independent and can go in any order. Once they
are not, and getting it wrong is expensive:

```
1. database migrations      gh workflow run db-migrate.yml -f environment=<env>
2. the functions service    gh workflow run deploy-services.yml -f service=functions ...
3. the Mini App (caddy)     gh workflow run deploy-services.yml -f service=caddy ...
```

**Migrations first, always, when a migration REMOVES a permission.**

`db/20-post/008` closes a path that let any authenticated player credit
themselves an arbitrary `won_balance` with one `PATCH` on `games`. Before the
bank withdrawal routes existed, a minted balance had nowhere to go — every
on-chain route is a 404. Those routes give it a cash exit, by hand,
irreversibly.

So deploying the `functions` image before the migration opens a window where
both halves are live at once. The reverse order has no such window: the
migration alone just makes a few admin actions fail until the image catches up.

The general rule, worth applying to migrations nobody has thought about yet:

| the change | order |
|---|---|
| a migration that REVOKES something | migration first |
| a migration that GRANTS something the code needs | migration first |
| a migration that only ADDS a table or function | either |
| code that stops calling something | code first, then drop it |

When in doubt, migrations first. A migration that runs early usually degrades a
feature; code that runs early can expose one.

### Reading `terraform plan` on an ECS change

A plan touching services routinely reports resources destroyed, and it is
almost never what it sounds like:

```
Plan: 2 to add, 4 to change, 2 to destroy
```

An **ECS task definition is immutable**. Terraform cannot edit one, so any
change at all — a new image tag, one added secret — is expressed as *destroy the
old revision, create a new one*. The two destroyed and the two added are the
same two resources. Nothing is torn down; `:4` is deregistered and `:5` takes
over, which is exactly what a normal deploy does.

What to actually look for in that summary:

- **`aws_ecs_service` should say `updated in-place`.** If a SERVICE is being
  replaced, that is a real outage — read why.
- **`aws_db_instance`, `aws_kms_key`, `aws_eip` in the destroy list.** Any of
  those is a stop-and-think. `prod` has `deletion_protection` and
  `skip_final_snapshot = false` precisely so the database cannot go quietly.
- **Task-definition churn you did not cause.** The image tag moves whenever CI
  has pushed a newer build than the last apply — that is the SSM image-pointer
  mechanism in `modules/app_stack` converging, not drift to be alarmed by. But it
  does mean an infrastructure apply will ALSO roll those services onto the newer
  image. Know that before running one at a busy moment.

---

## What is left

Ordered by what unblocks the most. Engineering detail for every item is in
**[AGENTS.md](AGENTS.md)** §0.

**1. Bank withdrawal routes and UI.** `db/20-post/007` has the correctness layer —
overdraft prevention, one payout per request, decided rows frozen — and nothing
calls it. `services/functions/src/deposits.js` is the worked example to mirror.
The player-facing button is deliberately absent rather than 404ing.

**2. Fund the wallet from the testnet faucet.** Free, and the only thing blocking
the three on-chain routes (`submit-deposit`, `record-withdrawal`,
`manage-bnb-withdrawal`). Note the faucet now wants ≥0.002 BNB on **mainnet** as
an anti-abuse gate, and the dev wallet has nothing on either network.

Bank deposits work today without it, so this no longer blocks players.

**3. ~~Build the bot webhook.~~ Done 2026-08-08.** `POST /telegram/webhook`
answers `/start` and `/help` with a **`web_app` button**, not a link — a bare URL
opens a browser, where the Mini App has no `initData` and the player cannot log
in. Authentication is `X-Telegram-Bot-Api-Secret-Token`, checked strictly: a
*missing* header is refused, because a forger simply omits it.

Registration is a separate step, `scripts/register-telegram-webhook.sh`, and the
order matters — deploy first, register second, or the bot goes silent.

> Worth keeping: `verifyWebhookSecret` would have **thrown on Telegram's first
> call**. It read `req.headers.get(...)`, the Fetch shape it was written for
> under Deno; Express has no `.get()` on `req.headers`. Nothing caught it because
> nothing called it, and its test builds a real `Request`. A test exercising a
> shape production never presents is not covering the code.

**4. ~~Replace single-factor admin auth.~~ Done 2026-08-08.** TOTP **on the
action**, not the login: approving a deposit and completing a withdrawal ask for
a code. Reads, ending a game and settings do not — six digits per action is a
real cost to someone clearing an overnight queue, and it is worth paying only
where money moves.

Not enforced until enrolled, deliberately: enforcing on an un-enrolled admin
would lock the deposit queue on deploy, causing the outage
`deposits-waiting-too-long` exists to catch. Enrol in **Admin → Settings →
Security**.

> The secret lives in its own `admin_totp` table, not on `telegram_users`. The
> first version used a column there and the migration's own assertion refused it:
> that table grants `SELECT` to `authenticated` at **table** level, and PostgREST
> serves every column a role may read — so
> `/rest/v1/telegram_users?select=totp_secret` would have handed the secret to
> the owner of that row, who is exactly the attacker with a stolen session.

**5. Production.** Terraform is written and plans cleanly, never applied. Needs
mainnet values and a funded wallet. Run the restore drill against prod once —
dev's 8–11 minute figure is not prod's.

**Known and not accepted:** no capacity data at all (the spike test has never run,
and `k6` is not installed — the npm entry is an autocomplete stub); the Cloudflare
rate-limit rule applies cleanly and **does not enforce**, so it is not a control
until somebody reads the dashboard analytics.

**Known and accepted:** single instance in a single AZ (~3–5 min MTTR); the SPA is
served from that instance, so a replacement blanks it for anyone who misses
Cloudflare's cache.

### Because dev is the live environment, dev now carries prod's protections

This section of the README has said since 2026-08-01 that dev holds real player
money and prod has never been applied. The **configuration had not caught up with
that sentence**, which is a different failure from not knowing:

- `infra/environments/dev/main.tf` still read `deletion_protection = false`,
  `skip_final_snapshot = true`, under a comment saying dev is disposable. The
  environment holding real balances was the one set up to be deleted without a
  final snapshot. **Deletion protection is now ON** — set directly on the live
  instance on 2026-08-03, not merely declared — and a final snapshot is required.

> **The 24-hour recovery window could not be closed, and this is the reason.**
> Raising `backup_retention_period` above 1 is refused by the account plan:
>
> ```
> FreeTierRestrictionError: The specified backup retention period exceeds the
> maximum available to free tier customers. Upgrade your account plan.
> ```
>
> Retried with 2 and refused identically — the ceiling is exactly 1. Lifting it
> is a billing decision: `aws freetier get-account-plan-state` reports
> `FREE / ACTIVE`, **$154.48 credits remaining, expiring 2027-01-14**. On a Free
> plan, exhausting credits *suspends* resources rather than billing for them — so
> a real-money game is currently scheduled to stop on a date nobody chose.
> Upgrading to Paid lifts the cap and removes the suspension risk in one step.
>
> **AWS caps retention. It does not stop us keeping our own copies.**
> `.github/workflows/db-backup.yml` takes a nightly `pg_dump` through the
> existing SSM tunnel into an S3 bucket in the **account** root, kept 30 days.
> The database holds a few MB of real data, so thirty compressed dumps sit inside
> the 5 GB S3 free tier — this costs approximately nothing and is the reason the
> plan cap is no longer the whole story.
>
> The two answer different questions and neither replaces the other. PITR undoes
> *the last 24 hours* to any second. The dumps undo *last Monday*, at nightly
> granularity — which is the range that matters for the failures that actually
> cost money here: a bad migration, a fraudulent approval, a wrong `UPDATE`.
> Those are quiet, and they surface in days.
>
> Two things make it a backup rather than a cron job. The archive is **parsed
> back** with `pg_restore --list` before it counts, because a truncated dump
> uploads perfectly happily. And a heartbeat metric drives
> `<prefix>-backup-did-not-run`, which treats **absent data as breaching** — so
> the workflow being disabled, or GitHub never firing the cron, alarms. A failure
> notification alone cannot cover that: nothing fails, so nothing reports.
>
> **See [RESTORE.md](RESTORE.md) before you need it.** It covers which of the two
> paths to reach for, and the one mistake that turns a good backup into a bad
> recovery: `--no-privileges` does not skip RLS policies, so restoring without
> first creating `anon`, `authenticated` and `service_role` silently drops every
> policy and leaves a database that looks restored and has lost its authorization
> layer.
>
> **Restorability is proven by hand, not automatically.** The 2026-08-07 dump was
> restored into PostgreSQL 16 and loaded 4 players / 7 games / 3 deposits. Eight
> CI runs failed to get a throwaway database reachable on a GitHub runner, so
> that check was removed rather than left warning every night — RESTORE.md
> records what was ruled out. Repeat the manual restore after any schema change.
- `terraform.yml`'s destroy job refused `prod` and `account` and waved `dev`
  through, on the same assumption. Destroy now requires the environment name to
  be **typed**, and refuses any environment whose database has deletion
  protection on — a check that follows where the money is rather than which name
  somebody chose, so it stays correct after cutover without being revisited.
- Nothing checked the site was reachable **from outside AWS**. Every alarm read a
  metric published from inside it, so a failed Elastic IP re-association — the
  documented recovery path after an instance replacement, which only `echo`s on
  failure — leaves every alarm green while no player can connect. There is now a
  Route 53 health check on `api.<domain>/healthz`. It creates no DNS; Cloudflare
  stays authoritative.
- The `$10` budget could not have alerted regardless of its threshold: the
  `Environment` cost allocation tag was **Inactive**, and Budgets cannot filter
  on an unactivated tag. `infra/environments/account` now activates it and adds
  an unfiltered account-wide budget, because a tag filter cannot see data
  transfer, KMS requests, or the two `Scope=account` buckets.
- Only `/auth/telegram*` was rate limited. Every authenticated route — including
  `/deposits/claim` and `/withdrawals/request` — accepted work as fast as one
  client could send it, against a connection pool of five. Per-player limits now
  cover them, keyed on the verified uid.

**Deferred by decision, not oversight:**

- **GuardDuty is off, on cost.** It is the detection that would catch credential
  misuse — including of the admin IAM user below, which every control in
  `infra/environments/account` is bypassed by. At this footprint it is a few
  dollars a month, which is real against a $10 budget on an account currently
  billing ~$0. Revisit when the budget has room; it is a one-resource change.
- **The `AdministratorAccess` IAM user is untouched.** Worth periodically
  checking what `aws iam get-credential-report` says about its MFA state, since
  it is the shortest path around everything else here.
- **AWS SMS alerting stays off, on cost and enrolment.** It was built, applied,
  reported active by SNS, and delivered nothing — see below. Making it work
  means enrolling in AWS End User Messaging, requesting production access to
  leave the SMS sandbox, and registering a `+251` origination identity, and each
  SMS is then billed. Deferred deliberately until there is budget for it. The
  subscription is left in place and empty so it becomes correct the moment the
  account is enrolled.

  It is worth revisiting despite the cost, for one reason the Telegram channel
  cannot match: **SMS is the only alert path that does not depend on this
  system's own infrastructure.** Telegram alerts are forwarded by the `functions`
  container, so if that container is what breaks, that channel breaks with it.
  Email covers the gap today, and SMS would cover it better.

### The SMS channel was built and does not deliver

Recorded because the symptom is indistinguishable from working, and the obvious
diagnosis is wrong.

An SNS **SMS subscription needs no confirmation click**, so it reports as active
whether or not anything arrives. Firing a real alarm produced emails and no SMS.
The cause is not the phone number and not Ethiopia — all three SMS APIs refuse at
the **account level, before any number is read**:

```
aws sns get-sms-sandbox-account-status
UserError: The AWS Access Key Id needs a subscription for the service
           (Service: PinpointSmsVoiceV2)
```

SNS SMS is delivered by AWS End User Messaging, which this account is not
enrolled in, so it would have failed for a US number identically. The same shape
appears on GuardDuty and Security Hub here (`SubscriptionRequiredException`) —
several services are simply not switched on for this account.

**The lesson generalises past SMS:** a channel that reports healthy is not a
channel that delivers. Prove any alerting change against the receiving device:

```
./scripts/verify-alarms.sh dev --fire fanosbingo-dev-game-loop-stalled
```

Alarms now reach Telegram instead, forwarded by the `functions` service — chosen
over a Lambda precisely because a Lambda is another AWS service to be enrolled
in, which is the failure being worked around.

---

## Overview

Fanos Bingo is a skill and speed-based competitive game - not gambling. Every round has deterministic, code-enforced rules. Winners are decided by who completes a valid bingo pattern first on their card. Prize distribution is handled by a BSC smart contract, ensuring full transparency and no custodial risk.

The game runs entirely inside Telegram as a Mini App, making it accessible to millions of users without any app installation.

---

## How It Works

### Player Journey

1. Open the Fanos Bingo Telegram Mini App
2. Fund the account — **by bank transfer (TeleBirr or CBE), or with BNB**. A crypto
   wallet is needed only for the BNB path; bank deposits and playing need none
3. Deposit BNB to receive in-game credits (1 BNB = 100,000 credits by default)
4. Enter the lobby and pick a card number (1-99)
5. Wait for the round to start and play in real-time
6. If you complete a bingo pattern first, claim your win and receive the prize

---

## Game Mechanics

### Cards

Each player gets a standard 5x5 bingo card with numbers distributed across five columns:

| Column | Range  |
|--------|--------|
| B      | 1-15   |
| I      | 16-30  |
| N      | 31-45  |
| G      | 46-60  |
| O      | 61-75  |

The center cell (N column, row 3) is a free space.

### Winning Patterns

A player wins by completing any of the following:

- Any horizontal row (5 cells)
- Any vertical column (5 cells)
- Either diagonal (5 cells)
- Four corners

### Number Calling

Numbers are called automatically every 3.5 seconds by a scheduled backend function. Numbers range from 1 to 75 and are never repeated within the same round.

### Auto-Mark

When a called number matches a number on a player's card, that cell is automatically marked. Players do not need to manually mark cells.

### Claiming a Win

When a player completes a valid winning pattern, a 1-second claim window opens. The first valid claim within that window wins the round. This prevents race conditions and ensures fairness when multiple players complete patterns simultaneously.

### Staking

Each player stakes a fixed amount of credits to enter a round. The total staked amount forms the prize pool.

- Winner receives 75% of the prize pool
- 25% is retained as a platform fee
- If a player leaves before the round starts, their stake is fully refunded

---

## Blockchain Integration

Fanos Bingo uses Binance Smart Chain (BSC) for all financial operations. Two smart contracts power the system:

### Deposit Contract (`FanosBingoDeposit.sol`)

Handles incoming BNB deposits and converts them to in-game credits.

- Accepts BNB and records the depositing wallet and linked Telegram user ID
- Configurable conversion rate (owner-adjustable)
- Minimum deposit enforced on-chain
- Emits events for every deposit, withdrawal, and rate change so the backend can track them off-chain

### Withdrawal Contract

Handles outgoing payments from won balance to player wallets.

- Signature-based authentication ensures only legitimate withdrawals are processed
- Daily and weekly withdrawal limits per user
- Functions: `withdraw()`, `claimAndWithdraw()`, `claimWithSignature()`
- Tracks each user's remaining limits

---

## Deposits

### Crypto (BNB) Deposits

1. Connect wallet inside the app
2. Send BNB to the deposit contract address
3. Submit the transaction hash inside the app
4. The backend monitors BSC for the transaction and waits for 3 confirmations
5. Credits are added to your deposited balance automatically

### Bank Deposits (Optional)

An optional SMS-based deposit flow supports Ethiopian bank transfers:

1. User makes a bank transfer and the bank sends an SMS confirmation
2. The SMS is forwarded to the backend via the `receive-bank-sms` edge function
3. The system extracts the amount and reference number automatically
4. An admin verifies and approves the deposit

---

## Withdrawals

Players withdraw their won balance to their own wallet at any time. The design
is **non-custodial**: the backend never sends a player's funds and never signs a
withdrawal.

1. The player wins; the backend credits that amount on-chain with
   `addWinCredits()`, signed by a KMS key no human can export
2. The player calls `withdraw()` on the contract **themselves**
3. BNB moves from the contract to their wallet, without the operator in the path

Withdrawal limits are enforced **on-chain** by the contract, per day and per
week. Database-side tracking is kept for analytics and is not authoritative.

> Earlier revisions had the backend generate a signed authorization the player
> then submitted. That was replaced (migration `20260216`) precisely to keep the
> operator out of the withdrawal path — the backend's only signing job now is
> crediting wins.

---

## Telegram Bot

The Telegram bot handles notifications and commands:

- Notifies players when a game is starting, when they win, and when deposits or withdrawals are processed
- Accepts balance transfer commands (move credits between deposited and won balance)
- Sends formatted messages with inline action buttons

### Referral System

Each user gets a unique referral code. When a new user signs up using your code, both you and the new user receive a bonus. Referrals are capped at 20 per user to prevent abuse.

---

## Admin Panel

The admin panel is protected by multi-step authentication:

1. Access key
2. Time-based one-time password (TOTP / 2FA)

Admin capabilities:

- View all active games and player activity
- Force-finish a game if needed
- Manage bank deposit options
- Approve or reject manual deposit requests
- Manage BNB withdrawal requests
- Configure game settings (stake amount, commission rate, contract addresses, bot token, etc.)
- View financial reports through the accountant dashboard

---

## Architecture

```
Telegram Mini App (React + Vite)
        |
        | Supabase Realtime (live game updates)
        |
Supabase Edge Functions (Deno)
        |
        |--- PostgreSQL Database (game state, balances, users)
        |--- BSC Smart Contracts (deposits, withdrawals)
        |--- Telegram Bot API (notifications, commands)
        |--- Cron Jobs (auto number caller every 3.5s)
```

### Key Technologies

| Layer | Technology |
|-------|------------|
| Frontend | React 18, TypeScript, Vite, TailwindCSS |
| Wallet | Wagmi v3, Viem v2, Reown (WalletConnect v3) |
| Backend | Supabase Edge Functions (Deno runtime) |
| Database | Supabase PostgreSQL with Row Level Security |
| Realtime | Supabase Realtime channels |
| Blockchain | Binance Smart Chain, Solidity 0.8.20 |
| Messaging | Telegram Bot API, Telegram Mini App SDK |

### Security

- Row Level Security (RLS) enforced on every database table
- Admin 2FA with TOTP
- Wallet address validation before crediting
- Blockchain confirmation threshold before deposits are accepted
- Signature-based authorization for withdrawals
- Referral abuse prevention with per-user caps

---

## Vision

Fanos Bingo is the foundation for a broader ecosystem of on-chain competitive mini-games.

The next major milestone is integrating autonomous AI agents that can participate as players. These agents will learn game patterns, compete against human players, and eventually enable fully agent-vs-agent matches. All outcomes will be recorded on-chain, creating provably fair, transparent competition between humans and AI.
