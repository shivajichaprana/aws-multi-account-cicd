#!/usr/bin/env bash
#
# test-rollback.sh
#
# Drives a deliberately broken CodeDeploy blue/green deployment against a
# target environment, then asserts that CodeDeploy's alarm-driven auto-
# rollback kicks in and the original task set is restored.
#
# Usage:
#   ./test-rollback.sh \
#       --application <codedeploy-app> \
#       --deployment-group <deployment-group> \
#       --cluster <ecs-cluster> \
#       --service <ecs-service> \
#       --bad-image <image-uri> \
#       [--region <aws-region>] \
#       [--timeout-seconds <secs>] \
#       [--keep-on-failure]
#
# The script never sends real traffic; it simply asks CodeDeploy to deploy
# a known-bad task definition (one whose container image either does not
# exist or fails its health check) and watches CloudWatch + CodeDeploy for
# the rollback signal.
#
# Exit codes:
#   0   rollback succeeded as expected
#   1   bad usage / pre-flight failure
#   2   deployment completed successfully when we expected a rollback
#   3   deployment exceeded the timeout
#   4   AWS API call failed mid-test
#

set -euo pipefail

# --------------------------------------------------------------------------
# Pretty-print helpers. tput goes through stderr because the caller may
# pipe the script's stdout into a logger.
# --------------------------------------------------------------------------

if [[ -t 2 ]] && command -v tput >/dev/null 2>&1; then
  COLOR_RED="$(tput setaf 1 || true)"
  COLOR_GREEN="$(tput setaf 2 || true)"
  COLOR_YELLOW="$(tput setaf 3 || true)"
  COLOR_BLUE="$(tput setaf 4 || true)"
  COLOR_BOLD="$(tput bold || true)"
  COLOR_RESET="$(tput sgr0 || true)"
else
  COLOR_RED=""
  COLOR_GREEN=""
  COLOR_YELLOW=""
  COLOR_BLUE=""
  COLOR_BOLD=""
  COLOR_RESET=""
fi

log()    { printf '%s[%(%H:%M:%S)T] %s%s\n' "$COLOR_BLUE"   -1 "$*" "$COLOR_RESET" >&2; }
ok()     { printf '%s[%(%H:%M:%S)T] OK   %s%s\n' "$COLOR_GREEN"  -1 "$*" "$COLOR_RESET" >&2; }
warn()   { printf '%s[%(%H:%M:%S)T] WARN %s%s\n' "$COLOR_YELLOW" -1 "$*" "$COLOR_RESET" >&2; }
fatal()  { printf '%s[%(%H:%M:%S)T] FAIL %s%s\n' "$COLOR_RED"    -1 "$*" "$COLOR_RESET" >&2; exit "${2:-1}"; }
bold()   { printf '%s%s%s\n' "$COLOR_BOLD" "$*" "$COLOR_RESET" >&2; }

# --------------------------------------------------------------------------
# Defaults + arg parsing
# --------------------------------------------------------------------------

APPLICATION=""
DEPLOYMENT_GROUP=""
CLUSTER=""
SERVICE=""
BAD_IMAGE=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
TIMEOUT_SECONDS=1200
KEEP_ON_FAILURE=0

usage() {
  cat >&2 <<USAGE
Usage: $(basename "$0") [options]

Required:
  --application       CodeDeploy application name
  --deployment-group  CodeDeploy deployment group name
  --cluster           ECS cluster name
  --service           ECS service name
  --bad-image         Container image URI guaranteed to fail health checks
                      (e.g. <accountid>.dkr.ecr.<region>.amazonaws.com/app:rollback-canary)

Optional:
  --region            AWS region (default: \$AWS_REGION or us-east-1)
  --timeout-seconds   How long to wait for the deployment to terminate (default: 1200)
  --keep-on-failure   Do not clean up the bad revision if the test fails
  -h, --help          Show this message

Environment:
  AWS_REGION / AWS_DEFAULT_REGION are honoured when --region is omitted.
  The script assumes the caller has already exported AWS credentials with
  enough scope to call ecs:RegisterTaskDefinition + codedeploy:CreateDeployment
  + codedeploy:GetDeployment + codedeploy:StopDeployment.

Exit codes:
  0  rollback succeeded
  1  bad usage / pre-flight failure
  2  deployment completed successfully when we expected a rollback
  3  deployment timed out
  4  AWS API call failed mid-test
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --application)       APPLICATION="$2"; shift 2 ;;
    --deployment-group)  DEPLOYMENT_GROUP="$2"; shift 2 ;;
    --cluster)           CLUSTER="$2"; shift 2 ;;
    --service)           SERVICE="$2"; shift 2 ;;
    --bad-image)         BAD_IMAGE="$2"; shift 2 ;;
    --region)            REGION="$2"; shift 2 ;;
    --timeout-seconds)   TIMEOUT_SECONDS="$2"; shift 2 ;;
    --keep-on-failure)   KEEP_ON_FAILURE=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   usage; fatal "unknown argument: $1" 1 ;;
  esac
