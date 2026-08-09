# Fanos Bingo — Infrastructure

> **Start with [../HANDOVER.md](../HANDOVER.md).** Three things about this
> infrastructure are not what they look like:
>
> - **`dev` is production.** It carries prod's RDS protections and its destroy
>   path is guarded twice. Prod has never been applied.
> - **RDS PITR is capped at 1 day by the account plan.** Raising
>   `backup_retention_period` fails the apply, not just the setting.
> - **The spend budgets cannot see the FREE-plan credit burn.** Spend is zero;
>   credits absorb it. `free-tier-runway.yml` is what actually watches the cliff.
>
> An infrastructure apply is also a **deploy** — it rolls `caddy` and
> `functions` onto whatever image SSM names, and briefly drops the site.

Terraform for the AWS build. Target: **~$30/month** at ~200 users, structured so
growth is a configuration change rather than a rewrite.

**State, ✅ verified 2026-08-09:** `dev` and `account` are applied and healthy —
five services `ACTIVE 1/1`, **17 alarms** in the account, CloudTrail logging, a
dev plan reporting no changes, and the Mini App serving at `app.<domain>`.
**`prod` is written and plans cleanly but has never been applied**, and `dev` is
therefore the live environment.

### Three hostnames, and what each one is

| Host | Served by | Notes |
|---|---|---|
| `app.<domain>` | Caddy, static files | The Mini App. **This is the URL BotFather needs.** Built into the Caddy image |
| `api.<domain>` | Caddy → PostgREST : 3000, functions : 8080 | `/rest/v1/*` and `/functions/v1/*` |
| `rt.<domain>` | Caddy → Realtime : 4000 | `/realtime/v1/*`, rewritten to `/socket/*` |

All three must be **proxied** in Cloudflare. The origin admits Cloudflare ranges
only, so a grey-cloud record black-holes with no error anywhere.

> **`ALLOWED_ORIGIN` on the functions service must equal `https://app.<domain>`
> exactly.** The app and the API are on different hosts, so every call the Mini
> App makes is cross-origin. A mismatch fails in the quietest way available: the
> preflight answers `204`, the access log fills with what look like successful
> requests, and the browser never sends the POST. `verify.yml` asserts this
> weekly for exactly that reason.

Engineering context and the reasoning behind these decisions live in
[../AGENTS.md](../AGENTS.md).

## Layout

```
infra/
├── environments/
│   ├── account/ # CloudTrail + account guardrails. SINGLETON, applied on demand.
│   ├── dev/     # BSC testnet. NOT always-on — apply, test, destroy.
│   └── prod/    # BSC mainnet. Written, plans cleanly, NEVER APPLIED.
│       └── ami.tf          one pinned AMI id, bumped by pull request
└── modules/
    ├── vpc/              VPC, 2 public + 2 isolated subnets, IGW, routes
    ├── security_groups/  sg-app (Cloudflare-locked), sg-rds
    ├── kms/              encryption CMK + secp256k1 wallet signing key
    ├── ssm/              config, secrets, and image pointers
    ├── iam/              GitHub OIDC, EC2 instance role, ECS task roles
    ├── rds/              PostgreSQL 16 + parameter group
    ├── ecr/              image repositories
    ├── ecs/              cluster, EC2 capacity provider, ASG, launch template
    ├── ecs_service/      one task definition + service
    ├── app_stack/        ALL FIVE services, called by dev AND prod
    ├── cloudtrail/       the trail, and the alarms that justify it
    ├── cloudflare/       DNS + zone settings — the origin lock's other half
    ├── s3_cloudfront/    SPA hosting (Phase 5) — still empty
    └── monitoring/       Budgets, SNS, alarms incl. the game loop
```

**Three roots, not two.** `account` holds resources that are account-wide
singletons: one CloudTrail (a second would bill for duplicate management
events), the S3 account public-access block, EBS default encryption, the IAM
password policy and Access Analyzer. It is applied on its own and is never
targeted by a merge.

