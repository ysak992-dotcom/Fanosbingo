#!/usr/bin/env bash
#
# Prove an alarm reaches a human, and say which ones cannot.
#
# scripts/verify-detections.sh establishes the principle for metric filters: "a
# detector that has never seen a positive is not a detector." Nothing did the
# equivalent for ALARMS, and the failure modes are worse because every one of
# them is silent:
#
#   * The metric never publishes. The alarm sits at OK forever, because
#     treat_missing_data says not to worry, and OK is indistinguishable from
#     healthy. This is what prompted the script -- a deposit alarm was created,
#     a deposit had been pending for a day, and no email arrived.
#
#   * The SNS subscription is unconfirmed. Terraform reports the subscription as
#     created while it sits in "pending confirmation"; modules/monitoring warns
#     about this in a comment and nothing checked it.
#
#   * The alarm has no actions at all, or points at a topic nobody is on.
#
# Usage:
#   ./scripts/verify-alarms.sh dev              # report only, changes nothing
#   ./scripts/verify-alarms.sh account          # the account-wide detections
#   ./scripts/verify-alarms.sh dev --fire NAME  # force one alarm, prove delivery
#
# TWO KINDS OF METRIC, AND THE DIFFERENCE DECIDES WHAT "NO DATA" MEANS.
#
#   CONTINUOUS  SecondsSinceLastNumberCalled, OldestPendingDepositMinutes.
#               The ticker publishes these every tick regardless of state, so
#               ABSENCE MEANS BROKEN -- the alarm is unarmed and will sit at OK
#               forever.
#
#   EVENT-DRIVEN  UnexpectedKmsSign, RootAccountUsage. A CloudTrail metric
#               filter emits these only when something matches, so ABSENCE IS
#               THE GOAL. Demanding datapoints here would fail permanently and
#               train everyone to ignore this script -- which is the failure
#               mode it exists to prevent, applied to itself.
#
# So the datapoint assertion runs for environments and not for `account`. What
# DOES apply to both is the delivery path: an encrypted topic whose key policy
# omits cloudwatch.amazonaws.com drops every notification silently, and that is
# a property of the topic, not of how often the metric fires.
#
# --fire uses SetAlarmState, which triggers the alarm ACTION and therefore the
# whole path: alarm -> SNS -> subscription -> inbox. CloudWatch re-evaluates from
# real data on the next period, so the forced state is transient. It fires the
# OK transition afterwards too, so you get both emails and can see the pair.

set -euo pipefail

TARGET="${1:-dev}"

if [ "$TARGET" = "account" ]; then
  # The account root's alarms are named `fanosbingo-<thing>` with no environment
  # segment, so this prefix also matches every environment alarm. They are
  # filtered out below rather than by the prefix, because "fanosbingo-" is the
  # only prefix that catches these two.
  PREFIX="fanosbingo-"
  NAMESPACE="FanosBingo/Security"
  DIMENSIONED=0
  EXPECT_DATA=0
else
  PREFIX="fanosbingo-${TARGET}"
  NAMESPACE="FanosBingo/${PREFIX}"
  DIMENSIONED=1
  EXPECT_DATA=1
fi
ENVIRONMENT="$TARGET"

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BOLD=$'\033[1m'; NC=$'\033[0m'
pass() { echo "  ${GREEN}PASS${NC} $*"; }
warn() { echo "  ${YELLOW}WARN${NC} $*"; }
fail() { echo "  ${RED}FAIL${NC} $*"; failures=$((failures + 1)); }
failures=0

