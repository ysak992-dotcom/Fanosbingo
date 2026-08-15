# Restoring the database

> Part of the handover set: **[HANDOVER.md](HANDOVER.md)** ·
> [README.md](README.md) · [AGENTS.md](AGENTS.md) ·
> [infra/README.md](infra/README.md)
>
> The one thing on this page that is easiest to get wrong, and worst to get
> wrong: **`--no-privileges` does not skip RLS policies.** Restore without
> creating `anon`, `authenticated` and `service_role` first and all 45 policies
> are silently dropped — a database that looks restored and has lost its entire
> authorization layer.

> **Changed 2026-08-15 (#151).** The nightly schedule is now a MATRIX over both
> environments. `dev` had never been backed up by the cron — the workflow
> defaulted to `prod` — so the environment that then held the only real player
> balances had no nightly dump at all. It does now, and it runs unattended.
>
> **`prod`'s nightly backup still waits for a human**, because the `prod` GitHub
> Environment has required reviewers. On 2026-08-15 it sat in `waiting` from
> 04:21 until approved by hand. Until that requirement changes, a night nobody
> approves is a night with no prod dump — and `backup-did-not-run` is what tells
> you, so do not mute it.
>
> **That alarm was also dead until 2026-08-15.** Its
> `period × evaluation_periods` exceeded CloudWatch's 86400 ceiling, so it never
> evaluated: dev went 78 hours with no backup and the alarm stayed OK. Both are
> now 86400×1, and the fix was proven with a throwaway no-action alarm rather
> than assumed — see AGENTS.md §0.

Two recovery paths exist and they answer different questions. Reach for the
right one first — using the wrong one costs time you will not have.

| You need to undo | Use | Granularity | How far back |
|---|---|---|---|
| something that happened **today** | RDS point-in-time recovery | any second | **24 hours** |
| something you noticed **days later** | a nightly dump from S3 | nightly | **30 days** |

The 24-hour limit is not a choice. Raising `backup_retention_period` above 1 is
refused on this account:

```
FreeTierRestrictionError: The specified backup retention period exceeds the
maximum available to free tier customers.
```

Retried with `2` and refused identically — the ceiling is exactly 1. That is why
the nightly dumps exist at all.

---

## Path 1 — point-in-time recovery (last 24 hours)

Use `.github/workflows/db-restore-drill.yml` as the reference. It restores a
snapshot into a throwaway instance named `*-restore-drill` and validates it, and
it runs monthly, so it is the path most likely to actually work when you need it.

**Never restore over the live instance.** Restore beside it, verify, then move
traffic. `deletion_protection` is on precisely so a panicking operator cannot
skip that step.

## Path 2 — a nightly dump (last 30 days)

```bash
aws s3 ls s3://fanosbingo-backups-$(aws sts get-caller-identity --query Account --output text)/dev/
aws s3 cp s3://fanosbingo-backups-<account>/dev/<timestamp>.dump ./restore.dump
```

The deploy role deliberately has **no `s3:GetObject`** on this bucket — a nightly
job has no reason to read the ledger back. Downloading is a human act with human
credentials, and that is the intent, not an obstacle to route around.

### Restoring it

The dumps are PostgreSQL **custom format** (`pg_dump -Fc`), so `pg_restore` can
load them selectively. Recovering one wrongly-updated table should not mean
replaying the whole ledger:

```bash
pg_restore --list restore.dump                 # what is in it
pg_restore --dbname="$DATABASE_URL" --table=deposit_requests restore.dump
```

A full restore into a fresh database:

```bash
psql "$DATABASE_URL" -c "CREATE ROLE anon NOLOGIN;" \
                     -c "CREATE ROLE authenticated NOLOGIN;" \
                     -c "CREATE ROLE service_role NOLOGIN;"
pg_restore --dbname="$DATABASE_URL" --no-owner --no-privileges restore.dump
```

**Create those three roles first.** `--no-privileges` skips `GRANT`s but does
**not** skip RLS policies, and every policy in this schema names one of them.
Without the roles the restore emits 32 `role does not exist` errors and silently
drops every policy — leaving a database that looks restored and has lost its
entire authorization layer. This is the single easiest way to turn a good backup
into a bad recovery.

### Errors you should expect, and what they mean

**Which six depends on where you restore TO, and that was not said here.**
Restored over the live RDS instance on 2026-08-13 -- the first time this was
done against a running environment rather than a throwaway -- and the pg_cron
errors below did not appear at all. pg_cron IS available on RDS, so restoring
RDS-to-RDS produces none of them.

What appeared instead was one error, and it came from the CLIENT:

```
ERROR: unrecognized configuration parameter "transaction_timeout"
Command was: SET transaction_timeout = 0;
```

`transaction_timeout` is a PostgreSQL 17 setting. The restore was run with an
Ubuntu-default `pg_restore` 18 against a PostgreSQL 16 server, so the client
emitted a setting the server does not know. Harmless -- it is the first line of
the archive, not data -- but it is exactly why `db-backup.yml` pins
`PG_MAJOR: '16'`. **Match the client to the server** and it does not occur.

So: restoring INTO plain PostgreSQL, expect the six pg_cron errors below.
Restoring INTO RDS, expect none of them. In both cases anything else is real.

Six errors are normal outside RDS. `pg_cron` is an RDS-provided extension, so on
plain PostgreSQL you will see:

```
extension "pg_cron" is not available        extension "pg_cron" does not exist
schema "cron" does not exist            (x2)  relation "cron.jobid_seq" does not exist
                                              relation "cron.runid_seq" does not exist
```

Anything **else** is a real problem. Note that
`pg_restore: warning: errors ignored on restore: 6` is the summary line, not a
seventh error.

---

## Has this been proven?

**Yes, over a live database, on 2026-08-13.** The 2026-08-11 dev dump was
restored over the running dev environment with services connected:

```
508 KB archive, 394 TOC entries
190 seconds
1 error, and it was the client's (see above)
data rolled back: games 21 -> 14, players 20 -> 12, deposits 6 -> 5
after: healthz 200, readyz 200, app 200, rt 200, lobby RPC 200
```

That is the claim that matters -- not that the archive parses, but that the
system works afterwards. The whole stack answered normally, and nothing needed
restarting.

Before that it had only been restored by hand into a throwaway PostgreSQL 16,
which proves the archive is readable and says nothing about whether a real
recovery leaves you with a working system.

## If a backup is missing

`<prefix>-backup-did-not-run` alarms when no dump has been recorded in 30 hours,
and treats **missing data as breaching** — so it fires if the workflow was
disabled or the schedule never ran, not only if a run failed. It reaches email
and Telegram.

The backup and its verification are deliberately separated: the dump is uploaded
and the heartbeat published *before* anything else is attempted, so a problem in
a checker can never cost you a recovery point.
