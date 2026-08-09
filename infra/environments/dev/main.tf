/**
 * Fanos Bingo — dev environment.
 *
 * THE HEADER BELOW USED TO SAY "stand it up, test, tear it down". Do not.
 *
 * This is the development and staging environment -- prod is planned and has
 * never been applied -- but it is the ONLY environment that exists, it is what
 * api.<domain> resolves to, and real birr has moved through it. Destroying it
 * destroys the only copy, which is why the RDS block below carries prod's
 * protections and why terraform.yml guards the destroy path twice.
 *
 * It is therefore always-on, and the ~$30/mo is the cost of the system running
 * rather than of somebody forgetting to tear it down.
 *
 * When prod exists and serves the domain, this becomes disposable again -- and
 * that is the change that should revert the RDS block, not a tidy-up beforehand.
 */

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Fallback image pins, used only where SSM has no pointer yet.
  #
  # These are the legacy TICKER_IMAGE/POSTGREST_IMAGE/... GitHub variables. They
  # exist so this environment keeps running across the switch to SSM-held image
  # pointers; once every service has deployed once, they can be deleted from the
  # repository settings and this map can go with them.
  #
  # An unset GitHub variable arrives as TF_VAR_x="" -- an EMPTY STRING, not null
  # -- so a bare `== null` check passes and Terraform goes on to register a task
  # definition with no image, failing with the distinctly unhelpful
  # "Container.image should not be null or empty". app_stack normalises empties,
  # so passing them straight through is safe.
  image_overrides = {
    ticker    = var.ticker_image
    postgrest = var.postgrest_image
    realtime  = var.realtime_image
    caddy     = var.caddy_image
  }

}

module "vpc" {
  source = "../../modules/vpc"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
}

module "security_groups" {
  source = "../../modules/security_groups"

  name_prefix = local.name_prefix
  vpc_id      = module.vpc.vpc_id
}

module "kms" {
  source = "../../modules/kms"

  name_prefix = local.name_prefix

  # Shorter window in dev so a torn-down environment does not leave keys
  # lingering for a month. Prod uses the full 30 days.
  deletion_window_in_days = 7
}

module "ssm" {
  source = "../../modules/ssm"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.main_key_arn
  domain_name = var.domain_name

  # Dev talks to BSC testnet. Nothing here should ever touch mainnet funds.
  bsc_chain_id      = 97
  bsc_rpc_primary   = "https://data-seed-prebsc-1-s1.binance.org:8545"
  bsc_rpc_secondary = "https://data-seed-prebsc-2-s1.binance.org:8545"
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = local.name_prefix

  # Dev repositories go away with the environment.
  force_delete     = true
  keep_last_images = 5
}

module "ecs" {
  source = "../../modules/ecs"

  name_prefix = local.name_prefix
  environment = var.environment

  # Index 0 only — a single instance in a single AZ at this tier.
  subnet_ids            = [module.vpc.public_subnet_ids[0]]
  security_group_id     = module.security_groups.app_security_group_id
  instance_profile_name = module.iam.ec2_instance_profile_name
  kms_key_arn           = module.kms.main_key_arn

  # Pinned in ami.tf, bumped by pull request. See that file.
  ami_id = local.ecs_ami_id
}

module "rds" {
  source = "../../modules/rds"

  name_prefix       = local.name_prefix
  subnet_ids        = module.vpc.isolated_subnet_ids
  security_group_id = module.security_groups.rds_security_group_id
  kms_key_arn       = module.kms.main_key_arn

