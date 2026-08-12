variable "aws_region" {
  description = "AWS region. us-east-1 is cheapest and is where CloudFront-scoped ACM certificates must live."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name. Becomes part of every resource name."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "project_name" {
  description = "Project slug used to build the resource name prefix."
  type        = string
  default     = "fanosbingo"
}

variable "vpc_cidr" {
  description = "CIDR for this environment's VPC. Keep dev and prod distinct so they could be peered later."
  type        = string
  default     = "10.30.0.0/16"
}

variable "domain_name" {
  description = <<-EOT
    Apex domain this environment serves.

    DEFAULTED HERE RATHER THAN PASSED BY CI, and that is the point.

    It used to come from a single repository variable shared by both roots,
    which was survivable only while both roots served the same domain. They no
    longer do.

    The obvious fix -- an environment-scoped GitHub variable -- fails silently.
    terraform.yml's PLAN job declares no `environment:`, deliberately, so its
    OIDC subject stays `pull_request` and the read-only planner role is
    reachable. `vars.DOMAIN_NAME` there resolves the REPOSITORY value while the
    apply job resolves the ENVIRONMENT one, so plan and apply would disagree
    about which domain they were building and the plan would look fine.

    A per-environment property belongs in the per-environment root, where the
    VPC CIDR, the chain id and the RPC endpoints already live.
  EOT
  type        = string
  default     = "yisakmesifin.org"
}

variable "github_repository" {
  description = "GitHub repository permitted to assume the deploy role, as owner/name."
  type        = string
}

variable "ticker_image" {
  description = <<-EOT
    Full image reference for the ticker, tagged by git SHA. Left null until the
    first image is pushed; CI then deploys new revisions directly, so this is
    only the initial value Terraform sets.
  EOT
  type        = string
  default     = null
}

variable "postgrest_image" {
  description = "Full image reference for PostgREST, tagged by git SHA. Null until first pushed."
  type        = string
  default     = null
}

variable "realtime_image" {
  description = "Full image reference for Realtime, tagged by git SHA. Null until first pushed."
  type        = string
  default     = null
}

variable "caddy_image" {
  description = "Full image reference for Caddy, tagged by git SHA. Null until first pushed."
  type        = string
  default     = null
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
    Create the account-wide GitHub OIDC provider. Normally false: the bootstrap
    script created it, and Terraform authenticates THROUGH it, so Terraform
    cannot also be what creates it.
  EOT
  type        = bool
  default     = false
}

variable "cloudflare_zone_id" {
  description = <<-EOT
    Cloudflare zone id for domain_name. Empty disables Terraform management of
    DNS and zone settings, leaving them as dashboard state.

    The API token is NOT a variable: the provider reads CLOUDFLARE_API_TOKEN
    from the environment, so it never enters Terraform state or a plan file.
    The token needs Zone:Read, DNS:Edit, Zone Settings:Edit and, if rate
    limiting is enabled, Zone WAF:Edit -- and now on BOTH zones, since the two
    environments no longer share one.

    Defaulted here for the same reason domain_name is: the zone and the domain
    are one fact, and splitting them across the root and a CI variable is how
    they drift apart.
  EOT
  type        = string
  default     = "8166779c73d66db7491dc1c63849cf61"
}

variable "manage_cloudflare" {
  description = <<-EOT
    Whether THIS root manages the Cloudflare zone.

    TRUE SINCE 2026-08-11, AND THIS SAID THE OPPOSITE IN CAPITALS UNTIL THEN.

    It read "FALSE, AND IT MUST STAY FALSE", because modules/cloudflare writes
    api/app/rt.<domain_name> and both roots passed the SAME apex. A dev applied
    with this true did not create its own records -- it repointed production's
    three hostnames at dev's Elastic IP, succeeding and reporting nothing.

    That reasoning was entirely about a shared apex, and the apex is no longer
    shared: prod serves bingonova.org and dev serves yisakmesifin.org, separate
    Cloudflare zones in the same account. Writing api/app/rt in this zone now
    touches nothing prod owns.

    It also retires the accepted consequence recorded alongside it -- that the
    Cloudflare layer was the one part of the stack dev could not test. It can
    now: origin lock, zone settings, and the rate-limit rule that applies
    cleanly and does not enforce are all exercisable here, against a domain no
    player reaches.
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
