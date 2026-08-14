variable "aws_region" {
  description = "AWS region. us-east-1 is cheapest and is where CloudFront-scoped ACM certificates must live."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name. Becomes part of every resource name."
  type        = string
  default     = "prod"

  validation {
    condition     = var.environment == "prod"
    error_message = "This root module is prod. Do not point it at another environment."
  }
}

variable "project_name" {
  description = "Project slug used to build the resource name prefix."
  type        = string
  default     = "fanosbingo"
}

variable "vpc_cidr" {
  description = "CIDR for prod's VPC. Distinct from dev's 10.30.0.0/16 so the two could be peered."
  type        = string
  default     = "10.20.0.0/16"
}

variable "domain_name" {
  description = <<-EOT
    Apex domain this environment serves.

    bingonova.org since 2026-08-11. prod previously served yisakmesifin.org,
    which now belongs to dev.

    Defaulted here rather than passed by CI: terraform.yml's plan job declares
    no `environment:` (deliberately, so the read-only planner role stays
    reachable on a pull request), so an environment-scoped GitHub variable
    would be resolved differently by plan and apply. See the same variable in
    environments/dev.
  EOT
  type        = string
  default     = "bingonova.org"
}

variable "github_repository" {
  description = "GitHub repository permitted to assume the deploy role, as owner/name."
  type        = string
}

variable "alert_emails" {
  description = <<-EOT
    Addresses receiving budget and alarm notifications. Each recipient must click
    the SNS confirmation link before any alert is delivered.
  EOT
  type        = list(string)
}

variable "create_github_oidc_provider" {
  description = <<-EOT
    Leave false. scripts/bootstrap-aws.sh created the account-wide OIDC provider,
    and Terraform authenticates through it.
  EOT
  type        = bool
  default     = false
}

variable "bsc_chain_id" {
  description = "BSC chain id. 56 is mainnet. Only set 97 if you are deliberately running prod against testnet."
  type        = number
  default     = 56

  validation {
    condition     = contains([56, 97], var.bsc_chain_id)
    error_message = "bsc_chain_id must be 56 (mainnet) or 97 (testnet)."
  }
}

variable "cloudflare_zone_id" {
  description = <<-EOT
    Cloudflare zone id for domain_name.

    bingonova.org. DIFFERENT FROM DEV'S -- the two environments no longer share
    a zone, which is the whole point of the split: dev can manage its own DNS
    again without being able to touch anything prod owns.

    The API token is NOT a variable: the provider reads CLOUDFLARE_API_TOKEN
    from the environment, so it never enters Terraform state or a plan file. It
    needs Zone:Read, DNS:Edit, Zone Settings:Edit and Zone WAF:Edit -- on BOTH
    zones now, not just the original one.

    Defaulted here rather than passed by CI for the same reason domain_name is:
    the zone and the domain are one fact, and splitting them across a root and a
    CI variable is how they drift apart.
  EOT
  type        = string
  default     = "9bf80a12fa113a34596257cd5c0ad50e"
}

variable "manage_cloudflare" {
  description = <<-EOT
    Whether THIS root manages the Cloudflare zone.

    Both environments share one domain and therefore one zone, so exactly one of
    them may own the DNS records, the zone settings and the rate-limit ruleset.

    PROD OWNS THE ZONE, as of the cutover of 2026-08-11. This flipped from false
    in the same change that set dev's to false, and the two must never both be
    true: the zone settings would fight over one value, and Cloudflare permits
    one ruleset per phase, so the second root to apply would fail outright.
  EOT
  type        = bool
  default     = true
}

variable "alert_sms_numbers" {
  description = <<-EOT
    E.164 numbers for a SECOND alerting channel, e.g. ["+251911234567"].

    Empty means every alarm -- including "money owed to a player" -- reaches one
    email inbox and nothing else. See modules/monitoring/variables.tf for the
    SNS SMS caveats that are not visible from a clean apply.
  EOT
  type        = list(string)
  default     = []
}

variable "telegram_alert_chat_id" {
  description = <<-EOT
    Telegram chat the operator receives alarms in. Empty means alarms are
    verified and then not forwarded, which is logged rather than silent.

    Supplied by CI from the TELEGRAM_ALERT_CHAT_ID repository secret, never from
    terraform.tfvars.example -- that file is committed.
  EOT
  type        = string
  default     = ""
}

variable "real_money" {
  description = <<-EOT
    Whether this environment holds real player money. FLIP THIS BEFORE THE FIRST
    REAL DEPOSIT, not after.

    It is the switch modules/rds checks its durability settings against: with it
    true, the apply FAILS unless backup_retention_period >= 7, multi_az is on,
    deletion protection is on and a final snapshot is required. All four need the
    PAID account plan, which is the same upgrade that removes the credit
    exhaustion deadline -- so this variable is really one billing decision
    expressed as a precondition.

    It replaces a comment. environments/prod/main.tf said "ONE, AND IT MUST
    BECOME 7 BEFORE THE FIRST REAL DEPOSIT" and gated two other settings on the
    same promise, enforced by nobody. This cannot force anyone to set it, but it
    makes the four settings impossible to change halfway -- which is the version
    of the mistake that still looks correct in a diff.

    WHAT IT DELIBERATELY DOES NOT COVER: instance_count. Running two application
    instances is not a variable flip -- the single Elastic IP model in modules/ecs
    only works with one, so two needs an ALB and service discovery (see the
    header of modules/ecs_service on the awsvpc/ENI limits). A precondition
    demanding something not yet deployable would block the upgrade rather than
    guide it. The 194-second replacement outage measured on 2026-08-13 remains
    the accepted trade, and AGENTS.md section 7 is where it is recorded.
  EOT
  type        = bool
  default     = false
}

variable "accept_single_az_risk" {
  description = <<-EOT
    Acknowledge running the real-money database in ONE availability zone.

    Only consulted when real_money is true. Multi-AZ roughly doubles the RDS
    instance cost, and this project runs to a ~$32/month budget -- so it is not
    forced. What modules/rds forces is that the choice is RECORDED: without this,
    "real money, one AZ" is indistinguishable in a diff from nobody having
    thought about it.

    Accepting it means: an AZ failure takes the balance ledger offline until
    somebody restores by hand. The nightly pg_dump to S3 under Object Lock bounds
    how much data is lost; nothing bounds the downtime. That is a reasonable
    trade for a small player base and stops being one as the base grows -- which
    is the point at which the second instance, and the ALB it needs, become worth
    their cost.
  EOT
  type        = bool
  default     = false
}