**`app_stack` is why dev and prod cannot diverge.** The five service definitions
used to live inline in `dev/main.tf` and were simply absent from prod — applying
prod would have produced a VPC, a database and an idle container instance with
no application on it.

## Design decisions that drive the cost

| Decision | Saves | Trade |
|---|---|---|
| ECS on **EC2** capacity provider, not Fargate | ~$53/mo | Same task definitions. Stage 3 swaps the capacity provider to `FARGATE`. |
| **No ALB** — Cloudflare proxies to the Elastic IP | ~$17/mo | Requires the Cloudflare origin lock (below) to stay correct. |
| **No AWS WAF** — Cloudflare free plan | ~$13/mo | Cloudflare's managed ruleset instead. |
| **No NAT Gateway, no VPC endpoints** | ~$61/mo | Instance in a public subnet with locked ingress. |
| **SSM Parameter Store**, not Secrets Manager | ~$2/mo | No managed rotation, which none of these values use. |

Single instance, single AZ. An instance failure is a 3–5 minute outage while the
ASG replaces it; a database failure is a ~25 minute PITR restore. That is the
deliberate trade for the budget. Stage 2 (`instance_count = 2`, `multi_az = true`)
buys it back for ~$30 more.

## The Cloudflare origin lock

`sg-app` admits port 443 **only** from Cloudflare's published IPv4 ranges, fetched
at plan time from `https://www.cloudflare.com/ips-v4`. This is what makes a
public-subnet instance safe — without it, anyone could bypass Cloudflare's WAF
and rate limiting by hitting the Elastic IP directly.

Two consequences:

- `api.<domain>` and `rt.<domain>` **must be proxied** (orange cloud). DNS-only
  records will be black-holed by the security group.
- A `terraform plan` needs network access to that endpoint. There is a
  precondition that fails the plan if the fetch returns fewer than 10 or more
  than 40 ranges, so a bad response cannot silently produce a broken rule set.

## How changes reach AWS

Through a pull request, and only through a pull request.

```
PR opened   ──▶  fmt · validate · trivy · plan ──▶ plan posted as a PR comment
PR merged   ──▶  apply to prod  (gated TWICE — see below)
Manual      ──▶  plan / apply / destroy any environment (workflow_dispatch)
```

Authentication is OIDC — there is no AWS access key anywhere in this repository.
Dev is deliberately not applied on merge.

> **`dev` is currently the live environment.** Prod has never been applied — the
> state bucket holds `account/` and `dev/` and nothing else, and
> `https://api.<domain>` is served by `fanosbingo-dev`. Until cutover, dev holds
> real player balances, and it carries prod's RDS protections — deletion
> protection and a required final snapshot — for that reason.
>
> **PITR is capped at 1 day by the account plan**, not by choice:
> `FreeTierRestrictionError` refuses any higher value, including 2. The real RPO
> on player money is 24 hours until the account moves off the Free plan. See the
> comment on the `rds` module call in `environments/dev/main.tf`.
>
> This matters most at `destroy`. That job used to refuse `prod` and `account`
> and wave `dev` through, which was one dropdown selection away from ending the
> live game. It now requires the environment name to be typed, and refuses any
> environment whose database has deletion protection on — a flag that follows
> where the money actually is, rather than which name somebody chose.

### Two roles, and the split is load-bearing

| Context | Role | Scope |
|---|---|---|
| `plan` on a pull request | `fanosbingo-terraform-planner` | ReadOnlyAccess + state lock; decrypts **dev** only, by resource tag |
| `apply` / `destroy` | `fanosbingo-terraform-executor` | AdministratorAccess, trusted only from `main` and the environments |
| deploy · secrets · migrate · drill | `fanosbingo-<env>-github-deploy` | ECR, ECS, this environment's SSM tree, the tunnel, `*-restore-drill` only |

A pull request runs workflow code **taken from the PR branch**. Before the
split, every workflow used the admin executor, so a modified workflow file in a
PR was an admin credential.

Two details that are easy to undo by accident:

