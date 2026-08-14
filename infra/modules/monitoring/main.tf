/**
 * Budgets and baseline alarms.
 *
 * The budget alerts are not decoration. On a credit-based AWS Free Tier plan,
 * exhausting your credits on a *Free* account plan suspends resources — for a
 * real-money game that is an outage, not a warning. These alerts are the early
 * signal that you need to switch to a Paid account plan, or that something is
 * running that should not be.
 *
 * Coverage is in two layers, and the second matters more.
 *
 * INFRASTRUCTURE alarms (RDS, EC2) tell you a component is unhealthy. They are
 * necessary and insufficient: every one of them can sit at OK while the game is
 * frozen, because a process can be running happily and still not be calling
 * numbers.
 *
 * The GAME LOOP alarm is the one that corresponds to what a player experiences.
 * The ticker's Dockerfile deliberately ships no HEALTHCHECK and says so: its
 * liveness is asserted here instead, from the outside, on the thing that
 * actually matters.
 *
 * The EXTERNAL health check is the third layer, and it exists because the first
 * two share a blind spot: both observe the system from inside AWS. Nothing here
 * used to answer "can a player actually load the site". The instance can be
 * healthy, the ticker can be calling numbers, every alarm below can read OK, and
 * the site can be unreachable -- see the comment on the Route 53 check for the
 * specific way that happens after an instance replacement.
 *
 * ALARM BUDGET: this module defines THIRTEEN alarms -- the twelfth is
 * `backup-did-not-run`, the thirteenth `free-tier-credits-low`. Ten was the whole
 * CloudWatch free-tier allowance, so three cost $0.10/mo each, and the health
 * check itself is $0.75/mo -- the NON-AWS endpoint rate, because the hostname resolves
 * to Cloudflare rather than to an AWS address. About $0.85 against a $32 budget,
 * spent deliberately, to cover the only failure mode nothing else can see.
 *
 * A previous version of this comment claimed ten alarms fit exactly and left it
 * there. Two things were already untrue when it was written: the ECS capacity
 * provider creates two target-tracking alarms of its own
 * (TargetTracking-<asg>-AlarmHigh/AlarmLow), which bill identically and which
 * this module does not manage, so the account was at twelve. Counting only what
 * one file declares is how a budget comment goes stale without anyone lying.
 *
 * If you need another, the honest options are to pay for it, to retire one that
 * has never fired, or to fold two related signals into a metric math alarm.
 *
 * FOUR MORE ALARMS AND A SECOND HEALTH CHECK, all count-gated and all OFF by
 * default, added to close the gaps a review found. Costed here rather than left
 * for the next person to discover on a bill:
 *
 *   origin-degraded          the deep check. postgrest, realtime and functions
 *                            could each stop with NO alarm anywhere -- the only
 *                            external check is answered by Caddy itself, and
 *                            there are no ECS task-count alarms. Three of five
 *                            containers, silently.
 *   balance-ledger-drift     db/20-post/019's journal disagreeing with the
 *                            balances. Without it the ledger is a table that
 *                            grows rather than a control.
 *   host-memory-high         basic EC2 metrics contain NO memory or disk
 *   host-disk-high           figure at all -- they are inside the guest, where
 *                            AWS cannot see. modules/ecs keeps detailed
 *                            monitoring off, so the five-container box had no
 *                            signal for either.
 *
 * COST WHEN ALL FOUR ARE ENABLED, at list price:
 *
 *   4 alarms                        $0.40   (all past the free ten)
 *   1 Route 53 health check         $0.75   (non-AWS endpoint rate, as above)
 *   4 custom metrics                $1.20   BalanceDrift{Accounts,Total},
 *                                           {Memory,Disk}UsedPercent
 *   PutMetricData calls            ~$0.10   one every 5 minutes
 *                                   -----
 *                                   $2.45 / month
 *
 * ZERO while the flags are false, which is how they ship. That is a real
 * fraction of a $32 budget and it is the cheapest form this coverage takes --
 * the alternative for the host metrics is the CloudWatch agent, whose default
 * configuration publishes a dozen metrics rather than two, and the alternative
 * for the deep check is three separate health checks at $0.75 each instead of
 * one endpoint that names which upstream failed.
 */

resource "aws_sns_topic" "alerts" {
  name              = "${var.name_prefix}-alerts"
  kms_master_key_id = var.kms_key_arn

  tags = merge(var.tags, { Name = "${var.name_prefix}-alerts" })
}

