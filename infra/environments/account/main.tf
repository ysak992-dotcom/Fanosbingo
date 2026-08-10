/**
 * Fanos Bingo — account-wide security baseline.
 *
 * Everything here is a singleton: there is one CloudTrail per account, one
 * account-level S3 public access block, one password policy. Putting them in
 * dev or prod would mean either duplicating them (and paying twice for the same
 * management events) or having them disappear the moment dev is destroyed --
 * and dev is explicitly disposable.
 *
 * This root is small, changes rarely, and is applied on its own:
 *
 *   gh workflow run terraform.yml -f environment=account -f action=apply
 *
 * It has no dependency on dev or prod existing, and they have no dependency on
 * it. The one coupling is by name: the kms:Sign alarm excludes the task role
 * names the environment roots create, so if you ever rename them, update
 * permitted_signing_roles here in the same change.
 */

data "aws_caller_identity" "current" {}

locals {
  name_prefix = var.project_name

  # Names, not ARNs -- CloudTrail records the role name in
  # userIdentity.sessionContext.sessionIssuer.userName. Listed for every
  # environment whether or not it currently exists: a role that does not exist
  # simply never appears in the log, and pre-listing it means standing prod up
  # does not require remembering to come back here.
  permitted_signing_roles = [
    for env in var.environments : "${var.project_name}-${env}-task-functions"
  ]
}

# ---------------------------------------------------------------------------
# Alerting
#
# Separate from the per-environment topics on purpose. These fire about the
# account rather than about a game, and they must keep working when dev has been
# destroyed.
# ---------------------------------------------------------------------------
resource "aws_sns_topic" "security" {
  name              = "${local.name_prefix}-security-alerts"
  kms_master_key_id = aws_kms_key.audit.arn

  tags = { Name = "${local.name_prefix}-security-alerts" }
}

# Email subscriptions require the recipient to click a confirmation link before
# anything is delivered. Terraform reports the subscription as created while it
# is still "pending confirmation" -- check your inbox, or these alarms fire into
# the void.
resource "aws_sns_topic_subscription" "security_email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.security.arn
  protocol  = "email"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# Audit key
#
# Its own CMK rather than an environment's. The environment keys are destroyed
# with their environment, and audit logs must outlive the thing they describe.
# ---------------------------------------------------------------------------
resource "aws_kms_key" "audit" {
  description             = "${local.name_prefix} audit logs and security notifications"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = { Name = "${local.name_prefix}-audit" }
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${local.name_prefix}-audit"
  target_key_id = aws_kms_key.audit.key_id
}

# CloudWatch Logs and CloudWatch alarms publishing to SNS both need to use this
# key. Note that aws_kms_key_policy REPLACES the default policy, so the root
# statement has to be restated -- omitting it locks everyone out of the key,
# including the account itself.
data "aws_iam_policy_document" "audit_key" {
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
  }

  # Without this, an alarm transitioning to ALARM cannot publish to the
  # encrypted topic and the notification is dropped -- silently, which is the
  # worst possible outcome for a security alarm.
  statement {
    sid    = "AllowCloudWatchAlarmsToPublish"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudwatch.amazonaws.com"]
    }

    actions   = ["kms:GenerateDataKey*", "kms:Decrypt"]
    resources = ["*"]
  }

  # CloudTrail encrypting the log files it delivers.
  #
  # Conditioned on the encryption context rather than a specific trail ARN, on
  # purpose: the key policy would otherwise need the trail's ARN while the trail
  # needs the key's ARN, and Terraform cannot resolve that cycle. The context
  # still pins this to CloudTrail trails in THIS account, which is the property
  # that matters -- it is not a grant to CloudTrail generally.
  statement {
    sid    = "AllowCloudTrailToEncryptLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }

    actions   = ["kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:aws:cloudtrail:arn"
      values   = ["arn:aws:cloudtrail:*:${data.aws_caller_identity.current.account_id}:trail/*"]
    }
  }

  # Reading a delivered log file back. Without this the logs are written and
  # then unreadable, which is an audit trail in name only.
  statement {
    sid    = "AllowAccountToDecryptTrailLogs"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_kms_key_policy" "audit" {
  key_id = aws_kms_key.audit.id
  policy = data.aws_iam_policy_document.audit_key.json
}

# ---------------------------------------------------------------------------
# CloudTrail and its detections
# ---------------------------------------------------------------------------
module "cloudtrail" {
  source = "../../modules/cloudtrail"

  name_prefix      = local.name_prefix
  kms_key_arn      = aws_kms_key.audit.arn
  alerts_topic_arn = aws_sns_topic.security.arn

  permitted_signing_roles = local.permitted_signing_roles

  depends_on = [aws_kms_key_policy.audit]
}

# ---------------------------------------------------------------------------
# Account guardrails
#
# Each of these is a setting somebody would otherwise have to remember to click,
# in a console, once, correctly. That is the definition of a control that
# regresses.
# ---------------------------------------------------------------------------

