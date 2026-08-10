# Cutover — standing up `prod` and retiring `dev`

**Written 2026-08-10.** Read the whole thing before running any of it.

This runbook exists because the environment serving `api.yisakmesifin.org` is
called `dev`, and every document in this repository has had to work around that.
The fix is to stand `prod` up, move the domain to it, and destroy `dev`.

## Why now, and why this is cheap

**There is no real money in any environment.** Verified 2026-08-10 rather than
assumed:

```
hot wallet 0xE509727904C1B057E58BCe7f4eC5bFb120D5adDF
  BSC testnet   0 BNB
  BSC mainnet   0 BNB
```

That single fact is what makes this a deployment rather than a migration. With
funds on chain it would be an operation with a maintenance window, a rollback
plan, and an on-chain fund move that must complete before `dev`'s KMS key hits
its 7-day deletion window — because KMS never exports private key material, so a
missed window is money gone permanently.

None of that applies today. **It will apply the moment the first real deposit
lands**, and it will never be this cheap again. That is the whole argument for
doing it now.

The corollary matters as much: everything else that is only possible without
players — load testing to failure, killing the instance to time EIP
re-association, restoring a backup over the live database — should be done on
`prod` **after** this cutover and **before** launch. See [the last
section](#after-the-cutover-and-before-players).

---

## Phase 0 — Blockers, verified by reading the code

Two things will stop the first apply. Neither is a surprise; both are recorded
in the code itself.

### `prod` cannot apply on the FREE account plan

[`infra/environments/prod/main.tf`](infra/environments/prod/main.tf) sets
`backup_retention_period = 7`, and its own comment says why that fails:

```
FreeTierRestrictionError: The specified backup retention period exceeds the
maximum available to free tier customers.
```

Measured on this account against `dev`, retried with `2`, refused identically —
the ceiling is exactly 1. It does not fail quietly; it fails the whole apply.

**Resolution taken here: lower it to 1, with the reason written down and a
condition for raising it.** That is defensible *today* precisely because there is
no money — a 24-hour recovery window on test data costs nothing. It is not
defensible the day players arrive, which is why the comment names that day as the
trigger rather than leaving it to be rediscovered.

The alternative is upgrading to a paid account plan, which also lifts Multi-AZ
and GuardDuty and removes the credit-exhaustion deadline. That is a billing
decision, not an engineering one.

### `prod` will come up with no application on it

`modules/app_stack` creates each ECS service only when SSM holds an image pointer
for it, and `prod`'s five ECR repositories will be empty. So the first apply
produces a VPC, a database and an idle container instance — correctly, and by
design.

`deploy-services.yml` already handles this: it pushes the image, writes the SSM
pointer, notices the service does not exist, and dispatches `terraform.yml` to
create it. No manual step, but expect each first deploy to take two workflow runs.

### What is *not* a blocker

- **DNS.** `manage_cloudflare` defaults to `false` in `prod`, so the first apply
  cannot touch `api`/`app`/`rt`. This is what makes Phase 1 safe to run while
  `dev` is serving players.
- **VPC collision.** `dev` is `10.30.0.0/16`, `prod` is `10.20.0.0/16`.
- **Chain.** `prod` defaults to `bsc_chain_id = 56` (mainnet) against
  `bsc-dataseed1.binance.org`. The crypto path is inert either way — the deposit
  contract is not deployed and the wallet is empty — so bank deposits are
  unaffected. Leave it at mainnet; it is what `prod` should mean.

---

## Phase 1 — Stand `prod` up beside `dev`

Nothing here is visible to a player. `dev` keeps serving throughout.

```bash
# 1. Populate prod's parameter tree from the repository secrets.
gh workflow run sync-secrets.yml -f environment=prod

# 2. Read the plan. Expect: VPC, RDS, EC2, KMS, ECR, IAM, SSM, monitoring.
#    Expect NO cloudflare resources and NO ECS services.
gh workflow run terraform.yml -f environment=prod -f action=plan

# 3. Apply. The `prod` GitHub Environment requires a reviewer.
gh workflow run terraform.yml -f environment=prod -f action=apply

# 4. Schema. Dry run first — it prints filenames and executes nothing.
gh workflow run db-migrate.yml -f environment=prod -f dry_run=true
gh workflow run db-migrate.yml -f environment=prod -f dry_run=false

# 5. Services, in this order. Reversed at the first step there is a window
#    where a player can mint a balance AND cash it out.
for s in ticker postgrest realtime functions caddy; do
  gh workflow run deploy-services.yml -f environment=prod -f service=$s
done
```

### Verifying `prod` before it owns the domain

**You cannot `curl` it from your laptop.** `sg-app` admits 443 from Cloudflare's
published ranges only, and Cloudflare is not in front of `prod` yet. A direct
request to the Elastic IP times out — which looks exactly like a broken
deployment and is not one.

Two honest options:

```bash
# A. Temporary ingress for your own address. Remove it the moment you are done.
MYIP="$(curl -s https://checkip.amazonaws.com)/32"
SG=$(aws ec2 describe-security-groups --region us-east-1 \
  --filters Name=group-name,Values=fanosbingo-prod-app \
  --query 'SecurityGroups[0].GroupId' --output text)
aws ec2 authorize-security-group-ingress --region us-east-1 --group-id "$SG" \
  --protocol tcp --port 443 --cidr "$MYIP"

PRODIP=$(aws ec2 describe-addresses --region us-east-1 \
  --filters Name=tag:Name,Values=fanosbingo-prod-app \
  --query 'Addresses[0].PublicIp' --output text)

curl -sk --resolve "api.yisakmesifin.org:443:$PRODIP" \
  https://api.yisakmesifin.org/healthz
curl -sk --resolve "api.yisakmesifin.org:443:$PRODIP" \
  https://api.yisakmesifin.org/functions/v1/readyz    # 503 = DB unreachable

aws ec2 revoke-security-group-ingress --region us-east-1 --group-id "$SG" \
  --protocol tcp --port 443 --cidr "$MYIP"

# B. From inside, no rule needed.
aws ecs execute-command --cluster fanosbingo-prod --region us-east-1 \
  --task <task-arn> --container functions --interactive --command /bin/sh
```

`--resolve` rather than editing `/etc/hosts`, and the Host header must be the
real hostname: Caddy routes on `api.{$DOMAIN}` and a request arriving with an IP
in the Host header falls through to the catch-all.

Do not proceed until `healthz` is 200 **and** `readyz` is 200. The second is the
one that proves the database is reachable from the service.

---

## Phase 2 — The cutover

### Data: start clean

`dev` holds 4 test users, 7 games and 3 deposit requests. **Recommendation: do
not migrate it.** Starting `prod` with an empty ledger removes the entire class
of migration defects, and there is nothing of value to lose. The `dev` dump in S3
remains as the record.

If you want the data anyway, restore the latest nightly dump per
[RESTORE.md](RESTORE.md) — and read the part about creating the three roles
first.

### DNS

`dev` currently owns `api`, `app` and `rt` in Terraform state. Two ways to hand
them over.

**Recommended, given no players — accept a few minutes of downtime:**

```bash
# Set manage_cloudflare = false in environments/dev, then:
gh workflow run terraform.yml -f environment=dev -f action=apply
# The three records are DESTROYED here. The site is down from this moment.

# Set manage_cloudflare = true and enable_external_health_check = true
# in environments/prod, then:
gh workflow run terraform.yml -f environment=prod -f action=apply
# The records are recreated pointing at prod's EIP.
```

**Zero-downtime, if you would rather rehearse the careful version:** remove the
records from `dev`'s state without destroying them (`terraform state rm
'module.cloudflare[0].cloudflare_dns_record.api'`, and the same for `app` and
`rt`), add matching `import` blocks to `prod`, then apply `prod` so it adopts
them and updates the content in place.

The second is what you would have to do with players on the system. Running it
now, while a mistake is free, is the only way to find out whether it works.

### Telegram

**Deploy first, register second.** The bot goes silent if this is reversed.

```bash
./scripts/register-telegram-webhook.sh prod
```

### Verify from outside

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://api.yisakmesifin.org/healthz
curl -s -o /dev/null -w '%{http_code}\n' https://app.yisakmesifin.org/
curl -s https://api.yisakmesifin.org/functions/v1/readyz
aws route53 get-health-check-status --health-check-id <id>
```

Then play a round end to end: `/start` in Telegram, open the Mini App, select a
card, watch numbers get called, claim.

---

## Phase 3 — Repoint the automation, THEN destroy `dev`

### This is the step that gets forgotten

Six workflows target `dev`. Three are **hard-wired** with no input at all, and
will simply break; three default to `dev` on their schedule and will silently
operate on an environment that no longer exists.

| Workflow | How it targets `dev` | Consequence if not changed |
|---|---|---|
| `db-backup.yml` | `\|\| 'dev'` on a nightly cron | **No backups of prod, every night, quietly** |
| `db-restore-drill.yml` | `\|\| 'dev'` on a monthly cron | The drill proves nothing |
| `verify.yml` | `\|\| 'dev'` on a weekly cron | Controls verified on a dead environment |
| `free-tier-runway.yml` | `fanosbingo-dev-*` hard-wired | The only alarm no budget can replace stops publishing |
| `ami-bump.yml` | `fanosbingo-dev-github-deploy` hard-wired | OS image pin drifts |
| `db-migrate.yml` | dev role hard-wired in the PR dry-run job | Migration dry runs fail on every PR |

The first row is the dangerous one. `db-backup.yml` failing loudly is survivable;
it succeeding against nothing is not. **Change these before destroying `dev`, not
after** — while there is still an environment to check the change against.

### Then destroy

`dev`'s RDS carries `deletion_protection = true` and `terraform.yml` guards the
destroy path twice. That is deliberate, and clearing it is its own change with
its own plan, which is the point.

```bash
# 1. deletion_protection = false in environments/dev/main.tf, then apply.
# 2. Only then:
gh workflow run terraform.yml -f environment=dev -f action=destroy -f confirm=dev
```

**Wait at least a week between Phase 2 and this.** The cheapest rollback in
existence is the old environment still running. Scaling `dev`'s ASG to 0 and
stopping its RDS costs roughly $5/month and keeps that option open. (Note RDS
restarts itself after 7 days stopped — take a final snapshot rather than relying
on it staying down.)

### What survives `dev` being destroyed

- **The S3 backups.** They live in the account root, not the environment. And
  since 2026-08-10 they carry Object Lock in COMPLIANCE mode for 30 days, so
  `dev/`'s dumps cannot be deleted by anyone — including by the destroy — for a
  month afterwards. That is an accidental but genuine rollback path.
- **CloudTrail**, for the same reason.
- **The final RDS snapshot** (`skip_final_snapshot = false`).

Gone: `dev`'s KMS keys (7-day window), its SSM parameter tree, its ECR
repositories (`force_delete = true`), its CloudWatch log groups.

### Update the documents

[HANDOVER.md](HANDOVER.md), [README.md](README.md), [AGENTS.md](AGENTS.md) and
[infra/README.md](infra/README.md) all assert that `dev` is the only environment
and serves the domain. Every one of those statements inverts here. `dev/main.tf`
says it directly: *"When prod exists and serves the domain, this becomes
disposable again — and that is the change that should revert the RDS block."*

---

## What `dev` becomes afterwards

The operating model, in the operator's own words: **`dev` is development and
staging, stood up to test a change, then destroyed — and only what was tested
there is applied to `prod`.**

That is the right model for this budget, and it is what `dev/main.tf`'s header
originally described before players arrived. It is also unusually well served by
this repository: `terraform destroy` and rebuild is the only real proof that the
code produces the system, most teams never run it, and their IaC quietly rots
into something that works only where it already exists. This model exercises it
every cycle.

At roughly $1/day while it is up, testing three days a month costs about $3
instead of $30.

Three things make it work, and one will take production down if it is missed.

### ⚠️ After cutover, applying `dev` with Cloudflare enabled hijacks production

`modules/cloudflare` writes `api.<domain_name>`, `app.<domain_name>` and
`rt.<domain_name>` — and `dev` passes the same apex, `yisakmesifin.org`. So a
freshly stood-up `dev` with `manage_cloudflare = true` **repoints production's
three hostnames at `dev`'s Elastic IP.** The apply succeeds, reports no errors,
and the site is down.

**`manage_cloudflare` must be `false` in `dev` from Phase 2 onward, permanently.**
It is set false as part of releasing the records to `prod`; the point here is
that it must never be turned back on.

Giving `dev` its own hostnames does not rescue this cheaply. `api.dev.<domain>`
is a second-level subdomain: Cloudflare's Universal SSL covers `*.<domain>` and
not `*.dev.<domain>`, so the edge certificate needs Advanced Certificate Manager
at $10/month — more than the environment it would serve — and the origin
certificate would need re-issuing to match.

**Consequence, accepted:** the Cloudflare layer is the one part of the stack
`dev` cannot test. That belongs written down rather than discovered. Verify `dev`
the same way [Phase 1](#verifying-prod-before-it-owns-the-domain) verifies `prod`
before cutover — a temporary security-group rule for your own address, removed
straight afterwards.

### Standing up is not instant, and that matters

RDS creation alone is ~10 minutes; add migrations, then five services each
needing two workflow runs the first time (deploy writes the SSM pointer,
Terraform then creates the service). **Budget 45–90 minutes from nothing to
usable.**

That tax is the real risk to this model. It is exactly high enough to make
"it is only a one-line change" tempting — and testing in `prod` is the thing the
model exists to prevent. If the rebuild is being skipped, the honest fix is to
shorten it, not to skip it.

### A fresh `dev` has an empty database

Nothing to test against, no bank to deposit to, and no admin to approve
anything — so every rebuild used to end in the same twenty minutes of `psql` by
hand, done slightly differently each time.

[`scripts/seed-dev.sh`](scripts/seed-dev.sh) is that step:

```bash
source scripts/db-tunnel.sh dev
./scripts/db-migrate.sh
./scripts/seed-dev.sh                    # add --admin <telegram-id> for a real account
```

It seeds `game_url` and `telegram_bot_username` correctly for the environment
(the exact pair found stale on the live database), two obviously-fake deposit
destinations, three payout banks, and three players covering the states the
money paths branch on — balance only, `won_balance` (the only state a withdrawal
is payable from), and admin.

It is idempotent, and it **refuses to run against production** — checked against
`DB_HOST`, which is where you actually are, rather than against an argument,
which is what you meant. There is no `--force`.

### What `dev` can and cannot prove

| Tested in `dev` | Not tested in `dev` |
|---|---|
| Migrations, and that they are idempotent | Cloudflare rules, DNS, edge TLS |
| Service code, IAM, task wiring | The rate-limit rule (which does not enforce anyway) |
| Terraform itself, from nothing | Anything about scale — same size, no traffic |
| The stand-up runbook | Certificate renewal |

The right response to the second column is not to widen `dev`. It is to know
that those things are only ever verified against `prod`, and to verify them
deliberately there — which is what `verify.yml` is for.

---

## After the cutover, and before players

The reason to do this now is the window it opens. On `prod`, with no money in it,
run the things that become impossible later:

1. **Load test to failure.** `stress-test/k6-spike-test.js` targets 400
   concurrent and has never run. Install the real k6 binary — the `"k6":
   "^0.0.0"` entry in `package.json` is a placeholder package, not the tool.
   Find out what breaks first: the pool is `max: 5` on a `t4g.small` sharing 2 GB
   with four other containers.
2. **Terminate the instance and time the recovery.** EIP re-association happens
   in `user_data` and has never been observed. It is the failure
   `api-unreachable` exists to catch.
3. **Restore a backup over the live database.** The only test of
   [RESTORE.md](RESTORE.md) that means anything.
4. **Remove the blanket table grant** (`db/20-post/001_rds_deltas.sql:121`).
   Its regression surface is the whole schema — which is a frightening sentence
   with players live and an ordinary afternoon today.
5. **`terraform destroy` and rebuild `prod` from scratch, once.** The only proof
   that the code produces the system.

Then raise `backup_retention_period` back to 7 — which needs the paid plan — and
close the pre-launch list in
[HANDOVER.md](HANDOVER.md): HSTS and CSP, the Cloudflare rate-limit rule that
applies cleanly and does not enforce, typecheck and lint as CI gates, the two
stale `settings` rows, and the Amharic money labels.