# Email subscriptions require the recipient to click a confirmation link before
# anything is delivered. Terraform reports the subscription as created while it
# is still "pending confirmation" — check your inbox, or alarms will fire into
# the void.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# A SECOND CHANNEL, on a second device.
#
# !! SMS DOES NOT DELIVER ON THIS ACCOUNT, AND DID NOT SAY SO.
# !!
# !! This subscription was created, reported active by SNS, and silently
# !! dropped every message. The send path refuses at the ACCOUNT level, before
# !! any phone number is considered:
# !!
# !!   aws sns get-sms-sandbox-account-status
# !!   UserError: The AWS Access Key Id needs a subscription for the service
# !!              (Service: PinpointSmsVoiceV2)
# !!
# !! SNS SMS is delivered by AWS End User Messaging, which this account is not
# !! enrolled in -- so this would have failed for a US number identically. It is
# !! NOT a restriction on Ethiopian numbers, and diagnosing it as one would send
# !! somebody looking for a second SIM instead of a console setting. The same
# !! shape appears on GuardDuty and Security Hub here: SubscriptionRequiredException.
# !!
# !! Enrolling is not the end of it: a new account then lands in the SMS
# !! sandbox, where only pre-verified numbers receive anything, and +251 wants a
# !! registered origination identity on top.
# !!
# !! Kept, defaulted to empty, because it becomes correct the moment the account
# !! is enrolled -- and because deleting it would erase the record of why the
# !! obvious answer was not taken. The channel that actually works is the
# !! Telegram delivery below.
# !!
# !! An SMS subscription needs no confirmation click, so nothing anywhere
# !! reports this as broken. Prove any alerting change with
# !! scripts/verify-alarms.sh --fire, and believe the handset, not the console.
#
# Every alarm in this file delivered to exactly one Gmail address, which is one
# inbox, on one phone, behind one set of push settings. That is fine for the
# infrastructure alarms -- an RDS CPU credit warning can wait for morning. It is
# not fine for the three that are about a person waiting:
#
#   game-loop-stalled            players are watching a frozen board
#   deposits-waiting-too-long    a player cannot join a game at all
#   withdrawals-waiting-too-long money owed to a player
#
# The whole argument for those alarms is that a support ticket should have been
# a page. Email is not a page. It is the same delivery mechanism as everything
# else in an inbox, and at 03:00 it is indistinguishable from a newsletter.
#
# SMS rather than a Telegram message, despite this being a Telegram product,
# because SNS speaks SMS natively and speaks Telegram not at all -- a Telegram
# alert needs a Lambda to reshape the SNS envelope into a sendMessage call, and
# a new function whose own failure is silent is a poor trade for a delivery path
# that must work when other things do not. Revisit if the operator bot gets
# built for other reasons; it is then a small addition.
#
# THREE THINGS TO KNOW BEFORE SETTING THIS, none of which are visible from a
# clean apply:
#
#   * The default SNS SMS spend limit on a new account is $1/month, and messages
#     beyond it are DROPPED rather than queued. A handful of alarms a month fits;
#     raise it through a support request before relying on this for volume.
#   * Ethiopian (+251) destinations are reachable but may require a registered
#     origination identity depending on carrier. Confirm delivery with
#     scripts/verify-alarms.sh --fire rather than assuming.
#   * Unlike email, an SMS subscription needs no confirmation click -- so it
#     starts working immediately, and a wrong number fails silently forever.
#
# E.164 with the country code, e.g. "+251911234567".
resource "aws_sns_topic_subscription" "sms" {
  for_each = toset(var.alert_sms_numbers)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "sms"
  endpoint  = each.value
}

# ---------------------------------------------------------------------------
# The channel that actually delivers: Telegram, via the functions service.
#
# NOT A LAMBDA, and that is the whole point rather than a shortcut. A Lambda is
# another AWS service to be enrolled in, and the failure being worked around is
# exactly "a service was not enabled and nothing said so". The functions
# container already holds the bot token, already runs, and Caddy already routes
# /functions/v1/* to it -- so this adds a route, not a dependency.
#
# It is also where the operator already is. This is a Telegram product; an alert
# arriving in the same app as the game is likelier to be read at 03:00 than one
# in an inbox.
#
# EMAIL STAYS. This is a second channel, not a replacement. If the functions
# container is the thing that is broken, email is what still arrives -- which is
# the property that makes two channels worth having at all.
#
# ENDPOINT AUTHENTICATION is the Amazon signature, checked in
# services/functions/src/alerts.js before anything else happens, plus a topic
# allowlist -- a valid signature only proves AWS sent it, not that it is ours.
# The route is necessarily unauthenticated: SNS cannot present a bearer token.
#
# endpoint_auto_confirms = true because the handler fetches SubscribeURL itself
# (after pinning its host, or the confirmation is an SSRF primitive). Without
# it Terraform reports the subscription as `pending confirmation` forever.
#
# raw_message_delivery stays FALSE: the handler reads TopicArn, Signature and
# SigningCertURL from the SNS envelope, and raw delivery strips exactly those.
# Turning it on would silently disable every check above.
# ---------------------------------------------------------------------------
resource "aws_sns_topic_subscription" "telegram" {
  count = var.enable_telegram_alerts ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "https"
  endpoint  = "https://api.${var.domain_name}/functions/v1/alerts/sns"

  endpoint_auto_confirms = true
  raw_message_delivery   = false

  # SNS gives up and DISABLES a subscription that keeps failing. A container
  # restart during a deploy is a normal, expected gap, so retry across it rather
  # than losing the channel to a routine rollout.
  confirmation_timeout_in_minutes = 5

  delivery_policy = jsonencode({
    healthyRetryPolicy = {
      numRetries         = 5
      minDelayTarget     = 5
      maxDelayTarget     = 60
      numMinDelayRetries = 2
      numMaxDelayRetries = 2
      backoffFunction    = "exponential"
    }
  })
}