  # DEV IS NOT DISPOSABLE. It is the ONLY database.
  #
  # These four used to read false / true / true / 1, under the comment "Dev is
  # disposable: allow destroy without ceremony. Prod inverts all three." That
  # was true when it was written and stopped being true the moment players
  # arrived, which nothing here noticed.
  #
  # What is actually the case, verified in the account rather than read from a
  # document: the state bucket holds `account/` and `dev/` and nothing else, and
  # https://api.<domain>/healthz is answered by fanosbingo-dev. Prod has never
  # been applied. So the environment carrying real player balances was the one
  # configured to be deleted without a final snapshot and to keep 24 hours of
  # point-in-time recovery.
  #
  # The prod root's protections are correct and protect nothing while prod does
  # not exist. Until the cutover happens, THIS root is the one that needs them,
  # so it now carries prod's values verbatim:
  #
  #   deletion_protection  the RDS API refuses a delete outright. Terraform
  #                        cannot destroy this instance, deliberately -- a
  #                        `terraform destroy` here now fails loudly instead of
  #                        succeeding quietly. Turning it off is its own change
  #                        with its own plan, which is the point.
  #   skip_final_snapshot  a delete that somehow gets past the above still
  #                        leaves a snapshot behind.
  #   apply_immediately    schema and parameter changes wait for the maintenance
  #                        window (Tue 02:30 UTC) rather than interrupting play.
  #
  # deletion_protection IS ALREADY TRUE ON THE LIVE INSTANCE. It was set out of
  # band on 2026-08-03 rather than waiting for an apply, because it is a
  # control-plane flag -- instant, no downtime, instantly reversible -- and it
  # was the one thing standing between a stray destroy and the balance ledger.
  # This declaration now matches reality rather than proposing it.
  deletion_protection = true
  skip_final_snapshot = false
  apply_immediately   = false

  # ONE DAY, AND IT IS NOT A CHOICE. THE ACCOUNT PLAN FORBIDS MORE.
  #
  # This read `= 7` for about an hour, to match prod, on the reasoning that the
  # environment holding real balances should not have a 24-hour recovery window.
  # That reasoning is right and the value was still wrong, because it cannot be
  # applied:
  #
  #   aws rds modify-db-instance --backup-retention-period 7 --apply-immediately
  #   An error occurred (FreeTierRestrictionError):
  #     The specified backup retention period exceeds the maximum available to
  #     free tier customers. To remove all limitations, upgrade your account plan.
  #
  # Retried with 2 and refused identically, so the ceiling is exactly 1. Had this
  # been left at 7 it would not have failed quietly -- it would have failed the
  # whole `terraform apply`, and the first anyone knew of it would have been a
  # red pipeline on an unrelated change.
  #
  #   aws freetier get-account-plan-state
  #   { accountPlanType: FREE, accountPlanStatus: ACTIVE,
  #     accountPlanRemainingCredits: 154.48 USD,
  #     accountPlanExpirationDate: 2027-01-14 }
  #
  # SO THE REAL RPO ON REAL PLAYER MONEY IS 24 HOURS, and no amount of Terraform
  # changes that. The fix is a billing decision, not a code one: upgrading to a
  # Paid account plan lifts the cap, and this line becomes 7 in the same change.
  #
  # That upgrade is worth doing for a second reason the monitoring module already
  # documents from the other side -- on a FREE plan, exhausting credits SUSPENDS
  # resources rather than billing for them. With $154.48 left and a 2027-01-14
  # expiry, a real-money game is currently scheduled to be suspended on a date
  # nobody chose.
  #
  # AND NO BUDGET CAN WARN YOU. An earlier version of this comment credited the
  # account-wide budget with making the credit burn visible. It cannot: every
  # budget watches SPEND, and spend is zero while credits absorb the bill --
  # measured at -0.0000001/day in Cost Explorer while credits fell about $1.30 a
  # day. What actually watches it is FreeTierCreditsRemaining, published daily by
  # .github/workflows/free-tier-runway.yml and alarmed in modules/monitoring.
  backup_retention_period = 1
}

# Adopt the log group RDS already created for itself.
#
# The rds module now declares its export log groups so retention and encryption
# are chosen rather than inherited. This instance predates that, so RDS made
# /aws/rds/instance/fanosbingo-dev-pg/postgresql on its own -- with no retention
# at all -- and a plain create would fail with ResourceAlreadyExistsException.
#
# ONLY postgresql. The `upgrade` group does not exist in the account: nothing has
# triggered a version upgrade yet, and RDS creates each group lazily on first
# write. An import block for an absent resource fails the whole plan, so that one
# is left to be created normally.
#
# Verified before writing this, rather than assumed:
#
#   aws logs describe-log-groups --log-group-name-prefix /aws/rds/instance/
#     -> /aws/rds/instance/fanosbingo-dev-pg/postgresql   retentionInDays: None
#
# Safe to leave here permanently: once the resource is in state Terraform treats
# the block as satisfied and does nothing. Remove it whenever this environment is
# next rebuilt from scratch, at which point the group will be Terraform's from
# the start.
import {
  to = module.rds.aws_cloudwatch_log_group.exports["postgresql"]
  id = "/aws/rds/instance/${local.name_prefix}-pg/postgresql"
}

