/**
 * PostgreSQL.
 *
 * This is the single most important resource in the stack: it holds player
 * balances. Everything else can be rebuilt from git in under an hour.
 *
 * Three parameter-group settings are load-bearing and easy to get wrong:
 *
 *   rds.logical_replication = 1
 *       Sets wal_level=logical, which the self-hosted Realtime container needs
 *       to consume a replication slot. Without it Realtime starts, connects,
 *       and silently never delivers a row change.
 *
 *   shared_preload_libraries = pg_cron
 *       Needed for the housekeeping jobs. NOTE: pg_cron on RDS has ONE-MINUTE
 *       granularity. Supabase's `cron.schedule_in_database('...', '4 seconds',
 *       ...)` six-field syntax is a fork extension and will NOT schedule here.
 *       That is why the game loop moved to the ticker container. Do not try to
 *       reinstate the 4-second cron job — it fails silently, which is the worst
 *       possible failure mode for a game heartbeat.
 *
 *   max_slot_wal_keep_size = 2048 (MB)
 *       If the Realtime container dies, its replication slot stops advancing
 *       and Postgres retains WAL forever waiting for it. Without this cap the
 *       disk fills and the database stops accepting writes — turning a
 *       recoverable container crash into a full outage. With it, the slot is
 *       dropped instead and Realtime resyncs on reconnect.
 *
 * Both `rds.logical_replication` and `shared_preload_libraries` are static
 * parameters: they only take effect after a reboot. Terraform will not reboot
 * the instance for you on a parameter-group change.
 */

resource "aws_db_subnet_group" "this" {
  name = "${var.name_prefix}-db"
  # ASCII only. The RDS API rejects non-printable characters in this field, and
  # counts anything outside ASCII as non-printable: an em-dash here fails the
  # apply with "DBSubnetGroupDescription must not contain non-printable control
  # characters". Keep every AWS-bound description plain ASCII.
  description = "Isolated subnets: no route to the internet in either direction"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db-subnets" })
}

resource "aws_db_parameter_group" "this" {
  name        = "${var.name_prefix}-pg16"
  family      = "postgres16"
  description = "Fanos Bingo: logical replication for Realtime, pg_cron for housekeeping"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot" # static parameter
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_cron,pg_stat_statements"
    apply_method = "pending-reboot" # static parameter
  }

  parameter {
    name         = "cron.database_name"
    value        = var.database_name
    apply_method = "pending-reboot"
  }

  # Cap WAL retained for an inactive replication slot. See the header comment —
  # this is what stops a dead Realtime container from filling the disk.
  parameter {
    name         = "max_slot_wal_keep_size"
    value        = tostring(var.max_slot_wal_keep_mb)
    apply_method = "immediate"
  }

  # Log slow queries. At 1s this is quiet in normal operation but catches the
  # lock contention that shows up under a join spike.
  parameter {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Where the exported logs land
#
# RDS creates /aws/rds/instance/<identifier>/<type> ITSELF the first time it has
# something to write there, and the group it creates has NO RETENTION and no
# customer key. That is not a default anybody chose -- it is what you get by
# saying nothing.
#
# Found by listing the account rather than reading the code: /ecs/fanosbingo-dev
# was 7 days and /aws/cloudtrail/fanosbingo was 14, while
# /aws/rds/instance/fanosbingo-dev-pg/postgresql had `retentionInDays: None`.
# Never expires, and log_min_duration_statement = 1000 above means it grows
# every time the database is slow. It is also the one log group holding query
# text from the database that holds player balances, and it was the only one not
# encrypted with this environment's CMK.
#
# Declaring the groups here takes ownership: retention and encryption become
# properties of the environment rather than of whichever service happened to
# create the group first.
#
# ORDER MATTERS. These must exist before the instance starts exporting, or RDS
# wins the race and creates them unmanaged -- hence the depends_on below. On an
# environment where RDS already made them, adopt them with an import block in
# the environment root; see infra/environments/dev/main.tf.
resource "aws_cloudwatch_log_group" "exports" {
  for_each = toset(var.enabled_cloudwatch_logs_exports)

  name              = "/aws/rds/instance/${var.name_prefix}-pg/${each.value}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-pg-${each.value}-logs" })
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-pg"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.database_name
  username = var.master_username

  # RDS generates and rotates the master password in Secrets Manager, so it
  # never passes through Terraform state. Costs ~$0.40/mo, which is the right
  # trade for the credential that owns every player balance.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  # Application roles authenticate with IAM tokens rather than passwords where
  # possible, so there is no long-lived app credential to leak.
  iam_database_authentication_enabled = true

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage # storage autoscaling ceiling
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false
  multi_az               = var.multi_az

  parameter_group_name = aws_db_parameter_group.this.name

  # 7 days of point-in-time recovery. RPO is ~5 minutes.
  backup_retention_period = var.backup_retention_period
  backup_window           = var.backup_window
  maintenance_window      = var.maintenance_window
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade = true
  apply_immediately          = var.apply_immediately

  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-pg-final-${var.final_snapshot_suffix}"

  performance_insights_enabled = var.performance_insights_enabled

  # Surface Postgres logs in CloudWatch so slow queries and errors are visible
  # without shelling into anything.
  enabled_cloudwatch_logs_exports = var.enabled_cloudwatch_logs_exports

  tags = merge(var.tags, { Name = "${var.name_prefix}-pg" })

  # So the managed groups above win the race against RDS creating its own
  # unretained ones. See the comment on aws_cloudwatch_log_group.exports.
  depends_on = [aws_cloudwatch_log_group.exports]
}