# ---------------------------------------------------------------------------
# Cost
# ---------------------------------------------------------------------------
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # format(), NOT "user:Environment$${var.environment}".
  #
  # In HCL, `$${` is the escape sequence for a LITERAL `${`. The obvious-looking
  # string therefore renders as the seven characters `user:Environment` followed
  # by the literal text `${var.environment}` -- the interpolation never happens.
  # Verified with `terraform console`:
  #
  #   > "user:Environment$${var.environment}"
  #   "user:Environment${var.environment}"
  #
  # That filter matches no resource, so the budget reported $0 actual and $0
  # forecast permanently, and every notification below was unreachable. Silent,
  # and in exactly the situation they exist to catch: on a credit-based Free Tier
  # plan, exhausting credits SUSPENDS resources, and these alerts are the warning
  # to switch to Paid before that happens to a real-money game.
  #
  # Same class of defect as the ALTER DEFAULT PRIVILEGES form documented in
  # db/20-post/004 -- a statement that reports success and changes nothing.
  #
  # format() sidesteps the escape entirely: the `$` is data, not syntax.
  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Environment$%s", var.environment)]
  }

  # Absolute dollar thresholds, expressed as percentages of the limit.
  dynamic "notification" {
    for_each = var.alert_thresholds_usd

    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = (notification.value / var.monthly_budget_usd) * 100
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
      subscriber_email_addresses = var.alert_emails
    }
  }

  # Forecast-based alert: catches a cost trend early enough to act, rather than
  # telling you about it once the money is already spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.alerts.arn]
    subscriber_email_addresses = var.alert_emails
  }
}

# ---------------------------------------------------------------------------
# Database
# ---------------------------------------------------------------------------

# Disk full means the database stops accepting writes — a total outage. The
# usual cause here is a stalled logical replication slot retaining WAL, which
# max_slot_wal_keep_size is meant to prevent; this alarm is the backstop for
# when that assumption is wrong.
resource "aws_cloudwatch_metric_alarm" "rds_free_storage" {
  alarm_name          = "${var.name_prefix}-rds-low-storage"
  alarm_description   = "RDS free storage below 20%. Disk full stops all writes."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = var.rds_allocated_storage_gb * 1024 * 1024 * 1024 * 0.2

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "breaching"

  tags = var.tags
}

# On a burstable class, exhausting CPU credits does not throttle gracefully —
# the instance drops to baseline (roughly 10-20% of a vCPU) and query latency
# collapses. This is the alarm that tells you it is time for db.t4g.small.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_credits" {
  alarm_name          = "${var.name_prefix}-rds-cpu-credits-low"
  alarm_description   = "RDS CPU credit balance low. Burstable instance is about to throttle to baseline."
  namespace           = "AWS/RDS"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 30

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name_prefix}-rds-cpu-high"
  alarm_description   = "RDS CPU above 80% for 15 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# PostgREST, Realtime, the ticker and the functions container each hold a pool.