# Belt and braces over each bucket's own public access block. This one cannot be
# overridden by a bucket-level policy, so a future bucket created outside
# Terraform is covered by default rather than by diligence.
resource "aws_s3_account_public_access_block" "this" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Every EBS volume created in this region is encrypted, including ones created
# by a service on your behalf where you never see a launch template.
resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

# There should be no IAM users with console access at all -- everything routine
# is OIDC -- but if one is ever created, it starts from a sane baseline instead
# of the AWS default of no policy whatsoever.
resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 16
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 180
  password_reuse_prevention      = 12
}

# Free, and it answers a question that is otherwise tedious and easy to get
# wrong: which of my resources can be reached from outside this account?
resource "aws_accessanalyzer_analyzer" "this" {
  analyzer_name = "${local.name_prefix}-external-access"
  type          = "ACCOUNT"

  tags = { Name = "${local.name_prefix}-external-access" }
}

# ---------------------------------------------------------------------------
# Cost allocation tags
#
# WITHOUT THIS, EVERY TAG-FILTERED BUDGET REPORTS ZERO FOREVER.
#
# A user-defined tag is not usable as a cost dimension until it is ACTIVATED in
# Billing. Until then Cost Explorer and Budgets can see the tag key exists and
# still attribute nothing to it, so a budget whose cost_filter names it matches
# no spend, sits at $0.00 actual with no forecast, and never crosses a threshold.
#
# MEASURED, not inferred:
#
#   aws ce list-cost-allocation-tags   -> Environment: Inactive
#   aws budgets describe-budgets       -> fanosbingo-dev-monthly
#                                         Actual 0.0, Forecast None
#
# modules/monitoring carries a long comment about the `$${` HCL escape that used
# to render this same filter as a literal, and about that being "the same class
# of defect as a statement that reports success and changes nothing". The escape
# was genuinely fixed. The behaviour did not change, because the cause was never
# only in the HCL -- it was here, one layer down, and the fix looked like it had
# worked because the symptom is identical either way: a budget reading zero.
#
# ACTIVATION IS NOT RETROACTIVE. Costs incurred before this applies stay
# unattributed permanently; only spend from the activation date forward carries
# the tag. So the per-environment budgets become meaningful roughly a day after
# this lands, not immediately -- do not read the first day's $0 as proof it is
# still broken.
#
# Environment is the one the budgets filter on. The other three are activated
# because the cost of doing so is nothing and the question "what is this
# environment spending on, and which of it is account-wide rather than dev"
# cannot be answered later for a period when the tags were off.
resource "aws_ce_cost_allocation_tag" "this" {
  for_each = toset(["Environment", "Project", "Scope", "ManagedBy"])

  tag_key = each.value
  status  = "Active"
}

# ---------------------------------------------------------------------------
# The backstop budget
#
# UNFILTERED, and that is the whole point of it existing alongside the
# per-environment ones.
#
# A tag-filtered budget can only ever see spend that carries the tag, and a
# meaningful amount of what this account bills for cannot carry one:
#
#   - data transfer and NAT-style charges, which are not tagged resources
#   - KMS request charges
#   - the CloudTrail and Terraform state buckets, tagged Scope=account and
#     therefore invisible to a filter on Environment
#   - anything created outside Terraform, by definition
#
# So the per-environment budgets answer "is dev costing more than it should",
# and this one answers "is the account costing more than it should" -- which is
# the question that matters when the failure mode is credit exhaustion
# SUSPENDING resources on a Free account plan, as modules/monitoring describes.
#
# It publishes to the security topic rather than an environment's, for the same
# reason the trail does: this must keep working when dev has been destroyed.
resource "aws_budgets_budget" "account_total" {
  name         = "${local.name_prefix}-account-total"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_account_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # No cost_filter at all. Every dollar the account bills counts.

  dynamic "notification" {
    for_each = var.account_alert_thresholds_usd

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = (notification.value / var.monthly_account_budget_usd) * 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [aws_sns_topic.security.arn]
      subscriber_email_addresses = var.alert_emails
    }
  }

  # Catches a trend while there is still time to act on it, rather than
  # reporting the money after it is spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.security.arn]
    subscriber_email_addresses = var.alert_emails
  }
}