- **The `plan` job declares no `environment:`.** A job that declares one gets
  `environment:<name>` as its OIDC subject — the environment context REPLACES the
  event context — so a PR plan would present `environment:dev` and never
  `pull_request`, and the planner role would refuse it.
- **`dev` carries a deployment branch policy limiting it to `main`.** Without it,
  a modified workflow could declare `environment: dev` and reach the admin
  executor anyway.

## One-time bootstrap

Two commands, and the first is unavoidable: GitHub Actions authenticates via an
OIDC role, but something already authenticated has to create that role.

```bash
./scripts/bootstrap-aws.sh      # state bucket, OIDC provider, BOTH roles
./scripts/bootstrap-github.sh   # variables, environments, prod's reviewers
```

Both are **idempotent** and re-running them is how you repair drift.
`bootstrap-aws.sh` writes `.bootstrap-output.json`, which the second reads, so
nothing is copied by hand between them.

`bootstrap-github.sh` **verifies** what it configured rather than assuming it
worked. That matters: a GitHub Environment that does not exist is created
implicitly and **without protection rules** the first time a workflow references
it — so `environment: prod` is not a gate until somebody has created `prod` and
ticked "required reviewers". A gate that depends on a human having clicked
something is not a gate.

Idempotent — re-running it repairs drift rather than failing. It creates the
state bucket (versioned, encrypted, private, with a 90-day lifecycle on old
versions), the GitHub OIDC provider, and the `terraform-executor` role. It then
prints the three GitHub variables to set.

Two roles exist deliberately, with different privilege levels:

| Role | Created by | Used by | Can do |
|---|---|---|---|
| `terraform-executor` | bootstrap | infra workflows | manage infrastructure |
| `github-deploy` | Terraform | app workflows | push ECR, roll ECS, sync S3 |

An application deploy must never be able to delete the database. The executor
role is broad, but it carries deny guardrails preventing it from widening its own
trust policy or deleting the state bucket — the real control is its *trust*
policy, which names one repository and specific branches and environments.

### GitHub configuration

`scripts/bootstrap-github.sh` sets all of this. The table is here so you can
check it, not so you can type it.

| Variable | Value |
|---|---|
| `AWS_ACCOUNT_ID` | used to derive the per-environment deploy role ARN |
| `AWS_ROLE_ARN` | the **executor** (admin) |
| `AWS_PLANNER_ROLE_ARN` | the **planner** (read-only, pull requests) |
| `AWS_REGION` | `us-east-1` |
| `TF_STATE_BUCKET` | printed by the bootstrap script |
| `DOMAIN_NAME` | `yisakmesifin.org` |
| `ALERT_EMAIL` | where alarms go |
| `CLOUDFLARE_ZONE_ID` | optional; enables `modules/cloudflare` |
| `PROD_APPLY_ENABLED` | **leave unset.** Setting it to `true` is the second prod gate |
| `TELEGRAM_BOT_USERNAME` | e.g. `BingoNovaaBot`, no `@`. Renders the Login Widget so the admin panel opens in a **browser**. Needs BotFather `/setdomain` pointed at `app.<domain>`, or Telegram refuses to render it. Unset = no button; the Mini App is unaffected |
| `REOWN_PROJECT_ID` | optional; only read when the crypto path is enabled |

The SPA build also reads `VITE_CRYPTO_ENABLED` from the environment. It is
**unset**, so crypto is off: every wallet surface is gated and its chunk is never
fetched. Turning it on is a coupled pair with deleting `db/20-post/010` — see
`src/lib/features.ts`.

Secrets, consumed by the *Sync secrets to SSM* workflow:

`TELEGRAM_BOT_TOKEN` · `TELEGRAM_WEBHOOK_SECRET` · `APP_JWT_SECRET` ·
`APP_ADMIN_BOOTSTRAP_KEY` · `DB_POSTGREST_PASSWORD` · `DB_APP_PASSWORD` ·
`REALTIME_SECRET_KEY_BASE` · `REALTIME_DB_ENC_KEY` ·
`REALTIME_METRICS_JWT_SECRET` · `TLS_ORIGIN_CERT` · `TLS_ORIGIN_KEY` ·
`CLOUDFLARE_API_TOKEN` (optional)

