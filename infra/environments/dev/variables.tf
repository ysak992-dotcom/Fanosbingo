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
  description = "Apex domain the SPA is served from, e.g. fanosbingo.com. Used for the CORS allowed origin."
  type        = string
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
    limiting is enabled, Zone WAF:Edit -- on this zone only.
  EOT
  type        = string
  default     = ""
}

variable "manage_cloudflare" {
  description = <<-EOT
    Whether THIS root manages the Cloudflare zone.

    FALSE, AND IT MUST STAY FALSE. Not a default to flip back when convenient.

    modules/cloudflare writes api/app/rt.<domain_name>, and this root passes the
    same apex prod does. So a dev applied with this true does not create its own
    records -- it REPOINTS PRODUCTION'S THREE HOSTNAMES at dev's Elastic IP. The
    apply succeeds, reports nothing unusual, and the site is down.

    That matters more here than anywhere else in this repository, because dev is
    now stood up and destroyed on demand. This is a foot-gun that gets picked up
    every rebuild.

    Giving dev its own hostnames does not rescue it cheaply either:
    api.dev.<domain> is a second-level subdomain, so Cloudflare's Universal SSL
    does not cover it and Advanced Certificate Manager is $10/month -- more than
    the environment it would serve.

    Consequence, accepted and written down rather than discovered: the Cloudflare
    layer is the one part of the stack dev cannot test. Reach dev with a
    temporary security-group rule for your own address instead. See CUTOVER.md.
  EOT
  type        = bool
  default     = false
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