command -v aws >/dev/null || { echo "aws CLI not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# --fire: force one alarm through a full transition
# ---------------------------------------------------------------------------
if [ "${2:-}" = "--fire" ]; then
  FIRE_TARGET="${3:?usage: verify-alarms.sh <env> --fire <alarm-name>}"

  if [ "$TARGET" = "account" ]; then
    echo "${RED}Refusing:${NC} --fire is not available for the account detections." >&2
    echo "Those alarms mean 'somebody used root' or 'something unexpected signed a" >&2
    echo "withdrawal'. Firing one deliberately puts a false positive in the record of" >&2
    echo "exactly the events you would later be reading back. The deploy role's IAM is" >&2
    echo "scoped to \${PREFIX}-* for the same reason." >&2
    exit 1
  fi

  case "$FIRE_TARGET" in
    "${PREFIX}"-*) ;;
    *) echo "${RED}Refusing:${NC} '$FIRE_TARGET' is not a ${PREFIX} alarm." >&2; exit 1 ;;
  esac

  echo "${BOLD}Forcing ${FIRE_TARGET} through ALARM -> OK${NC}"
  echo "This sends real notifications. CloudWatch re-evaluates from real data on"
  echo "the next period, so nothing is left misreporting."
  echo

  aws cloudwatch set-alarm-state --alarm-name "$FIRE_TARGET" --state-value ALARM \
    --state-reason "Delivery test from scripts/verify-alarms.sh at $(date -u +%FT%TZ)"
  echo "  ${GREEN}sent${NC} ALARM"

  sleep 10

  aws cloudwatch set-alarm-state --alarm-name "$FIRE_TARGET" --state-value OK \
    --state-reason "Delivery test complete"
  echo "  ${GREEN}sent${NC} OK"

  echo
  echo "Expect TWO messages on EVERY confirmed channel: two emails, and two"
  echo "Telegram messages from the bot."
  echo
  echo "CHECK THE DEVICE, NOT THE CONSOLE. That is the whole point of this"
  echo "command. An SNS SMS subscription needs no confirmation click, so it"
  echo "reports active whether or not anything is delivered -- Terraform, the"
  echo "console and list-subscriptions all called the SMS channel healthy while"
  echo "every message was dropped, because the account is not enrolled in AWS"
  echo "End User Messaging. It was found by firing this and asking whether the"
  echo "handset rang."
  echo
  echo "If a channel is silent, the fault is its subscription or its delivery"
  echo "path, not the metric -- the metric is what this command bypassed."
  echo
  echo "Telegram silent but email fine?  The forwarder is a route on the"
  echo "functions container, so check its log for alert_forwarded /"
  echo "alert_forward_failed before suspecting SNS:"
  echo
  echo "  aws logs filter-log-events --log-group-name /ecs/${PREFIX} \\"
  echo "    --filter-pattern '\"alert_\"' --start-time \$(( (\$(date +%s) - 600) * 1000 ))"
  exit 0
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
echo
echo "${BOLD}Alarm delivery — ${PREFIX}${NC}"
echo

alarms_json="$(aws cloudwatch describe-alarms --alarm-name-prefix "$PREFIX" \
  --query 'MetricAlarms[].{name:AlarmName,state:StateValue,actions:AlarmActions,ns:Namespace,metric:MetricName,missing:TreatMissingData,period:Period,evals:EvaluationPeriods}' \
  --output json)"

# `fanosbingo-` matches the environment alarms too. Drop them, so `account`
# reports on the two account-wide detections and nothing else.
if [ "$TARGET" = "account" ]; then
  alarms_json="$(echo "$alarms_json" | python3 -c '
import json,re,sys
print(json.dumps([a for a in json.load(sys.stdin)
                  if not re.match(r"fanosbingo-(dev|prod)-", a["name"])]))')"
fi

count="$(echo "$alarms_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
echo "${BOLD}${count} alarm(s)${NC}"
echo