Environments: `account`, `dev`, `prod`.

- `prod` and `account` carry **required reviewers**
- `dev` carries a **deployment branch policy limited to `main`** — not a
  reviewer, because routine dev applies should not need approval, but a PR branch
  must not be able to declare `environment: dev` and reach the admin executor

Prod apply needs **both** `PROD_APPLY_ENABLED == "true"` and the environment's
reviewers. Two gates, because a missing environment is created implicitly and
without protection rules, so the environment alone would be no gate at all.

## Running it locally

Rarely needed, but for a quick plan:

```bash
cd infra/environments/dev
echo 'bucket = "fanosbingo-tfstate-<account-id>"' > backend.hcl   # gitignored
cp terraform.tfvars.example terraform.tfvars                      # gitignored
terraform init -backend-config=backend.hcl
terraform plan
```

## After an apply

`scripts/post-apply.sh` runs automatically at the end of the apply job. It is
idempotent, so it is a no-op on a steady-state apply. It handles:

- **Rebooting RDS when static parameters are pending.** `rds.logical_replication`
  and `shared_preload_libraries` do not take effect until the instance restarts.
  This matters more than it sounds: without `wal_level=logical` the Realtime
  container starts cleanly, connects cleanly, and then silently delivers nothing.
  There is no error to chase.
- **Publishing the hot-wallet address**, derived from the KMS public key and
  written to `/<prefix>/bsc/hot_wallet_address`. The private half never leaves
  KMS, so unlike the wallet this replaces, there is nothing that *could* be
  committed.
- **Reporting what still needs a human.**

### What is still genuinely manual

| Step | Why it cannot be automated |
|---|---|
| Confirming the SNS subscription email | AWS requires the recipient to click the emailed link. Until someone does, **the alarms notify nobody** — `verify-detections.sh` fails on zero confirmed subscribers precisely so this cannot be forgotten quietly. |
| Creating the Cloudflare API token | A credential. Needs `Zone:Read`, `DNS:Edit`, `Zone Settings:Edit`, `Zone WAF:Edit` and **`Bot Management:Read`** — that last one is separate, not implied by Zone Settings, and without it Bot Fight Mode cannot be verified. |
| Setting the GitHub Secret *values* | The one thing not derivable. `bootstrap-github.sh` prints the list. |
| Funding the hot wallet | Moving money. Deliberately not automated. Testnet is a free faucet; mainnet is real BNB. |
| Deploying the contract | One command (`scripts/deploy-contract.mjs`), but it broadcasts a transaction and permanently sets the owner, so it is deliberately explicit. |

**No longer manual**, and worth knowing because the old instructions are wrong:

| Was | Now |
|---|---|
| Set `<SVC>_IMAGE` GitHub variables, then re-dispatch Terraform | Deploy writes the image pointer to `/<prefix>/images/<service>` and dispatches Terraform itself |
| Create GitHub Environments and tick "required reviewers" | `scripts/bootstrap-github.sh` creates them **and verifies** the rule is present |
| Set Cloudflare DNS and zone settings in the dashboard | `modules/cloudflare`, gated on `cloudflare_zone_id` |
| Watch for new ECS AMIs | `ami-bump.yml` opens a PR weekly |

## Cloudflare settings that are not optional

**Most of these are Terraform now** (`modules/cloudflare`), gated on
`cloudflare_zone_id` being set.