module "iam" {
  source = "../../modules/iam"

  name_prefix = local.name_prefix
  environment = var.environment

  kms_key_arn            = module.kms.main_key_arn
  wallet_signing_key_arn = module.kms.wallet_signing_key_arn

  # This environment's master secret, by exact ARN. Sourced from the rds module
  # rather than pattern-matched, so this role cannot request prod's.
  rds_master_secret_arn = module.rds.master_user_secret_arn

  github_repository = var.github_repository

  # The GitHub OIDC provider is account-wide. Dev creates it; prod reuses it by
  # setting create_github_oidc_provider = false and passing the ARN.
  create_github_oidc_provider = var.create_github_oidc_provider

  # Three contexts, and the third is a deliberate, bounded decision.
  #
  #   environment:dev       deploy-services, sync-secrets, the drill, ami-bump
  #   ref:refs/heads/main   anything dispatched from the default branch
  #   pull_request          the db-migrate DRY RUN on a pull request
  #
  # `pull_request` means PR-branch code can reach this role: it can read and
  # write dev's parameter tree and tunnel to the dev database. That is the cost
  # of dry-running a migration against a real database, the check is worth
  # having, and dev holds BSC testnet credentials by construction.
  #
  # It is emphatically NOT granted in prod, which is why this list is set per
  # environment rather than defaulted in the module.
  github_allowed_refs = ["environment:dev", "ref:refs/heads/main", "pull_request"]
}

# ---------------------------------------------------------------------------
# The application
#
# Every container is defined once, in modules/app_stack, and called identically
# by dev and prod. These blocks used to be inline here and simply absent from
# prod, which meant applying prod would have produced infrastructure with no
# application running on it.
#
# Which build runs is read from SSM (/fanosbingo-dev/images/<service>), written
# by the deploy workflow. The variables below only apply while an environment
# still predates that mechanism -- see modules/app_stack.
# ---------------------------------------------------------------------------
module "app_stack" {
  source = "../../modules/app_stack"

  name_prefix = local.name_prefix
  environment = var.environment
  aws_region  = var.aws_region
  domain_name = var.domain_name

  cluster_arn       = module.ecs.cluster_arn
  capacity_provider = module.ecs.capacity_provider_name
  log_group_name    = module.ecs.log_group_name

  db_host = module.rds.address
  db_port = module.rds.port
  db_name = module.rds.database_name

  task_execution_role_arn = module.iam.task_execution_role_arn
  task_ticker_role_arn    = module.iam.task_ticker_role_arn
  task_data_role_arn      = module.iam.task_data_role_arn
  task_functions_role_arn = module.iam.task_functions_role_arn
  wallet_signing_key_id   = module.kms.wallet_signing_key_id
  metric_namespace        = module.iam.metric_namespace

  # The chat alarms are forwarded to. The TOPIC they are accepted from is
  # constructed inside the module rather than passed from monitoring -- see the
  # comment on local.alerts_topic_arn there for the failed apply that caused it.
  telegram_alert_chat_id = var.telegram_alert_chat_id

  # Must match what the ssm module publishes, and what the RPC actually serves.
  # The service checks the latter at startup and refuses to run on a mismatch.
  bsc_chain_id    = 97
  bsc_rpc_primary = "https://data-seed-prebsc-1-s1.binance.org:8545"

  image_overrides = local.image_overrides
}

# Address changes only. Without these, moving the service definitions into
# modules/app_stack would destroy and recreate all four running services --
# a real outage in exchange for a refactor nobody asked to be disruptive.
moved {
  from = module.service_ticker
  to   = module.app_stack.module.ticker
}

moved {
  from = module.service_postgrest
  to   = module.app_stack.module.postgrest
}

moved {
  from = module.service_realtime
  to   = module.app_stack.module.realtime
}

moved {
  from = module.service_caddy
  to   = module.app_stack.module.caddy
}

