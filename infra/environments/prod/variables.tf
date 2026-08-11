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
  description = "Apex domain the SPA is served from, e.g. fanosbingo.com."
  type        = string
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
