#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# canary-validator.sh
#
# Post-deploy validation script invoked during a CodeDeploy blue/green
# deployment. Runs against the green task set via the ALB test listener
# while real users are still served by the blue task set, then signals
# CodeDeploy with PutLifecycleEventHookExecutionStatus.
#
# How it is wired:
#   1. terraform/target-account/codedeploy.tf provisions the CodeDeploy app
#      and deployment group.
#   2. pipelines/appspec.yml lists "CodeDeployHook_AfterAllowTestTraffic" as
#      the Lambda hook for the AfterAllowTestTraffic event.
#   3. That Lambda invokes this script (packaged in the deploy CodeBuild
#      project image) and forwards its exit code as the hook status.
#
# Exit codes:
#   0   — all probes passed; deployment is allowed to shift prod traffic
#   1   — a probe failed; deployment is rolled back to the blue task set
#   2   — argument / environment misconfiguration (treated as failure)
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Constants ------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
DEFAULT_TIMEOUT_SECONDS=10
DEFAULT_ATTEMPTS=5
DEFAULT_RETRY_DELAY=6
DEFAULT_LATENCY_BUDGET_MS=1500

# --- Colour helpers (silently no-op when stdout is not a tty) -------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  BOLD="$(tput bold)"
  RESET="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# --- Logging --------------------------------------------------------------
log()   { printf "%s[%s]%s %s\n" "${BOLD}" "$(date -u +%FT%TZ)" "${RESET}" "$*"; }
ok()    { printf "%s[ OK ]%s %s\n" "${GREEN}" "${RESET}" "$*"; }
warn()  { printf "%s[WARN]%s %s\n" "${YELLOW}" "${RESET}" "$*" >&2; }
fail()  { printf "%s[FAIL]%s %s\n" "${RED}" "${RESET}" "$*" >&2; }

# --- Usage ----------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} [options]

  --base-url URL            Base URL of the test listener (required).
                            Example: https://green.test.example.invalid:8443
  --health-path PATH        Health-check endpoint (default: /healthz).
  --smoke-path PATH         Smoke endpoint validated for body content
                            (default: /api/v1/status).
  --expected-version STR    String the smoke endpoint must echo back. Useful
                            for confirming the task set is actually the
                            new build (default: unset — skipped).
  --attempts N              Number of attempts per probe (default: ${DEFAULT_ATTEMPTS}).
  --retry-delay SECONDS     Seconds between retries (default: ${DEFAULT_RETRY_DELAY}).
  --timeout SECONDS         Per-request timeout (default: ${DEFAULT_TIMEOUT_SECONDS}).
  --latency-ms MS           Max acceptable p95 latency over the warmup loop
                            (default: ${DEFAULT_LATENCY_BUDGET_MS}).
  --deployment-id ID        CodeDeploy deployment id. When set together with
                            --hook-execution-id, the script also signals the
                            CodeDeploy lifecycle event.
  --hook-execution-id ID    Lifecycle event hook execution id (from the
                            invoking Lambda's event payload).
  --region REGION           AWS region for CodeDeploy signalling. Falls
                            back to AWS_REGION / AWS_DEFAULT_REGION.
  -h, --help                Show this help and exit.
USAGE
}

# --- Defaults -------------------------------------------------------------
BASE_URL=""
HEALTH_PATH="/healthz"
SMOKE_PATH="/api/v1/status"
EXPECTED_VERSION=""
ATTEMPTS="${DEFAULT_ATTEMPTS}"
RETRY_DELAY="${DEFAULT_RETRY_DELAY}"
TIMEOUT="${DEFAULT_TIMEOUT_SECONDS}"
LATENCY_BUDGET_MS="${DEFAULT_LATENCY_BUDGET_MS}"
DEPLOYMENT_ID=""
HOOK_EXECUTION_ID=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"

# --- Arg parsing ----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --base-url)            BASE_URL="$2"; shift 2 ;;
    --health-path)         HEALTH_PATH="$2"; shift 2 ;;
    --smoke-path)          SMOKE_PATH="$2"; shift 2 ;;
    --expected-version)    EXPECTED_VERSION="$2"; shift 2 ;;
    --attempts)            ATTEMPTS="$2"; shift 2 ;;
    --retry-delay)         RETRY_DELAY="$2"; shift 2 ;;
    --timeout)             TIMEOUT="$2"; shift 2 ;;
    --latency-ms)          LATENCY_BUDGET_MS="$2"; shift 2 ;;
    --deployment-id)       DEPLOYMENT_ID="$2"; shift 2 ;;
    --hook-execution-id)   HOOK_EXECUTION_ID="$2"; shift 2 ;;
    --region)              REGION="$2"; shift 2 ;;
    -h|--help)             usage; exit 0 ;;
    *)                     fail "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

if [ -z "${BASE_URL}" ]; then
  fail "--base-url is required"
  usage
  exit 2
fi

# --- Validate dependencies ------------------------------------------------
for tool in curl awk; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail "Required tool missing on PATH: ${tool}"
    exit 2
  fi
done