# ---------------------------------------------------------------------------
# Cloudflare
#
# The other half of the origin lock. sg-app admits 443 only from Cloudflare's
# ranges; this is what makes sure Cloudflare is actually in front, with strict
# TLS and the settings that a Telegram Mini App needs.
#
# Count-gated on the zone id so a contributor without a Cloudflare token can
# still plan and apply everything else. When it is off, those settings are
# dashboard state and scripts/verify-cloudflare.sh is the only thing checking
# them.
# ---------------------------------------------------------------------------
module "cloudflare" {
  source = "../../modules/cloudflare"

  count = var.manage_cloudflare && try(trimspace(var.cloudflare_zone_id), "") != "" ? 1 : 0

  zone_id     = var.cloudflare_zone_id
  domain_name = var.domain_name

  # Taken from the ecs module, not typed in: the records must point at the
  # address the instance actually claims on boot, and a stale literal here would
  # black-hole the whole site.
  origin_ip = module.ecs.public_ip

  # The zone is now under Terraform and its DNS has converged, which is the
  # precondition the variable's own description asks for. Turning it on here
  # rather than changing the module default, so prod adopts it as a separate,
  # deliberate change with its own plan.
  #
  # Worth being clear about what this is and is not: it throttles
  # /functions/v1/auth and the wallet account-creation RPC. It is NOT what
  # protects the money-moving functions -- db/20-post/004 revoked EXECUTE on
  # those, which holds whether or not Cloudflare is in front.
  enable_rate_limiting = true
}

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix = local.name_prefix
  environment = var.environment
  kms_key_arn = module.kms.main_key_arn

  # Must match the namespace the containers publish to, or the game-loop alarm
  # watches nothing. Sourced from iam rather than restated, so it cannot drift.
  metric_namespace = module.iam.metric_namespace

  # The external health check probes api.<domain_name>. Passed from the same
  # variable the app_stack and cloudflare modules use, so the thing being checked
  # cannot drift from the thing being served.
  #
  # ON here, unlike prod, for the reason the rds block above spells out: this
  # environment is what api.<domain> actually resolves to, so this is where a
  # player-visible outage happens.
  domain_name                  = var.domain_name
  enable_external_health_check = true

  # The only alarm no budget can replace. Every budget here watches SPEND, and
  # spend is zero on a FREE plan -- credits absorb the bill before Cost Explorer
  # sees it, so they all sit at OK until the account is suspended. See the
  # comment on the alarm itself, and .github/workflows/free-tier-runway.yml.
  enable_free_tier_alarm = true

  alert_emails = var.alert_emails

  # Second channel, second device. Empty until a number is set in tfvars --
  # see the variable for why an empty list is a known gap and not a choice.
  alert_sms_numbers = var.alert_sms_numbers

  # $10 is a testing ceiling and this environment stopped being a testing
  # environment -- it is what serves players. Left as it is on purpose, though:
  # the current footprint bills nothing like $10, so the headroom is real, and a
  # low ceiling on the environment that must not surprise anybody is the right
  # direction to be wrong in. Raise it when prod exists and this is disposable
  # again, not before.
  monthly_budget_usd   = 10
  alert_thresholds_usd = [3, 6]

  rds_instance_id          = module.rds.instance_id
  rds_allocated_storage_gb = 20
  autoscaling_group_name   = module.ecs.autoscaling_group_name
  # SUBSCRIBE ONLY ONCE THERE IS SOMETHING TO ANSWER.
  #
  # SNS confirms an HTTPS subscription by CALLING the endpoint, and that endpoint
  # is a route on the functions container. Without this edge Terraform is free to
  # create the subscription first, SNS calls a service that has not yet restarted
  # with ALERT_TOPIC_ARNS, the handler drops the confirmation as an unknown
  # topic, and the apply fails after a five-minute wait:
  #
  #   Error: waiting for SNS Topic Subscription (...) confirmation:
  #          timeout while waiting for state to become 'false'
  #
  # That is not hypothetical -- it happened on 2026-08-05 and passed on the
  # retry, which is precisely what makes it worth pinning down rather than
  # shrugging at.
  #
  # Expressible only because app_stack no longer reads this module's outputs; it
  # constructs the topic arn itself. See local.alerts_topic_arn there.
  depends_on = [module.app_stack]

}