| Setting | Value | Managed by | Why |
|---|---|---|---|
| SSL mode | **Full (strict)** | Terraform | Anything less either loops or silently sends plaintext on the origin leg |
| `api.` / `rt.` records | **Proxied** | Terraform | Required by the origin lock — a grey-cloud record black-holes with no error |
| Minimum TLS | 1.2 | Terraform | |
| WebSockets | on | Terraform | Realtime cannot upgrade without it |
| Bot Fight Mode | **Off** | **script only** | No free-plan Terraform resource. Challenges non-browser clients — which is exactly what Telegram's webhook caller and a WebSocket upgrade look like. Telegram does not solve challenges: it retries, then DISABLES your webhook |
| Apex / `www` | DNS-only | manual | Points at CloudFront; proxying would double-CDN for no gain |

`scripts/verify-cloudflare.sh` asserts the lot against Cloudflare's API — not
against Terraform state, because a dashboard edit does not update state. It runs
weekly via `verify.yml`.

> **Exactly one root may own the zone.** dev and prod share a domain and therefore
> a zone, and two Terraform states managing one DNS record is a fight neither
> wins — each apply reverts the other, presenting as unexplained DNS flapping.
> `manage_cloudflare` is `true` in dev, `false` in prod. **At cutover, flip prod
> on and dev off, in that order.**

> **Records that already exist must be imported, not created.** Cloudflare permits
> several A records on one name, so a plain apply creates a *second* `api.` record
> beside the live one — no error, and Terraform then manages a record nobody
> resolves. Run `cloudflare-import.yml`, merge its PR, apply, then delete the
> generated `cloudflare-imports.tf`.

## Troubleshooting

### `Not authorized to perform sts:AssumeRoleWithWebIdentity`

Almost always the OIDC subject claim, not the permissions. GitHub emits subject
claims with an **immutable prefix containing numeric owner and repository IDs**:

```
repo:amana0921@221070182/Fanosbingo@1305204469:environment:dev
```

not the form the documentation shows:

```
repo:amana0921/Fanosbingo:environment:dev
```

A trust policy written the documented way therefore matches nothing, and STS
gives no hint which claim failed. Check what your repository actually emits:

```bash
gh api repos/OWNER/NAME/actions/oidc/customization/sub
```

`scripts/bootstrap-aws.sh` lists both forms and prints the emitted prefix when
it runs, so re-running it fixes this.

### `Not authorized` on a PR plan, but applies work

The `plan` job must declare **no** `environment:`. A job that declares one gets
`environment:<name>` as its OIDC subject — the environment context REPLACES the
event context — so the plan presents `environment:dev` and never `pull_request`,
and the read-only planner role refuses it. The error is the bare STS message and
says nothing about environments.

### A service exists in Terraform but ECS never creates it

Its image pointer is absent or still `none`. Terraform declines to create a
service whose image does not exist, because one that references a missing image
retries forever without explaining itself.

```bash
aws ssm get-parameters-by-path --path /fanosbingo-dev/images --query 'Parameters[].[Name,Value]' --output text
```

Terraform **reads** these and never writes them; the deploy workflow owns them.

### `KMSKeyNotAccessibleFault` restoring a snapshot

The key is fine. Restoring an *encrypted* snapshot makes RDS create a grant on
the CMK, and the caller needs `kms:CreateGrant`. The error names three possible
causes and the real one is a fourth.

### The Mini App loads but never logs in

CORS. Look for `204` responses on `/functions/v1/auth/telegram` in the Caddy
access log — that is the preflight, and a wall of them means the POST is never
being sent. `ALLOWED_ORIGIN` on the functions service must equal the app's origin
exactly, and the app is served from `app.<domain>`, not the apex.

The app degrades to the unverified identity from `initDataUnsafe` when auth
fails, so it shows a name and appears to work. That is the trap.

### A `/functions/v1/...` route returns 404

It is an inherited Deno function name that the rebuilt service never
implemented. The 25 upstream functions were deliberately not ported — see
`../AGENTS.md` §7. Decide whether it should be a route at all: most are plain
data access and belong in PostgREST under RLS.

### The restore drill reports a plausible RTO, then fails to connect

The restored instance landed in the VPC **default** security group, which admits
traffic only from itself. Pass `--vpc-security-group-ids` from the source. This
one is dangerous precisely because the timing looks right.