# --- Signal CodeDeploy ----------------------------------------------------
# Idempotent: only signals when both deployment-id and hook-execution-id
# are provided (i.e. running inside the CodeDeploy Lambda hook). When
# invoked manually (e.g. by the rollback test script) signalling is
# skipped and the exit code alone communicates pass/fail.
signal_codedeploy() {
  local status="$1"
  if [ -z "${DEPLOYMENT_ID}" ] || [ -z "${HOOK_EXECUTION_ID}" ]; then
    log "Skipping CodeDeploy signal (deployment-id and hook-execution-id not provided)"
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    warn "aws cli not on PATH; cannot signal CodeDeploy"
    return 0
  fi

  local region_arg=()
  if [ -n "${REGION}" ]; then
    region_arg=(--region "${REGION}")
  fi

  log "Signalling CodeDeploy: status=${status}"
  if aws "${region_arg[@]}" deploy put-lifecycle-event-hook-execution-status \
      --deployment-id "${DEPLOYMENT_ID}" \
      --lifecycle-event-hook-execution-id "${HOOK_EXECUTION_ID}" \
      --status "${status}" >/dev/null 2>&1; then
    ok "CodeDeploy lifecycle hook status set to ${status}"
  else
    warn "Failed to signal CodeDeploy (status=${status}); deployment will time out"
  fi
}

# --- Cleanup / trap -------------------------------------------------------
EXIT_STATUS=1
cleanup() {
  local rc=$?
  if [ "${rc}" -eq 0 ]; then
    signal_codedeploy "Succeeded"
  else
    signal_codedeploy "Failed"
  fi
  exit "${rc}"
}
trap cleanup EXIT

# --- Probes ---------------------------------------------------------------
# All probes use curl with explicit timeout, hard-fail on non-2xx, and a
# bounded retry loop. Latency is measured by %{time_total} so we can enforce
# an SLO budget across the warmup window.

probe_http_status() {
  local url="$1"
  local attempt=1
  while [ "${attempt}" -le "${ATTEMPTS}" ]; do
    log "GET ${url} (attempt ${attempt}/${ATTEMPTS})"
    if curl --silent --show-error --fail \
            --max-time "${TIMEOUT}" \
            --connect-timeout 5 \
            --output /dev/null \
            "${url}"; then
      ok "200 OK from ${url}"
      return 0
    fi
    warn "${url} did not return 2xx"
    attempt=$((attempt + 1))
    [ "${attempt}" -le "${ATTEMPTS}" ] && sleep "${RETRY_DELAY}"
  done
  fail "exhausted ${ATTEMPTS} attempts against ${url}"
  return 1
}

probe_body_contains() {
  local url="$1"
  local needle="$2"
  local body
  log "Verifying ${url} body contains '${needle}'"
  body="$(curl --silent --show-error --fail \
               --max-time "${TIMEOUT}" \
               --connect-timeout 5 \
               "${url}")" || { fail "Could not fetch ${url}"; return 1; }
  if printf "%s" "${body}" | grep -qF "${needle}"; then
    ok "body contains '${needle}'"
    return 0
  fi
  fail "body did NOT contain '${needle}'"
  printf "response:\n%s\n" "${body}" >&2
  return 1
}

probe_latency_budget() {
  local url="$1"
  local samples=10
  local total_ms=0
  local max_ms=0
  local sample_ms
  log "Latency sampling ${url} (${samples} samples, budget ${LATENCY_BUDGET_MS}ms)"
  for i in $(seq 1 "${samples}"); do
    sample_ms="$(curl --silent --show-error --fail \
                       --max-time "${TIMEOUT}" \
                       --connect-timeout 5 \
                       --output /dev/null \
                       --write-out '%{time_total}' \
                       "${url}" 2>/dev/null \
                 | awk '{ printf "%d", $1 * 1000 }')" \
      || { fail "Sample ${i} failed entirely"; return 1; }
    total_ms=$((total_ms + sample_ms))
    if [ "${sample_ms}" -gt "${max_ms}" ]; then
      max_ms="${sample_ms}"
    fi
  done
  local avg_ms=$((total_ms / samples))
  log "latency: avg=${avg_ms}ms peak=${max_ms}ms"
  if [ "${max_ms}" -gt "${LATENCY_BUDGET_MS}" ]; then
    fail "peak latency ${max_ms}ms exceeds budget ${LATENCY_BUDGET_MS}ms"
    return 1
  fi
  ok "latency within budget"
  return 0
}

# --- Run validation suite -------------------------------------------------
HEALTH_URL="${BASE_URL%/}${HEALTH_PATH}"
SMOKE_URL="${BASE_URL%/}${SMOKE_PATH}"

log "Canary validation starting against ${BASE_URL}"

# 1. Health check must return 200.
probe_http_status "${HEALTH_URL}"

# 2. Smoke endpoint must respond and (optionally) carry the expected build tag.
probe_http_status "${SMOKE_URL}"
if [ -n "${EXPECTED_VERSION}" ]; then
  probe_body_contains "${SMOKE_URL}" "${EXPECTED_VERSION}"
fi

# 3. Latency budget — guards against a green build that is functional but
#    significantly slower than the blue baseline.
probe_latency_budget "${HEALTH_URL}"

ok "All probes passed — green task set is healthy"
EXIT_STATUS=0
exit "${EXIT_STATUS}"
