# Restoring the database

> Part of the handover set: **[HANDOVER.md](HANDOVER.md)** ·
> [README.md](README.md) · [AGENTS.md](AGENTS.md) ·
> [infra/README.md](infra/README.md)
>
> The one thing on this page that is easiest to get wrong, and worst to get
> wrong: **`--no-privileges` does not skip RLS policies.** Restore without
> creating `anon`, `authenticated` and `service_role` first and all 32 policies
> are silently dropped — a database that looks restored and has lost its entire
> authorization layer.

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

**Yes, once, by hand — not automatically.** On 2026-08-07 the dump
`dev/2026-08-07T05-39-10Z.dump` was restored into PostgreSQL 16 and loaded:

```
telegram_users 4 · games 7 · players 6 · deposit_requests 3 · withdrawal_requests 0
```

with only the six expected `pg_cron` errors. The local copy was shredded
afterwards.

**Automating that is unfinished, and the reason is recorded so nobody repeats
it.** Eight CI runs could not get a throwaway PostgreSQL reachable on a GitHub
runner: as a `services:` container the published port carried no traffic —
`ss` showed `0.0.0.0:5433 LISTEN` while `pg_isready` got `no response` — and with
`docker run --network host` the port was not there at all. Two causes were found
and fixed along the way and neither was the last one: the postgres entrypoint
does not listen on TCP until `initdb` finishes, and `PGPORT` is a libpq *client*
variable that the server ignores.

None of that says anything about whether the backups work, which is exactly why
the check was removed rather than left warning every night — a check that always
warns is a check nobody reads.

**What still runs every night** is `pg_restore --list` against the archive
*before* it is uploaded. That catches truncation and corruption, which are the
failure modes an unattended dump actually has.

**So: repeat the manual restore above after any schema change.** It takes about
five minutes and it is currently the only thing that proves the dumps are worth
keeping.

---

## If a backup is missing

`<prefix>-backup-did-not-run` alarms when no dump has been recorded in 30 hours,
and treats **missing data as breaching** — so it fires if the workflow was
disabled or the schedule never ran, not only if a run failed. It reaches email
and Telegram.

The backup and its verification are deliberately separated: the dump is uploaded
and the heartbeat published *before* anything else is attempted, so a problem in
a checker can never cost you a recovery point.