### Trivy fails the build

Findings are accepted in `.trivyignore`, each with a written justification.
Anything not listed there fails deliberately. Add an entry only when the finding
is a conscious architectural decision — and write down why, next to it.

Note that Trivy's config file (`.trivy.yaml`) has **no** per-ID ignore
mechanism; `.trivyignore` is the only one that works. Documenting suppressions
in config-file comments looks correct and does nothing.

### `must not contain non-printable control characters`

An AWS-bound `description` contains a non-ASCII character. RDS counts anything
outside ASCII as non-printable, so an em-dash fails the apply. Other services
(SSM, for one) accept it, which makes this inconsistent and easy to reintroduce.

**Rule: every string sent to AWS — descriptions, names, tags — stays plain
ASCII.** Terraform *variable* descriptions never leave your machine and can use
whatever punctuation you like. Find offenders with:

```bash
grep -rnP '^\s*(description|alarm_description)\s*=.*[^\x00-\x7F]' infra/modules --include=*.tf
```

### `Client.InvalidKMSKey.InvalidState` on instance launch

The ASG launches an instance, fails to attach its encrypted root volume,
terminates it, and retries forever. The message is misleading: the key is
enabled and healthy. **This is an authorisation failure, not a state failure.**

Auto Scaling needs explicit key-policy permission to use the CMK — the
`AllowAutoScalingUseOfKey` and `AllowAutoScalingToCreateGrants` statements in
`modules/kms`. Note that attaching an `aws_kms_key_policy` **replaces** the
default policy, so the usual "root has `kms:*`, therefore IAM delegation covers
it" reasoning does not hold for service-linked roles.

Diagnose with:

```bash
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name <asg> --max-records 3 \
  --query 'Activities[].StatusMessage' --output text
```

### `Volume of size NGB is smaller than snapshot`

The ECS-optimized AL2023 arm64 AMI ships a 30 GiB snapshot and EBS will not
restore it into a smaller volume. `root_volume_size` must be >= 30; there is a
validation block enforcing it.

### Realtime connects but delivers no row changes

`rds.logical_replication` did not take effect. It is a static parameter and
needs an instance reboot:

```bash
aws rds describe-db-instances --db-instance-identifier fanosbingo-prod-pg \
  --query 'DBInstances[0].DBParameterGroups[0].ParameterApplyStatus'
```

If that says `pending-reboot`, run `scripts/post-apply.sh <env>`. There is no
error message for this condition, which is what makes it costly.

### Instance is healthy but the site is unreachable

The Elastic IP was probably not re-associated on boot. Check the bootstrap log
on the instance:

```bash
aws ssm start-session --target <instance-id>
sudo cat /var/log/fanosbingo-bootstrap.log
```

The user-data script logs an explicit multi-line ERROR block on failure. The
usual cause is the instance role's `ec2:AssociateAddress` tag condition not
matching.

## Common operations

```bash
# Everything goes through workflows. These are the ones you will actually use.
gh workflow run terraform.yml -f environment=dev     -f action=plan
gh workflow run terraform.yml -f environment=dev     -f action=apply
gh workflow run terraform.yml -f environment=account -f action=apply   # rare
gh workflow run terraform.yml -f environment=dev     -f action=destroy # refuses prod and account

# Ship a service: build -> ECR -> SSM pointer -> roll (creates the service if new)
gh workflow run deploy-services.yml -f service=functions -f environment=dev

# Prove the security controls still work (also weekly)
gh workflow run verify.yml -f environment=dev

# Measure the RTO for real (also monthly)
gh workflow run db-restore-drill.yml -f environment=dev

# Shell into the instance — no SSH key, no open port, CloudTrail-logged
aws ssm start-session --target <instance-id>

# See what an apply would change, locally
terraform plan -out=tfplan && terraform show tfplan
```

**A plan's verdict is in the job log**, not only in the step summary: both
outcomes emit a `::notice::`. A green tick means terraform exited cleanly, not
that infrastructure matches configuration — only "No changes" means that.