# ---------------------------------------------------------------------------
# The promise, made mechanical
#
# environments/prod/main.tf spent 34 lines explaining that backup_retention_period
# is 1 because the free plan refuses more, that this is acceptable only because
# there is no real money yet, and that "THE TRIGGER IS THE FIRST REAL DEPOSIT,
# not a date and not a release". That reasoning is correct and it was enforced by
# a comment, alongside two other settings gated on the same unenforced promise.
#
# A comment cannot fail an apply. This can.
#
# WHAT IT DOES NOT DO, said plainly so nobody mistakes its scope: it cannot know
# whether a real deposit has happened. Terraform cannot see the deposit_requests
# table, and a flag somebody must set is still a flag somebody must set. What it
# removes is the PARTIAL state -- declaring the environment live while two of the
# four durability settings still say otherwise, which is the version of this
# mistake that looks fine in a diff.
#
# Written as a terraform_data precondition rather than a validation block on the
# variable, because the condition spans several variables. Same shape as
# terraform_data.cloudflare_range_sanity in modules/security_groups and
# terraform_data.cloudflare_zone_required in environments/prod.
# ---------------------------------------------------------------------------
resource "terraform_data" "real_money_durability" {
  lifecycle {
    precondition {
      condition = !var.real_money || var.backup_retention_period >= 7
      error_message = join("", [
        "real_money is true but backup_retention_period is ${var.backup_retention_period}. ",
        "Point-in-time recovery of ${var.backup_retention_period} day(s) means a problem discovered on Friday about Monday is unrecoverable. ",
        "This needs the PAID account plan -- the free plan refuses any value above 1 with FreeTierRestrictionError, measured against the live instance. ",
        "The same upgrade lifts Multi-AZ and removes the credit-exhaustion deadline. See CUTOVER.md.",
      ])
    }

    # MULTI-AZ IS NOT FORCED, AND THAT IS DELIBERATE.
    #
    # An earlier version of this block required it outright. That was the wrong
    # control for this project: Multi-AZ roughly DOUBLES the RDS instance cost,
    # and a precondition that demands real spending is one an operator on a
    # budget routes around by never setting real_money at all -- which loses the
    # three cheap guarantees above as well. A gate people disable is worse than
    # no gate.
    #
    # So the cost decision stays with whoever pays the bill, and what is enforced
    # is that it was DECIDED rather than defaulted into. Setting
    # accept_single_az_risk records the choice in the diff, where a reviewer sees
    # it, instead of leaving multi_az = false looking like nobody considered it.
    #
    # What the risk actually is, so the acknowledgement means something: an AZ
    # failure takes the ledger offline until somebody restores it by hand, and
    # RDS is the one resource here that cannot be rebuilt from git. The nightly
    # pg_dump to S3 under Object Lock is what bounds the loss; it does not bound
    # the downtime.
    precondition {
      condition = !var.real_money || var.multi_az || var.accept_single_az_risk
      error_message = join("", [
        "real_money is true and multi_az is false. ",
        "An availability-zone failure would take the balance ledger offline until somebody restores it by hand, and RDS is the one resource in this stack that cannot be rebuilt from git. ",
        "Multi-AZ roughly doubles the instance cost and needs the paid plan. ",
        "If that is not affordable yet, that is a legitimate call -- set accept_single_az_risk = true to record it deliberately, and keep the nightly S3 dumps working, because they become the ONLY recovery path.",
      ])
    }

    precondition {
      condition     = !var.real_money || var.deletion_protection
      error_message = "real_money is true but deletion_protection is false. Nothing should be able to destroy the balance ledger with a plan that says 1 to destroy."
    }

    precondition {
      condition     = !var.real_money || !var.skip_final_snapshot
      error_message = "real_money is true but skip_final_snapshot is true. A deliberate destroy would leave no copy of the balances at all."
    }
  }
}