# Exhausting max_connections presents as intermittent, confusing failures rather
# than a clean outage.
resource "aws_cloudwatch_metric_alarm" "rds_connections" {
  alarm_name          = "${var.name_prefix}-rds-connections-high"
  alarm_description   = "RDS connection count approaching the instance limit."
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.rds_max_connections_alarm

  dimensions         = { DBInstanceIdentifier = var.rds_instance_id }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Application instance
# ---------------------------------------------------------------------------

# With a single instance this alarm IS the outage notification. The ASG will
# replace the instance in 3-5 minutes on its own; this tells you it happened.
resource "aws_cloudwatch_metric_alarm" "ec2_status_check" {
  alarm_name          = "${var.name_prefix}-ec2-status-check-failed"
  alarm_description   = "Application instance failed its status check. Game is down until the ASG replaces it."
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  dimensions         = { AutoScalingGroupName = var.autoscaling_group_name }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Game loop
#
# THE alarm. Everything else in this file describes the health of a component;
# this one describes whether the game is running.
# ---------------------------------------------------------------------------

# treat_missing_data = "breaching" is the entire point of this alarm, not a
# detail. It makes one alarm cover both failure modes:
#
#   * the loop is stalled  -> the metric climbs past the threshold
#   * the ticker is dead   -> no data points arrive at all
#
# With the CloudWatch default of "missing", a ticker that crashes stops
# publishing and the alarm sits at INSUFFICIENT_DATA forever -- silent, in
# exactly the situation it exists to catch. That is the same class of failure as
# the sub-minute pg_cron schedule this service was built to replace: a heartbeat
# that stops without complaining.
#
# Threshold: numbers are called every CALL_INTERVAL_MS (3.5s). 30 seconds is
# roughly eight missed calls -- unambiguous to a player, and far enough above
# normal jitter that a slow tick does not page anybody.
resource "aws_cloudwatch_metric_alarm" "game_loop_stalled" {
  alarm_name        = "${var.name_prefix}-game-loop-stalled"
  alarm_description = "No bingo number called for 30s, or the ticker has stopped publishing entirely. Players are watching a frozen board."

  namespace   = var.metric_namespace
  metric_name = "SecondsSinceLastNumberCalled"
  statistic   = "Maximum"

  # 60s periods over two of them: fast enough to matter, slow enough that a
  # single delayed publish does not page anyone.
  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 30

  dimensions         = { Environment = var.environment }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "breaching"

  tags = var.tags
}

# A tick that takes longer than its own interval means the loop cannot keep
# cadence: number calls drift and players notice before any component looks
# unhealthy. Warning-level -- it precedes the stall rather than being one.
resource "aws_cloudwatch_metric_alarm" "tick_duration" {
  alarm_name        = "${var.name_prefix}-tick-duration-high"
  alarm_description = "game_tick() is taking longer than its 1s interval. The loop is falling behind."

  namespace           = var.metric_namespace
  metric_name         = "TickDuration"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 800

  dimensions    = { Environment = var.environment }
  alarm_actions = [aws_sns_topic.alerts.arn]

  # Unlike the stall alarm, absent data here is not a failure -- the stall alarm
  # already owns "the ticker is gone", and duplicating that would page twice for
  # one incident.
  treat_missing_data = "notBreaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ec2_cpu_credits" {
  alarm_name          = "${var.name_prefix}-ec2-cpu-credits-low"
  alarm_description   = "Instance CPU credit balance low. t4g.small is about to throttle to baseline."
  namespace           = "AWS/EC2"
  metric_name         = "CPUCreditBalance"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 30

  dimensions         = { AutoScalingGroupName = var.autoscaling_group_name }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# The manual money queues
#
# THE GAP THESE CLOSE, found on a player's screen rather than in a dashboard:
#
#   Deposit · Telebirr    0.10    pending    1d ago
#
# against a zero play balance, while the deposit form promised "usually within a
# few minutes". Nothing was broken -- the queue, the RLS policy and the route all
# worked. There was no signal that anything was in it.
#
# Same shape as the game-loop alarm above, and the same reasoning db/20-post/002
# gives for that one: a health signal exists so an alarm on it turns a support
# ticket into a page. A deposit pending overnight is a support ticket that should
# have been a page.
#
# The ticker publishes these from queue_health() once a minute; see
# db/20-post/015 for why that is a separate function from game_tick().
# ---------------------------------------------------------------------------

# treat_missing_data = "notBreaching", UNLIKE the game-loop alarm.
#
# That one uses "breaching" so a dead ticker alarms, and it is right to: a
# stopped heartbeat and a frozen game are the same outage. Here, absent data
# means the ticker is down -- which game_loop_stalled already pages for. Using
# "breaching" would page twice for one incident and make this alarm noisy in
# exactly the situation it has nothing to say about.
resource "aws_cloudwatch_metric_alarm" "pending_deposits_stale" {
  alarm_name        = "${var.name_prefix}-deposits-waiting-too-long"
  alarm_description = "A deposit claim has been unapproved for ${var.pending_deposit_alarm_minutes} minutes. That player cannot join a game, and the form told them a few minutes."

  namespace   = var.metric_namespace
  metric_name = "OldestPendingDepositMinutes"
  statistic   = "Maximum"

  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.pending_deposit_alarm_minutes

  dimensions         = { Environment = var.environment }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Is the site actually reachable?
#
# THE BLIND SPOT THIS CLOSES. Every other alarm in this file reads a metric
# published from inside AWS, about a component. None of them can tell you that a
# player cannot open the app, because none of them looks from outside.
#
# The concrete way that happens, and it is not hypothetical -- it is the
# documented recovery path:
#
#   the ASG replaces the instance (AMI bump, status check failure, refresh)
#   the new instance boots and runs user_data.sh.tftpl
#   `aws ec2 associate-address` fails -- a permission change, a throttle, a
#     transient API error
#   user_data ECHOES AN ERROR and carries on
#
# Now: EC2 status check passes, ECS reports every service running, the ticker
# holds its advisory lock and keeps calling numbers, SecondsSinceLastNumberCalled
# stays at 3.5, the game-loop alarm reads OK -- and Cloudflare is still
# resolving to an Elastic IP attached to nothing. Total outage, every alarm
# green. The same shape covers an expired Cloudflare Origin Certificate, a Caddy
# config that fails to load, and a Cloudflare zone setting changed by hand.
#
# THIS DOES NOT PUT ANY DNS IN AWS, and the resource name says otherwise loudly
# enough to be worth answering here.
#
# Cloudflare is the authoritative DNS for this domain and stays that way. A
# Route 53 HEALTH CHECK is a standalone uptime monitor that happens to be sold
# under the Route 53 brand, because its original purpose was DNS failover --
# "stop answering with this IP when it stops responding". Used without a record
# pointing at it, which is how it is used here, it is only a prober and a
# CloudWatch metric. There is no aws_route53_zone and no aws_route53_record
# anywhere in this repository; grep for `route53` and this file is the only hit.
#
# What the probers actually do is resolve api.<domain> through PUBLIC DNS -- so
# through Cloudflare, exactly as a player's phone does -- and request /healthz
# over HTTPS from about fifteen locations. The path under test is therefore
# Cloudflare DNS -> Cloudflare edge -> the origin lock -> Caddy, which is the
# whole player path rather than the last hop of it.
#
# WHY NOT CLOUDFLARE'S OWN HEALTH CHECKS, which would be the obvious answer:
# they are a Pro-and-above feature and this zone is on the free plan. The rate
# limiting block in modules/cloudflare records the same ceiling from the other
# side -- one rule, one permitted period, both entitlement-gated.
#
# The remaining alternatives are worse. A CloudWatch Synthetics canary at a
# five-minute cadence is roughly $10/mo, a third of this environment's entire
# budget for a check that answers one boolean. An external service like
# UptimeRobot is free but delivers to its own inbox, so the one alarm that says
# "players cannot reach the game" would be the one alarm that does not arrive
# where every other alarm arrives.
#
# /healthz is served by Caddy itself and touches no upstream, so this stays a
# statement about reachability and does not double as a database check.
# Readiness has its own endpoint.
#
# FIRST THING TO DO AFTER APPLYING THIS: confirm the check reports Healthy.
#
#   aws route53 get-health-check-status --health-check-id <id>
#
# The zone runs Browser Integrity Check and a rate-limiting rule, and the Route
# 53 checkers arrive from many addresses at once with a non-browser user agent.
# If Cloudflare decides to challenge or block them, this alarm becomes a
# permanent false positive -- which is worse than not having it, because an
# alarm that is always red is an alarm nobody reads. If that happens, add a
# Cloudflare skip rule for the checker ranges rather than deleting this.
# ---------------------------------------------------------------------------
resource "aws_route53_health_check" "api" {
  count = var.enable_external_health_check ? 1 : 0

  type = "HTTPS"
  fqdn = "api.${var.domain_name}"
  port = 443

  resource_path = var.health_check_path

  # 30s interval, three consecutive failures: roughly 90 seconds to alarm. Fast
  # enough to matter on a real-money game, slow enough that one slow edge
  # response does not page anybody.
  request_interval  = 30
  failure_threshold = 3

  # Latency measurement is a paid add-on and answers a question this check is
  # not being asked. Reachability only.
  measure_latency = false

  # Off for the same reason. The check either completes or it does not.
  enable_sni = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-api-reachable" })
}

# us-east-1 ONLY, and this module is already there.
#
# Route 53 publishes HealthCheckStatus exclusively to us-east-1 regardless of
# where anything else lives. An alarm on it created in another region finds no
# metric and sits at INSUFFICIENT_DATA forever -- silent, in exactly the
# situation it exists to catch.
resource "aws_cloudwatch_metric_alarm" "api_unreachable" {
  count = var.enable_external_health_check ? 1 : 0

  alarm_name        = "${var.name_prefix}-api-unreachable"
  alarm_description = "api.${var.domain_name}${var.health_check_path} is not answering from outside AWS. Players cannot reach the game, whatever the component alarms say."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  statistic   = "Minimum"

  period              = 60
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "LessThanThreshold"
  threshold           = 1

  dimensions = { HealthCheckId = aws_route53_health_check.api[0].id }

  alarm_actions = [aws_sns_topic.alerts.arn]

  # Recovery is as worth knowing as failure here: this is the alarm that says
  # the outage is over.
  ok_actions = [aws_sns_topic.alerts.arn]

  # Same reasoning as the game-loop alarm. A monitor that stops reporting is
  # indistinguishable, from where the player stands, from the thing it monitors
  # being down -- and treating absent data as fine is how a check goes quiet in
  # the one situation it was bought for.
  treat_missing_data = "breaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Is the origin SERVING, or merely answering?
#
# THE GAP THIS CLOSES, which was most of the stack.
#
# aws_route53_health_check.api above requests var.health_check_path, and
# services/caddy/Caddyfile answers that path itself with `respond "ok" 200`. That
# is the right design for a reachability check -- it stays meaningful while an
# upstream is down, which is exactly when you want it. But it was the ONLY thing
# looking from outside, and there are no ECS RunningTaskCount alarms, so:
#
#   ticker stops       game_loop_stalled fires
#   caddy/instance     api_unreachable and ec2_status_check fire
#   postgrest stops    nothing. The SPA's whole data path is dead, silently.
#   realtime stops     nothing. No live game updates, silently.
#   functions stops    nothing. No login, no deposits, no withdrawals, silently.
#
# Three of five containers could stop and no alarm anywhere would say so. The
# first anyone would know is a player complaining, which for a real-money game is
# not a monitoring strategy.
#
# ONE CHECK, NOT THREE. A Route 53 check against a non-AWS endpoint is $0.50/mo,
# so covering the upstreams separately is $1.50/mo against a $32 budget --
# affordable, and it buys less. The endpoint probes all three from inside the box
# and names the failure in its body and in the log, so the page already says what
# broke. See services/functions/src/upstreams.js.
#
# COUNT-GATED SEPARATELY from the reachability check, because it has a
# precondition that one does not: the functions image must actually serve
# /readyz/deep. See the variable.
# ---------------------------------------------------------------------------
resource "aws_route53_health_check" "origin_deep" {
  count = var.enable_deep_health_check ? 1 : 0

  type = "HTTPS"
  fqdn = "api.${var.domain_name}"
  port = 443

  resource_path = var.deep_health_check_path

  # SLOWER AND MORE FORGIVING than the reachability check, on purpose. That one
  # answers from Caddy and either works or does not; this one depends on three
  # upstreams, one of which (realtime) runs Ecto migrations on boot and is
  # legitimately unavailable for a few seconds after a deploy. Three failures at
  # 30s is ~90 seconds, which outlasts a normal restart and still catches a
  # container that is not coming back.
  request_interval  = 30
  failure_threshold = 3

  measure_latency = false
  enable_sni      = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-origin-serving" })
}

# us-east-1 only, for the same reason as api_unreachable above: Route 53
# publishes HealthCheckStatus exclusively there, and an alarm on it created
# elsewhere sits at INSUFFICIENT_DATA forever.
resource "aws_cloudwatch_metric_alarm" "origin_degraded" {
  count = var.enable_deep_health_check ? 1 : 0

  alarm_name        = "${var.name_prefix}-origin-degraded"
  alarm_description = "api.${var.domain_name}${var.deep_health_check_path} is not returning 200: one of postgrest, realtime or the database is down. The site may still answer while being unusable. The response body and the functions log name which one."

  namespace   = "AWS/Route53"
  metric_name = "HealthCheckStatus"
  statistic   = "Minimum"

  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1

  dimensions = { HealthCheckId = aws_route53_health_check.origin_deep[0].id }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  # Same reasoning as every other alarm here: a monitor that stops reporting is
  # indistinguishable, from where the player stands, from the thing it monitors
  # being down.
  treat_missing_data = "breaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Does the ledger still agree with the balances?
#
# db/20-post/019 journals every change to deposited_balance and won_balance with
# an append-only entry, and reconcile_balances() compares the sum of a player's
# entries against their actual balance. The ticker publishes the number of
# disagreeing accounts every five minutes.
#
# ZERO IS THE INVARIANT. A non-zero value means either a balance moved without
# being journalled -- a code path that bypassed the trigger, or a manual UPDATE
# with triggers disabled -- or an entry was altered after the fact. There is no
# benign cause, so the threshold is 0 rather than a tolerance.
#
# THIS IS THE POINT OF HAVING A LEDGER. A journal nobody compares against the
# balances is a table that grows; the comparison is the control. Publishing it is
# what turns "we could reconcile if we looked" into "we would be told".
#
# The alarm carries a count. WHICH accounts is in the ticker's log, written at
# error alongside the metric, because that is what somebody starting to
# investigate actually needs.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "balance_drift" {
  count = var.enable_balance_drift_alarm ? 1 : 0

  alarm_name        = "${var.name_prefix}-balance-ledger-drift"
  alarm_description = "One or more player balances disagree with their own journal in balance_entries. Money moved without being recorded, or a record was changed. Query: SELECT reconcile_balances(); and check the ticker log for balance_ledger_drift."

  namespace   = var.metric_namespace
  metric_name = "BalanceDriftAccounts"
  statistic   = "Maximum"

  # The ticker publishes every five minutes, so a 600s period always contains a
  # datapoint. Two of them before alarming, because a reconciliation that runs
  # in the middle of a multi-statement money movement could in principle observe
  # an intermediate state -- twice in a row is not that.
  period              = 600
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  dimensions    = { Environment = var.environment }
  alarm_actions = [aws_sns_topic.alerts.arn]

  # Recovery matters here: drift that resolves itself is worth knowing about,
  # because it means something is racing rather than broken.
  ok_actions = [aws_sns_topic.alerts.arn]

  treat_missing_data = "breaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Did last night's backup happen?
#
# THE CASE A FAILURE NOTIFICATION CANNOT COVER.
#
# db-backup.yml publishes to this topic when it fails, which handles the dump
# erroring. It cannot handle the workflow being disabled, the schedule being
# edited out, the repository being archived, or GitHub simply not firing a cron.
# In every one of those, nothing fails, so nothing reports, and the backups stop
# silently -- discovered during a restore, which is the worst possible moment.
#
# So the workflow publishes a HEARTBEAT on success and this alarms on its
# ABSENCE. Identical reasoning to game_loop_stalled above, and the same failure
# shape: a heartbeat that stops without complaining.
#
# treat_missing_data = "breaching" is therefore the entire alarm, not a detail.
#
# 30 HOURS, against a 24-hour schedule. Wide enough that a slow runner, a queued
# job or an hour of GitHub trouble does not page anybody; narrow enough that two
# consecutive missed nights cannot pass unnoticed.
#
# WHY THIS MATTERS MORE HERE THAN IT WOULD ELSEWHERE: RDS point-in-time recovery
# is capped at ONE DAY by the account plan, so these dumps are the only recovery
# point older than 24 hours that exists. If they stop, the system silently
# returns to a state where a problem found on Friday about Monday is
# unrecoverable -- and nothing else would say so.
#
# This is the twelfth alarm, $0.10/mo past the CloudWatch free tier. Named
# rather than absorbed, because the point of the header comment is that nothing
# here is billed by accident.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# How long this account has left
#
# THE ONE ALARM NO BUDGET CAN REPLACE.
#
# Every budget in this project watches SPEND. On a FREE account plan spend is
# zero -- credits absorb the bill before it reaches Cost Explorer, measured at
# -0.0000001/day while the credit balance falls by about $1.30/day. So all of
# them sit at OK right up to the moment the account is suspended.
#
# And suspension is what happens: a FREE plan that exhausts its credits does not
# start billing, it SUSPENDS RESOURCES. For a real-money game that is the game
# stopping, with player balances inside a suspended database.
#
# TWO DEADLINES, and the nearer one is not the one written in the docs:
#
#   plan expiry   2027-01-14, fixed
#   credits       ~$150 at ~$1.30/day, so roughly 115 days
#
# The credits bind first. Alarming on the balance rather than the date is what
# makes that visible.
#
# THRESHOLD is a month of runway at the observed burn, which is enough time to
# upgrade the plan deliberately rather than in a hurry. Raise it if the burn
# rises -- the number is a duration expressed in dollars, not a dollar opinion.
#
# treat_missing_data = "breaching": the metric is published once a day by
# .github/workflows/free-tier-runway.yml, so its absence means that check has
# stopped running -- and a runway alarm that goes quiet is indistinguishable
# from one that has nothing to report. Same reasoning as game_loop_stalled.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "free_tier_runway" {
  count = var.enable_free_tier_alarm ? 1 : 0

  alarm_name        = "${var.name_prefix}-free-tier-credits-low"
  alarm_description = "Free-tier credits below $${var.free_tier_credit_floor}. On a FREE plan, exhausting credits SUSPENDS resources -- it does not bill. No spend budget can see this, because credits absorb the cost before Cost Explorer does."

  namespace   = var.metric_namespace
  metric_name = "FreeTierCreditsRemaining"
  statistic   = "Minimum"

  # Published daily, so a day-long period with one datapoint to alarm.
  period              = 86400
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "LessThanThreshold"
  threshold           = var.free_tier_credit_floor

  dimensions = { Environment = var.environment }

  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "breaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "backup_missing" {
  count = var.enable_backup_alarm ? 1 : 0

  alarm_name        = "${var.name_prefix}-backup-did-not-run"
  alarm_description = "No successful database backup in ${var.backup_alarm_hours}h. RDS PITR is capped at 1 day on this account, so these dumps are the ONLY recovery point older than 24 hours."

  namespace   = var.metric_namespace
  metric_name = "HoursSinceLastBackup"
  statistic   = "Maximum"

  # One period of the full window: the metric is published once a day, so a
  # shorter period would spend most of its life with no datapoint and alarm on
  # ordinary quiet rather than on a missed backup.
  period              = var.backup_alarm_hours * 3600
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0

  dimensions = { Environment = var.environment }

  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "breaching"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "pending_withdrawals_stale" {
  alarm_name        = "${var.name_prefix}-withdrawals-waiting-too-long"
  alarm_description = "A withdrawal has been unpaid for ${var.pending_withdrawal_alarm_minutes} minutes. This is money owed to a player."

  namespace   = var.metric_namespace
  metric_name = "OldestPendingWithdrawalMinutes"
  statistic   = "Maximum"

  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.pending_withdrawal_alarm_minutes

  dimensions         = { Environment = var.environment }
  alarm_actions      = [aws_sns_topic.alerts.arn]
  ok_actions         = [aws_sns_topic.alerts.arn]
  treat_missing_data = "notBreaching"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# The inside of the instance
#
# Basic EC2 monitoring reports CPU, network and disk I/O -- all from the
# hypervisor, none from inside the guest. Memory and filesystem usage are not
# available to AWS at all without something in the instance publishing them, and
# modules/ecs deliberately keeps detailed monitoring off to avoid the charge.
#
# The result was a five-container box with no memory or disk signal. An OOM kill
# surfaced only as whichever container-specific alarm happened to notice it, and
# a filling root volume would have surfaced as the container runtime failing to
# pull an image mid-deploy.
#
# user_data publishes both every five minutes with the AWS CLI it already
# installs. See the variables for why that rather than the CloudWatch agent.
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "host_memory" {
  count = var.enable_host_metric_alarms ? 1 : 0

  alarm_name        = "${var.name_prefix}-host-memory-high"
  alarm_description = "Host memory above ${var.memory_alarm_threshold_percent}%. The instance runs five containers with a 2 GiB swapfile, so this precedes an OOM kill rather than reporting one -- Realtime's BEAM VM is the usual cause."

  namespace   = var.metric_namespace
  metric_name = "MemoryUsedPercent"
  statistic   = "Average"

  # Published every 5 minutes, so a 300s period holds exactly one datapoint.
  # Three of them before alarming: a join spike is allowed to be brief.
  period              = 300
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.memory_alarm_threshold_percent

  dimensions    = { Environment = var.environment }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  # NOT breaching, unlike the game-loop and backup alarms, and the difference is
  # deliberate. Those watch heartbeats where silence IS the failure. This watches
  # a level, and its publisher stopping means the instance is gone -- which
  # ec2_status_check and api_unreachable already cover, from two directions. A
  # third alarm for the same event is noise, and noise is how alarms get muted.
  treat_missing_data = "missing"

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "host_disk" {
  count = var.enable_host_metric_alarms ? 1 : 0

  alarm_name        = "${var.name_prefix}-host-disk-high"
  alarm_description = "Root volume above ${var.disk_alarm_threshold_percent}%. It holds container images and the swapfile; when it fills, image pulls fail and a deploy breaks. `docker image prune` on the instance via SSM Session Manager is the usual fix."

  namespace   = var.metric_namespace
  metric_name = "DiskUsedPercent"
  statistic   = "Maximum"

  # Two periods, not three. Disk usage does not spike and recover the way memory
  # does -- if it is high twice running it is high.
  period              = 300
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.disk_alarm_threshold_percent

  dimensions    = { Environment = var.environment }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  treat_missing_data = "missing"

  tags = var.tags
}