`*.tfplan` files are gitignored: plan output can contain secret values in
cleartext.

## Notes

- `.terraform.lock.hcl` **is** committed, so your machine and CI resolve
  identical provider versions.
- `terraform.tfvars` is **not** committed; `terraform.tfvars.example` is.
- Dev uses `10.30.0.0/16`, prod uses `10.20.0.0/16` — non-overlapping, so they
  could be peered later.
- The GitHub OIDC provider is account-wide. Whichever environment you apply
  first sets `create_github_oidc_provider = true`; the other sets it false.

---

## Application state, as of 2026-07-31

The infrastructure documented above is unchanged. What runs on it has moved, and
two things in this file's assumptions are worth restating.

**A manual money path now exists that needs no smart contract.** Players deposit
by TeleBirr or CBE, an operator approves against their own bank statement, and
the balance is credited. So the undeployed contract no longer blocks players from
funding an account — it blocks only the on-chain deposit and withdrawal routes.
See AGENTS.md §0.

**`app_service` now carries the `BYPASSRLS` attribute.** It always needed it; it
never had it. `GRANT service_role TO app_service` makes it a member, and
membership does not confer role ATTRIBUTES — only privileges and policy matching.
Every server-side read appeared to work because the tables involved happened to
carry `TO service_role` policies. `bank_options` did not, and the deposit route
read zero rows from a table with data in it.

If you add a table that server-side code reads, this is now handled by the role
rather than by remembering a policy. `db/20-post/004` asserts the attribute.

**CI executes migrations now.** `db-migrate.yml`'s pull-request job runs
`--dry-run`, which prints filenames and executes nothing. The `migrations` job in
`test.yml` starts a `postgres:16` service and applies `db/20-post/003` onwards
against `db/test/fixture.sql`, **twice**, because these files are repeatable and
one that only works against a clean database is broken in a way a single pass
cannot see.

It does not cover `db/00-bootstrap` or the 104 inherited migrations: the bootstrap
asserts `wal_level=logical` and `pg_cron`, neither available in a stock image.
Closing that needs a custom image.

**The Cloudflare rate-limit rule is applied and does not enforce.** Measured:
160 requests from one IP to a covered path, zero blocked, and a deliberately
excluded path behaving identically. Treat it as absent until somebody reads the
dashboard's rate-limiting analytics. `/auth/telegram` has a per-player limiter in
the functions service underneath it.

**IMDS hop limit is 1.** Containers can no longer reach the instance metadata
service; task credentials come from the ECS agent at `169.254.170.2` and are
unaffected. Changing it again requires an explicit
`aws autoscaling start-instance-refresh` — Terraform will not trigger one,
because the ASG references `version = "$Latest"` and therefore shows no diff.

---

## Infrastructure state, as of 2026-08-02

Four defects were fixed here that had one property in common: **every signal said
healthy.** None errored, none failed a plan, and none would have been found by
reading the configuration. Recorded in full because the class matters more than
the instances.

### No per-environment alarm could ever deliver a notification

`modules/monitoring` encrypts its SNS topic with the environment CMK.
`modules/kms` admitted CloudWatch **Logs** and Auto Scaling to that key, and not
`cloudwatch.amazonaws.com` — so an alarm transitioning to ALARM could not produce
a data key to encrypt the message. The publish failed and the notification was
**dropped silently**: state correct, console showing ALARM, subscription
confirmed, metric publishing, nothing delivered.

That included `game-loop-stalled`, which this repository calls "THE alarm ... the
one that describes whether the game is running". It had never once reached a
human.

**The statement already existed on the audit key** in `environments/account`,
with a comment saying precisely what its absence costs. It was never applied to
`modules/kms`, so account-wide alarms delivered while every environment alarm did
not. When a lesson gets written down, grep for the other place it applies.

Found by firing an alarm deliberately and getting no email — after confirming the
subscription, the alarm state, and the metric datapoints. Each link looked
correct in isolation.