# ---------------------------------------------------------------------------
# Logical backups
#
# WHY THIS EXISTS WHEN RDS ALREADY TAKES BACKUPS.
#
# It does, and they are capped at ONE DAY. Not by choice --
# `backup_retention_period` above 1 is refused outright on this account:
#
#   FreeTierRestrictionError: The specified backup retention period exceeds
#   the maximum available to free tier customers.
#
# Retried with 2 and refused identically, so the ceiling is exactly 1. Lifting
# it is a billing decision, deliberately deferred.
#
# So point-in-time recovery answers "undo what happened in the last 24 hours",
# and nothing answers "undo what happened last Monday". For a system holding
# real player balances that is the WRONG WAY ROUND: disk failure is loud and
# immediate, while the failures that actually cost money -- a bad migration, a
# fraudulent approval, a wrong UPDATE -- are quiet and found days later. The
# monthly restore drill passes and proves only that you can recover from
# something you noticed today.
#
# AWS caps retention. It does not stop us keeping our own copies. A nightly
# pg_dump to this bucket turns a 1-day window into 30 days for approximately
# nothing: the database holds a few MB of actual data, and thirty compressed
# dumps sit inside the 5 GB S3 free tier.
#
# IN THE ACCOUNT ROOT, NOT THE ENVIRONMENT, and that is the whole point of the
# placement. A backup stored inside the thing it backs up is not a backup. The
# same argument the audit key above makes for CloudTrail: these must outlive the
# environment they describe, including the case where that environment was
# destroyed by the incident.
#
# SSE-S3 RATHER THAN A CMK, deliberately, and this inverts the usual advice.
# Every environment CMK is destroyed with its environment -- dev's has a 7-day
# window. A backup encrypted with a key that dies alongside the database is
# ciphertext, not a recovery point. SSE-S3 is managed by AWS, outlives every
# key here, and costs nothing. Confidentiality still rests on the bucket policy
# and IAM, which is where it rested with a CMK too.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "backups" {
  bucket = "${local.name_prefix}-backups-${data.aws_caller_identity.current.account_id}"

  # No force_destroy. `terraform destroy` FAILING on a bucket with objects in it
  # is the correct outcome for the only copy of the ledger that is not inside
  # the environment being destroyed.
  tags = { Name = "${local.name_prefix}-backups" }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket = aws_s3_bucket.backups.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning protects against the failure this bucket exists to survive: a
# principal that can write here can also overwrite. A version cannot be
# silently replaced, only added to.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # Explicit dependency: S3 rejects a lifecycle rule referencing noncurrent
  # versions on a bucket where versioning is still being enabled.
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "expire-old-dumps"
    status = "Enabled"

    filter {}

    # THIRTY DAYS is the number that matters, and it is chosen against how long
    # a quiet failure takes to surface rather than against storage cost. A
    # disputed balance or a bad migration is typically noticed within days, not
    # hours -- which is precisely the range RDS's 1-day cap cannot reach.
    #
    # PLUS ONE, so this never races the Object Lock retention below. The lock
    # guarantees thirty days of immutability; a lifecycle expiration on day
    # thirty would be refused by S3 for as long as the lock holds and then
    # silently retried, which works but leaves the rule quietly not doing what
    # it says. Deleting on day thirty-one means the two agree.
    expiration {
      days = var.backup_retention_days + 1
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }

    # Housekeeping: a failed multipart upload otherwise bills forever while
    # being invisible in the object listing.
    abort_incomplete_multipart_upload {
      days_after_initiation = 3
    }
  }
}

# ---------------------------------------------------------------------------
# Object Lock -- the control that makes these backups survive the account
#
# WHAT VERSIONING ABOVE DOES NOT DO. It stops a dump being silently REPLACED.
# It does not stop it being DELETED: a principal holding s3:DeleteObjectVersion
# can remove every version, and this account has such a principal -- an IAM user
# with AdministratorAccess and a console password. The same credential can clear
# `deletion_protection` on the RDS instance and drop it.
#
# So today the database and the only copy of the database that outlives it share
# one blast radius, and CloudTrail records management events only -- the object
# deletions would not even appear. That is the gap this closes: the backups stop
# being reachable by the credential whose misuse they exist to survive.
#
# COMPLIANCE, NOT GOVERNANCE, AND THIS IS THE WHOLE DECISION.
#
#   GOVERNANCE  a principal with s3:BypassGovernanceRetention can override it.
#               Administrator has that permission. It defends against a mistake
#               and against nobody else, which is not the threat above.
#   COMPLIANCE  nothing overrides it. Not this account's administrator, not the
#               root user, not AWS Support.
#
# GOVERNANCE would let this file claim a protection it does not provide, which
# is the failure mode this repository keeps finding in itself. So: COMPLIANCE.
#
# WHICH MEANS THIS CANNOT BE UNDONE. For thirty days after it is written, every
# dump is undeletable by anyone, and the retention cannot be shortened. Read the
# blast radius of being wrong before applying: ~470 KB a night, so a mistake
# costs roughly 14 MB of storage held for thirty days, inside the 5 GB S3 free
# tier. That is the correct direction to be wrong in for the only recovery point
# older than 24 hours that this system has.
#
# APPLIES TO NEW OBJECTS ONLY. The dumps already in the bucket stay deletable
# and simply age out. Full coverage exists thirty days after the first apply.
#
# NO REPLACEMENT RISK, and this is worth stating because getting it wrong would
# destroy the bucket. `object_lock_enabled` on aws_s3_bucket is ForceNew -- but
# it is also Computed, so leaving it unset there (as it is above) means
# Terraform reads the live value and plans no change. Enabling the lock through
# this separate resource is supported on an existing bucket precisely because
# versioning is already on. CONFIRM THAT IN THE PLAN BEFORE APPLYING: if the
# plan proposes replacing aws_s3_bucket.backups, stop.
resource "aws_s3_bucket_object_lock_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  # S3 refuses a lock configuration on a bucket whose versioning is not yet
  # settled, the same ordering the lifecycle rule needs.
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.backup_retention_days
    }
  }
}
