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

variable "deep_health_check_path" {
  description = <<-EOT
    Path of the DEEP check: is the origin serving, not merely answering?

    health_check_path above is answered by Caddy itself and touches no upstream,
    deliberately. The consequence was that postgrest, realtime and the functions
    service could each stop with NO alarm anywhere -- three of the five
    containers, silently, because there are no ECS task-count alarms either.

    This path is served by the functions service and probes the database,
    postgrest and realtime, returning 503 and naming the failure if any is down.
    See services/functions/src/upstreams.js for why it is one endpoint rather
    than three separate health checks, and why a non-200 from an upstream still
    counts as alive.
  EOT
  type        = string
  default     = "/functions/v1/readyz/deep"
}

variable "enable_deep_health_check" {
  description = <<-EOT
    Whether to create the deep origin check and its alarm.

    Separate from enable_external_health_check because it has a precondition the
    reachability check does not: the functions service must be DEPLOYED and
    serving /readyz/deep. Turning this on against an environment whose functions
    image predates that route produces a check that is permanently red -- and an
    alarm that is always red is an alarm nobody reads, which is the failure mode
    modules/monitoring keeps coming back to.

    Turn it on in the apply AFTER the deploy that ships the route.
  EOT
  type        = bool
  default     = false
}

variable "enable_balance_drift_alarm" {
  description = <<-EOT
    Whether to alarm when the balance ledger disagrees with the balances.

    db/20-post/019 journals every movement of deposited_balance and won_balance,
    and the ticker publishes reconcile_balances() as BalanceDriftAccounts every
    five minutes. Non-zero means a balance moved without an entry, or an entry
    was altered. There is no benign cause.

    Same precondition shape as the deep check: the metric only exists once a
    ticker carrying that code has run, and the alarm treats missing data as
    breaching, so turning it on early produces a permanent false alarm.
  EOT
  type        = bool
  default     = false
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

    TWENTY-FOUR, AND IT CANNOT BE MORE. This read 30, with a validation block
    REQUIRING more than 24 -- and that combination is exactly what stopped the
    alarm from working at all.

    CloudWatch requires Period x EvaluationPeriods <= 86400 seconds. The alarm
    below uses one evaluation period of the full window, so 30 hours meant a
    period of 108000, over the ceiling. AWS accepted the alarm and then never
    evaluated it again.

    Measured on the live account on 2026-08-14, both environments:

      dev  StateReason cites a datapoint from 06/08/26 -- eight days stale
      prod StateReason cites a datapoint from 10/08/26 -- four days stale
      dev  alarm history: ONE transition ever, INSUFFICIENT_DATA -> OK on 08-07

    In that time dev went 78 HOURS with no backup datapoint (2026-08-11 to
    2026-08-14) and the alarm stayed OK throughout. For contrast, the game-loop
    alarm at period 60 updates normally.

    So the one control answering "did last night's backup happen" has never
    answered it, in either environment, since it was created -- and it is the
    control guarding the only recovery point older than 24 hours, because the
    account plan caps point-in-time recovery at one day.

    THE OLD VALIDATION IS INVERTED, not merely wrong. It enforced the condition
    that guarantees the alarm cannot evaluate, in the name of preventing a
    false alarm between normal runs.

    THE COST OF 24, stated rather than hidden: there is no slack. A backup more
    than 24 hours after the previous one pages somebody. Against a 04:00 cron
    that is usually fine, and where it is not -- the `prod` environment carries
    a REQUIRED REVIEWER, so its nightly dump waits for a human, measured at up
    to 82 minutes -- the alarm firing IS the information. A backup that did not
    happen on time is the thing this exists to report.

    A wider window is not expressible as a single metric alarm. It would need
    the metric to carry the real AGE and be published more often than daily,
    rather than a once-a-day heartbeat whose absence is the signal.
  EOT
  type        = number
  default     = 24

  validation {
    condition     = var.backup_alarm_hours > 0 && var.backup_alarm_hours <= 24
    error_message = "Must be between 1 and 24. CloudWatch requires Period x EvaluationPeriods <= 86400 seconds, and this alarm uses a single evaluation period, so anything above 24 hours produces an alarm that AWS accepts and never evaluates -- which is how both backup alarms sat at OK through a 78-hour gap."
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

variable "enable_host_metric_alarms" {
  description = <<-EOT
    Whether to alarm on host memory and disk usage.

    WHAT WAS BLIND. modules/ecs sets `monitoring { enabled = false }` (five-minute
    basic metrics, to avoid the detailed-monitoring charge) and basic EC2 metrics
    do not include memory or disk AT ALL -- those live inside the instance, where
    AWS cannot see them. So the single box running all five containers, ~1.03 GiB
    of steady state against 2 GiB, and a 30 GiB volume accumulating container
    images, had no memory or disk signal whatsoever.

    user_data now publishes MemoryUsedPercent and DiskUsedPercent every five
    minutes using the AWS CLI it already installs -- no CloudWatch agent, because
    its default configuration publishes a dozen metrics at $0.30 each. Two
    metrics and two alarms is about $0.80/month.

    PRECONDITION, same shape as the other staged alarms here: the metrics only
    exist once an instance has booted with the new user_data. That is a LAUNCH
    TEMPLATE change, so it does not take effect on apply -- the ASG references
    $Latest and Terraform sees no diff on it. It needs a deliberate instance
    refresh, which is a ~194-second outage. See AGENTS.md section 7.
  EOT
  type        = bool
  default     = false
}

variable "memory_alarm_threshold_percent" {
  description = <<-EOT
    Memory usage that should page somebody, as a percentage.

    90 rather than 95: there is a 2 GiB swapfile, so the box degrades into swap
    before it OOM-kills, and the useful moment to know is while it is still only
    slow. Measured as (total - available), not (total - free) -- page cache is
    not usage.
  EOT
  type        = number
  default     = 90
}

variable "disk_alarm_threshold_percent" {
  description = <<-EOT
    Root volume usage that should page somebody, as a percentage.

    80, which is early on purpose. The volume holds container images and the
    swapfile, and the failure when it fills is not gradual -- the container
    runtime stops being able to pull, and a deploy fails at the worst moment.
    Clearing space is a two-minute job with warning and an outage without.
  EOT
  type        = number
  default     = 80
}
