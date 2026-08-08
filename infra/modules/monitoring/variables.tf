variable "name_prefix" {
  description = "Prefix applied to every resource name, e.g. fanosbingo-dev."
  type        = string
}

variable "environment" {
  description = "Environment name. Used as the budget's cost-allocation tag filter."
  type        = string
}

variable "metric_namespace" {
  description = <<-EOT
    CloudWatch namespace the ticker publishes SecondsSinceLastNumberCalled,
    ActiveGames and TickDuration to. Must match what the containers are given.
    Get it wrong and the game-loop alarm watches a namespace nothing writes to
    -- which, because it treats missing data as breaching, pages continuously
    rather than failing quiet. modules/iam is the source of truth for the value.
  EOT
  type        = string
}

variable "kms_key_arn" {
  description = "CMK encrypting the SNS alert topic."
  type        = string
}

variable "alert_emails" {
  description = <<-EOT
    Addresses receiving budget and alarm notifications. Each must click the SNS
    confirmation email before anything is delivered — an unconfirmed
    subscription silently drops every alert.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "At least one alert email is required; alarms with no subscriber are worse than no alarms."
  }
}

variable "monthly_budget_usd" {
  description = "Monthly budget ceiling for this environment, in USD."
  type        = number
  default     = 32
}

variable "alert_thresholds_usd" {
  description = <<-EOT
    Absolute spend levels that trigger an alert, in USD. Converted to
    percentages of monthly_budget_usd. Each must be below the ceiling.
  EOT
  type        = list(number)
  default     = [20, 27]

  validation {
    condition     = length(var.alert_thresholds_usd) > 0
    error_message = "Provide at least one alert threshold."
  }
}

variable "rds_instance_id" {
  description = "RDS instance identifier, for alarm dimensions."
  type        = string
}

variable "rds_allocated_storage_gb" {
  description = "RDS allocated storage in GiB, used to compute the 20% free-space threshold."
  type        = number
  default     = 20
}

variable "rds_max_connections_alarm" {
  description = <<-EOT
    Connection count that triggers an alarm. db.t4g.micro allows roughly 80-110
    depending on memory, so 60 leaves room to react before exhaustion.
  EOT
  type        = number
  default     = 60
}

variable "autoscaling_group_name" {
  description = "ASG name, for EC2 alarm dimensions."
  type        = string
}

variable "alert_sms_numbers" {
  description = <<-EOT
    E.164 phone numbers for a SECOND alerting channel, e.g. ["+251911234567"].

    Empty by default, and the default is a known gap rather than a choice: with
    it empty, every alarm -- including "money owed to a player" -- reaches one
    Gmail inbox and nothing else.

    See the comment on aws_sns_topic_subscription.sms for the three things that
    bite here: the $1/month default spend limit that DROPS messages rather than
    queueing them, +251 origination requirements, and the fact that an SMS
    subscription needs no confirmation -- so a mistyped number fails silently
    forever. Prove delivery with:

      ./scripts/verify-alarms.sh <env> --fire <alarm-name>
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.alert_sms_numbers : can(regex("^\\+[1-9][0-9]{7,14}$", n))])
    error_message = "Each number must be E.164: a leading +, country code, digits only. A number SNS cannot parse is a subscription that never delivers and never says so."
  }
}

variable "enable_telegram_alerts" {
  description = <<-EOT
    Subscribe the functions service to this topic, so alarms reach Telegram.

    ON by default: it is the only second channel that delivers on this account.
    SMS was the intended one and is refused before a phone number is even
    considered -- see the comment on aws_sns_topic_subscription.sms.

    Turn it OFF for an environment whose functions service is not deployed yet.
    SNS confirms a subscription by calling the endpoint, so subscribing to a
    host that 404s leaves it `pending confirmation` and delivers nothing.
  EOT
  type        = bool
  default     = true
}

variable "domain_name" {
  description = <<-EOT
    Apex domain. The external health check probes api.<domain_name>, which is
    the hostname the Mini App actually calls -- so the check covers DNS, the
    Cloudflare edge, the origin lock and the origin, not merely the last hop.
  EOT
  type        = string
}