# Which SNS topics are actually deliverable? An unconfirmed subscription has a
# SubscriptionArn of the literal string "PendingConfirmation".
declare -A topic_ok
for topic in $(echo "$alarms_json" | python3 -c '
import json,sys
print("\n".join(sorted({a for x in json.load(sys.stdin) for a in (x["actions"] or [])})))'); do
  confirmed="$(aws sns list-subscriptions-by-topic --topic-arn "$topic" \
    --query 'length(Subscriptions[?SubscriptionArn!=`PendingConfirmation`])' --output text 2>/dev/null || echo 0)"
  pendingn="$(aws sns list-subscriptions-by-topic --topic-arn "$topic" \
    --query 'length(Subscriptions[?SubscriptionArn==`PendingConfirmation`])' --output text 2>/dev/null || echo 0)"
  topic_ok["$topic"]="$confirmed"
  short="${topic##*:}"
  if [ "$confirmed" -gt 0 ]; then
    pass "topic ${short}: ${confirmed} confirmed subscriber(s)$([ "$pendingn" -gt 0 ] && echo ", ${pendingn} still pending")"
  else
    fail "topic ${short}: NO confirmed subscribers. Alarms firing here reach nobody."
  fi

  # CAN CLOUDWATCH ACTUALLY ENCRYPT TO IT?
  #
  # The check this script shipped without, and the one that would have caught
  # the bug that motivated the script. An SNS topic encrypted with a CMK needs
  # that key's policy to admit cloudwatch.amazonaws.com, or the publish fails
  # and the notification is dropped -- with the alarm in ALARM, the subscription
  # confirmed, and the metric publishing. Every other signal says healthy.
  key="$(aws sns get-topic-attributes --topic-arn "$topic" \
    --query 'Attributes.KmsMasterKeyId' --output text 2>/dev/null || echo "None")"

  if [ "$key" = "None" ] || [ -z "$key" ]; then
    pass "topic ${short}: not encrypted, so no key policy to satisfy"
  else
    if aws kms get-key-policy --key-id "$key" --policy-name default \
         --query Policy --output text 2>/dev/null |
       python3 -c '
import json,sys
pol = json.load(sys.stdin)
ok = any(
    "cloudwatch.amazonaws.com" in json.dumps(st.get("Principal", {}))
    and st.get("Effect") == "Allow"
    for st in pol.get("Statement", [])
)
sys.exit(0 if ok else 1)'; then
      pass "topic ${short}: its CMK admits cloudwatch.amazonaws.com"
    else
      fail "topic ${short}: encrypted with ${key}, whose policy does NOT admit cloudwatch.amazonaws.com. Every notification is dropped silently -- alarm state, subscription and metric all still look correct."
    fi
  fi
done
echo

# Per alarm: does it have an action, and is its metric actually publishing?
#
# THE CHECK THAT MATTERS. An alarm at OK with no datapoints is not healthy, it
# is unarmed -- and with treat_missing_data=notBreaching it will never say so.
echo "$alarms_json" | python3 -c '
import json,sys
for a in json.load(sys.stdin):
    print("\t".join([a["name"], a["state"], str(len(a["actions"] or [])),
                     a["ns"] or "", a["metric"] or "", a["missing"] or "",
                     str(a.get("period") or 300), str(a.get("evals") or 1)]))' |
while IFS=$'\t' read -r name state nactions ns metric missing period evals; do
  echo "${BOLD}${name}${NC}  [${state}]"

  if [ "$nactions" -eq 0 ]; then
    fail "  no alarm actions - it can fire and tell nobody"
  fi

  if [ "$ns" = "$NAMESPACE" ] && [ "$EXPECT_DATA" -eq 0 ]; then
    # EVENT-DRIVEN. A CloudTrail metric filter emits only on a match, so no
    # datapoints is the goal rather than a fault. Asserting otherwise would fail
    # this check permanently and teach everyone to ignore it -- which is the
    # exact failure this script exists to prevent, turned on itself.
    #
    # What covers these instead is scripts/verify-detections.sh, which tests the
    # deployed filter PATTERNS against synthetic events. Delivery is covered by
    # the topic checks above, which apply to both kinds.
    pass "  ${metric}: event-driven, so no datapoints is correct. Pattern coverage is verify-detections.sh"

  elif [ "$ns" = "$NAMESPACE" ]; then
    # THE WINDOW IS THE ALARM'S OWN, NOT A FIXED TWO HOURS.
    #
    # This asked "any datapoints in the last 2h?" for every metric, which is
    # right only for one published more often than that. HoursSinceLastBackup
    # arrives once a night and FreeTierCreditsRemaining once a day, so both
    # reported "NO datapoints ... it is unarmed" about alarms that were armed
    # and correct -- their own evaluation windows are 30h and 24h.
    #
    # Measured on prod on 2026-08-11: both metrics had published three hours
    # earlier, and both were called unarmed.
    #
    # That is this script's own stated failure mode turned on itself. Its header
    # says a check that fails permanently teaches everyone to ignore it, and
    # verify.yml now runs weekly against prod -- so this would have produced two
    # standing FAILs forever, on the backup alarm and on the one alarm no budget
    # can replace.
    #
    # Period x EvaluationPeriods is exactly the span CloudWatch itself considers
    # before deciding a datapoint is missing, so asking over that span asks the
    # same question the alarm does. Floored at 2h so a fast metric still gets a
    # meaningful sample rather than a single period.
    span=$(( period * evals ))
    [ "$span" -lt 7200 ] && span=7200
    window_h=$(( (span + 3599) / 3600 ))
    since="$(date -u -d "@$(( $(date -u +%s) - span ))" +%FT%TZ)"

    points="$(aws cloudwatch get-metric-statistics \
      --namespace "$ns" --metric-name "$metric" \
      --dimensions Name=Environment,Value="$ENVIRONMENT" \
      --start-time "$since" \
      --end-time "$(date -u +%FT%TZ)" \
      --period 300 --statistics Maximum \
      --query 'length(Datapoints)' --output text 2>/dev/null || echo 0)"

    if [ "$points" -gt 0 ]; then
      latest="$(aws cloudwatch get-metric-statistics \
        --namespace "$ns" --metric-name "$metric" \
        --dimensions Name=Environment,Value="$ENVIRONMENT" \
        --start-time "$since" \
        --end-time "$(date -u +%FT%TZ)" \
        --period 300 --statistics Maximum \
        --query 'sort_by(Datapoints,&Timestamp)[-1].Maximum' --output text)"
      pass "  ${metric}: ${points} datapoint(s) in ${window_h}h, latest ${latest}"
    else
      # This is the silent one. Say exactly what it means.
      fail "  ${metric}: NO datapoints in ${window_h}h (the alarm's own evaluation span). treat_missing_data=${missing}, so this alarm cannot fire. It is not healthy, it is unarmed."
    fi
  fi
  echo
done

echo
if [ "$failures" -eq 0 ]; then
  echo "${GREEN}${BOLD}Every alarm has a confirmed recipient and a deliverable topic.${NC}"
  if [ "$TARGET" = "account" ]; then
    echo "Delivery here shares the audit key and the security topic; verify-detections.sh"
    echo "covers whether the filters still match."
  else
    echo "To prove delivery end to end:  $0 ${ENVIRONMENT} --fire ${PREFIX}-game-loop-stalled"
  fi
else
  echo "${RED}${BOLD}${failures} problem(s).${NC} An alarm that cannot fire is not coverage."
  exit 1
fi