done

for v in APPLICATION DEPLOYMENT_GROUP CLUSTER SERVICE BAD_IMAGE; do
  if [[ -z "${!v}" ]]; then
    usage
    fatal "--${v,,} is required" 1
  fi
done

command -v aws  >/dev/null 2>&1 || fatal "aws CLI not on PATH" 1
command -v jq   >/dev/null 2>&1 || fatal "jq not on PATH"      1

# --------------------------------------------------------------------------
# Workspace for intermediate JSON. Cleaned on exit unless --keep-on-failure
# is set AND the test failed.
# --------------------------------------------------------------------------

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/test-rollback.XXXXXX")"
TEST_RESULT=99
DEPLOYMENT_ID=""

cleanup() {
  if [[ "$KEEP_ON_FAILURE" -eq 1 && "$TEST_RESULT" -ne 0 ]]; then
    warn "leaving workspace $WORKDIR in place for inspection (--keep-on-failure)"
    return
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --------------------------------------------------------------------------
# Pre-flight: confirm the deployment group exists and the service is stable.
# --------------------------------------------------------------------------

bold "==> Pre-flight checks"
log "looking up CodeDeploy deployment group $APPLICATION/$DEPLOYMENT_GROUP in $REGION"
aws deploy get-deployment-group \
    --region "$REGION" \
    --application-name "$APPLICATION" \
    --current-deployment-group-name "$DEPLOYMENT_GROUP" \
    >"$WORKDIR/deployment-group.json" \
  || fatal "failed to describe deployment group; check credentials and names" 4

ALARM_NAMES=$(jq -r '.deploymentGroupInfo.alarmConfiguration.alarms[]?.name // empty' "$WORKDIR/deployment-group.json")
if [[ -z "$ALARM_NAMES" ]]; then
  fatal "deployment group has no alarm_configuration; auto-rollback would never trigger. Run \`terraform apply\` first." 1
fi
log "alarms wired to deployment group:"
while IFS= read -r name; do log "  - $name"; done <<< "$ALARM_NAMES"

log "looking up ECS service $CLUSTER/$SERVICE"
aws ecs describe-services \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    >"$WORKDIR/service.json" \
  || fatal "failed to describe ECS service" 4

CURRENT_TD_ARN=$(jq -r '.services[0].taskDefinition' "$WORKDIR/service.json")
if [[ -z "$CURRENT_TD_ARN" || "$CURRENT_TD_ARN" == "null" ]]; then
  fatal "could not determine current task definition for $CLUSTER/$SERVICE" 4
fi
ok "current task definition: $CURRENT_TD_ARN"

# --------------------------------------------------------------------------
# Build a deliberately-bad task definition: same family, but the container
# image is swapped for the supplied $BAD_IMAGE which is known to fail.
# --------------------------------------------------------------------------

bold "==> Building deliberately-broken task definition"
aws ecs describe-task-definition \
    --region "$REGION" \
    --task-definition "$CURRENT_TD_ARN" \
    >"$WORKDIR/current-td.json" \
  || fatal "failed to describe current task definition" 4

jq --arg img "$BAD_IMAGE" '
  .taskDefinition
  | del(
      .taskDefinitionArn, .revision, .status, .requiresAttributes,
      .compatibilities, .registeredAt, .registeredBy, .deregisteredAt
    )
  | .containerDefinitions |= map(.image = $img)
' "$WORKDIR/current-td.json" > "$WORKDIR/bad-td.json"

REGISTER_OUT="$WORKDIR/register-out.json"
aws ecs register-task-definition \
    --region "$REGION" \
    --cli-input-json "file://$WORKDIR/bad-td.json" \
    >"$REGISTER_OUT" \
  || fatal "failed to register bad task definition" 4
BAD_TD_ARN=$(jq -r '.taskDefinition.taskDefinitionArn' "$REGISTER_OUT")
ok "bad task definition registered: $BAD_TD_ARN"

# --------------------------------------------------------------------------
# Build an AppSpec for the bad deployment and kick it off.
# --------------------------------------------------------------------------

bold "==> Triggering bad deployment"
APPSPEC=$(jq -n --arg td "$BAD_TD_ARN" '{
  version: "0.0",
  Resources: [{
    TargetService: {
      Type: "AWS::ECS::Service",
      Properties: {
        TaskDefinition: $td,
        LoadBalancerInfo: { ContainerName: "app", ContainerPort: 8080 }
      }
    }
  }]
}')

REVISION=$(jq -n --arg appspec "$APPSPEC" '{
  revisionType: "AppSpecContent",
  appSpecContent: { content: $appspec }
}')

CREATE_OUT="$WORKDIR/create-deployment.json"
aws deploy create-deployment \
    --region "$REGION" \
    --application-name "$APPLICATION" \
    --deployment-group-name "$DEPLOYMENT_GROUP" \
    --description "test-rollback.sh deliberate bad deploy at $(date -u +%FT%TZ)" \
    --revision "$REVISION" \
    >"$CREATE_OUT" \
  || fatal "failed to create deployment" 4

DEPLOYMENT_ID=$(jq -r '.deploymentId' "$CREATE_OUT")
ok "deployment id: $DEPLOYMENT_ID"

# --------------------------------------------------------------------------
# Poll the deployment until it terminates or we hit the timeout.
# --------------------------------------------------------------------------

bold "==> Watching for auto-rollback (timeout ${TIMEOUT_SECONDS}s)"
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))
STATUS=""
ROLLBACK_INFO=""
while :; do
  if (( $(date +%s) > DEADLINE )); then
    TEST_RESULT=3
    warn "deployment $DEPLOYMENT_ID did not terminate within ${TIMEOUT_SECONDS}s, attempting to stop it"
    aws deploy stop-deployment \
        --region "$REGION" \
        --deployment-id "$DEPLOYMENT_ID" \
        --auto-rollback-enabled \
        >/dev/null \
      || warn "stop-deployment call failed; you may need to stop it manually"
    fatal "test timed out" 3
  fi

  aws deploy get-deployment \
      --region "$REGION" \
      --deployment-id "$DEPLOYMENT_ID" \
      >"$WORKDIR/poll.json" \
    || { warn "get-deployment polling call failed, retrying"; sleep 10; continue; }

  STATUS=$(jq -r '.deploymentInfo.status' "$WORKDIR/poll.json")
  ROLLBACK_INFO=$(jq -r '.deploymentInfo.rollbackInfo.rollbackTriggeringDeploymentId // ""' "$WORKDIR/poll.json")
  log "status=$STATUS rollback_triggering=${ROLLBACK_INFO:-none}"

  case "$STATUS" in
    Stopped|Failed)
      ROLLBACK_REASON=$(jq -r '.deploymentInfo.rollbackInfo.rollbackMessage // .deploymentInfo.errorInformation.message // "no detail"' "$WORKDIR/poll.json")
      ok "deployment terminated with status=$STATUS"
      log "rollback reason: $ROLLBACK_REASON"
      TEST_RESULT=0
      break
      ;;
    Succeeded)
      warn "deployment SUCCEEDED — that means the supposedly-bad image worked, which is unexpected"
      TEST_RESULT=2
      break
      ;;
    Created|Queued|InProgress|Baking|Ready)
      sleep 15
      ;;
    *)
      sleep 15
      ;;
  esac
done

# --------------------------------------------------------------------------
# Post-conditions: confirm the live service was reverted to the original
# task definition.
# --------------------------------------------------------------------------

bold "==> Verifying live service was restored"
aws ecs describe-services \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --services "$SERVICE" \
    >"$WORKDIR/post-service.json" \
  || fatal "post-test describe-services failed" 4

ROLLED_BACK_TD=$(jq -r '.services[0].taskDefinition' "$WORKDIR/post-service.json")
if [[ "$ROLLED_BACK_TD" == "$CURRENT_TD_ARN" ]]; then
  ok "live service is back on $ROLLED_BACK_TD"
else
  warn "live service task definition is $ROLLED_BACK_TD (was $CURRENT_TD_ARN)"
  warn "this can be normal if CodeDeploy registered a recovery revision; verify in the console"
fi

if [[ "$TEST_RESULT" -eq 0 ]]; then
  bold "${COLOR_GREEN}rollback test PASSED${COLOR_RESET}"
elif [[ "$TEST_RESULT" -eq 2 ]]; then
  bold "${COLOR_RED}rollback test FAILED: deployment succeeded${COLOR_RESET}"
fi

exit "$TEST_RESULT"