variable "enable_external_health_check" {
  description = <<-EOT
    Whether to create the Route 53 health check and its alarm.

    On by default: it is the only signal in this module that looks at the system
    from where a player stands, and about $0.85/mo all in ($0.75 for the check at
    the non-AWS endpoint rate, $0.10 for the alarm).

    It creates NO DNS. Cloudflare remains authoritative for the domain -- a
    Route 53 health check used without a record pointing at it is only a prober
    and a CloudWatch metric. See the comment on the resource itself.

    Turn it OFF for an environment with no public DNS -- a health check against
    a hostname that does not resolve reports Unhealthy forever, which is an
    alarm that cries wolf from the moment it is created.
  EOT
  type        = bool
  default     = true
}

variable "health_check_path" {
  description = <<-EOT
    Path the external check requests. Caddy answers /healthz itself without
    touching an upstream, which is what keeps this a statement about
    reachability rather than a second, worse database check -- the functions
    service has /readyz for that.
  EOT
  type        = string
  default     = "/healthz"
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "pending_deposit_alarm_minutes" {
  description = <<-EOT
    Age of the oldest unapproved deposit before alerting, in minutes.

    FOUR HOURS, and the number is chosen against what a human can act on rather
    than against what the UI promises.

    The deposit form says "usually within a few minutes", and a player with an
    unapproved claim cannot join a game at all -- so the temptation is to alarm
    at five. That would page a solo operator through the night for every
    overnight deposit and teach them to ignore the alarm, which is worse than
    having none.

    This is the backstop underneath a per-claim notification, not a replacement
    for one. It answers "is anybody looking at the queue at all", and four hours
    is long enough that a normal working rhythm never trips it and short enough
    that a claim does not sit for a day -- which is exactly what was found on a
    player's screen and prompted this.

    When the Telegram bot exists, notify the operator per claim and this can be
    raised further.
  EOT
  type        = number
  default     = 240
}

variable "pending_withdrawal_alarm_minutes" {
  description = <<-EOT
    Age of the oldest unpaid withdrawal before alerting, in minutes.

    EIGHT HOURS, longer than the deposit threshold, and deliberately.

    A pending deposit BLOCKS a player from playing. A pending withdrawal does
    not block anything -- it is money owed, and the operator has to physically
    send it from their own bank account, which they cannot do at 3am. The slower
    action deserves the longer fuse.

    It is still a trust issue rather than a convenience one, so it alarms at all.
  EOT
  type        = number
  default     = 480
}

variable "enable_backup_alarm" {
  description = <<-EOT
    Alarm when no nightly logical backup has been recorded.

    ON where db-backup.yml runs. Turn it OFF for an environment that has no
    backup schedule, or it alarms from creation -- the metric is absent and
    absence is deliberately treated as breaching.
  EOT
  type        = bool
  default     = true
}

variable "backup_alarm_hours" {
  description = <<-EOT
    Hours without a successful backup before alerting.

    THIRTY, against a 24-hour schedule. Wide enough that a queued runner or an
    hour of GitHub trouble does not page anybody, narrow enough that two missed
    nights cannot pass unnoticed.
  EOT
  type        = number
  default     = 30

  validation {
    condition     = var.backup_alarm_hours > 24
    error_message = "Must exceed the 24-hour backup interval, or the alarm fires between normal runs."
  }
}

variable "enable_free_tier_alarm" {
  description = <<-EOT
    Alarm when free-tier credits run low.

    ON where .github/workflows/free-tier-runway.yml publishes the metric. Turn it
    OFF elsewhere: the alarm treats absent data as breaching, deliberately, so it
    would fire from creation in an environment nothing publishes to.

    Turn it off too once the account is on a PAID plan -- there is no cliff then,
    and the workflow publishes a sentinel rather than a balance.
  EOT
  type        = bool
  default     = false
}

variable "free_tier_credit_floor" {
  description = <<-EOT
    Credit balance, in USD, below which to alert.

    Roughly a month of runway at the observed burn of ~$1.30/day. It is a
    DURATION expressed in dollars, not an opinion about dollars -- if the burn
    rises, this should rise with it.
  EOT
  type        = number
  default     = 50
}