### `scripts/verify-alarms.sh` — run this before trusting an alarm

```bash
./scripts/verify-alarms.sh dev                  # report; changes nothing
./scripts/verify-alarms.sh account              # the account-wide detections
./scripts/verify-alarms.sh dev --fire <alarm>   # force ALARM -> OK, prove the inbox
```

It checks four links, and the fourth is the one that was missing when it first
shipped: confirmed subscribers, a topic whose CMK admits CloudWatch, non-empty
alarm actions, and — for **continuous** metrics only — live datapoints.

**An alarm at OK with no datapoints is not healthy, it is unarmed.** With
`treat_missing_data = "notBreaching"` it will sit there forever saying nothing.

`account` deliberately skips the datapoint assertion: `UnexpectedKmsSign` and
`RootAccountUsage` are **event-driven**, so no datapoints is the goal. Demanding
them would fail permanently and train everyone to ignore the script — the exact
failure it exists to prevent, turned on itself. `--fire` refuses the account
target for the same reason: those alarms mean "somebody used root", and firing
one writes a false positive into the record you would read back during an
incident.

Wired into `verify.yml`, so it runs weekly alongside the other checks.

### The budget alerts had never been able to fire

```hcl
values = ["user:Environment$${var.environment}"]     # WRONG
```

In HCL `$${` is the escape for a literal `${`, so the filter rendered as the
literal text and matched no resource. The budget reported $0 actual and $0
forecast permanently, and every notification below it was unreachable — in
exactly the situation they exist to catch, since exhausting credits on a
credit-based Free Tier plan **suspends resources**. Use
`format("user:Environment$%s", var.environment)`.

### The deploy role was wider than its comments claimed

- **`ssm:StartSession` on `instance/*` with no condition** is an interactive root
  shell on every instance in the account. Listing the port-forwarding document in
  `Resource` constrains nothing — a session naming no document uses the default
  `SSM-SessionManagerRunShell`, so only the instance ARN is evaluated. Combined
  with dev's `pull_request` trust, PR-branch code could reach a shell on the
  **prod** instance. Now conditioned on `ssm:resourceTag/Environment`.
- **`ecs:UpdateService` on `*`** let the dev role set a prod service's
  `desiredCount` to 0. Now scoped to the environment's cluster.
- **The RDS master secret** was matched by the account-wide `rds!db-*` prefix.
  Not exploitable — the CMK scoping caught it — but correct by accident. Now
  passed by exact ARN from the `rds` module.

### prod's trust policy was reachable without its reviewer gate

It admitted `ref:refs/heads/main` alongside `environment:prod`. A
`workflow_dispatch` from `main` emits that subject **whether or not the job
declares an environment**, so any workflow building the role ARN from an input
reached prod with no reviewer asked. Two did.

**The rule this establishes: any workflow that interpolates an environment into a
role ARN must declare that environment.** Audited across all ten; `db-migrate.yml`
is split into two jobs because the PR dry run must *not* declare one (dev's
deployment branch policy would refuse it) while the apply must.

### Alarm budget

`modules/monitoring` now defines **exactly ten alarms — the entire CloudWatch
free-tier allowance.** There is no headroom. An eleventh costs $0.10/mo, which is
trivial in isolation and worth knowing deliberately on a $32 budget whose point is
that nothing is billed by accident. If you need another: pay for it, retire one
that has never fired, or fold two signals into a metric-math alarm. Do not
quietly add an eleventh.

### Reading a plan on an ECS change

A task definition is **immutable**, so Terraform expresses every change to one as
destroy-and-create. "2 to add, 4 to change, 2 to destroy" on an infrastructure PR
is usually the same two resources being revised, not a service being deleted.

What *is* worth stopping for: a **service** replaced rather than updated in place,
or `aws_db_instance` / `aws_kms_key` appearing in a destroy list. And image-tag
churn nobody caused is the SSM pointer converging — fine, but it means **an
infrastructure apply is also a deploy** of whatever the pointer names.
