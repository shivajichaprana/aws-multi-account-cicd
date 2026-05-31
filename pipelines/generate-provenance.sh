#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# generate-provenance.sh
#
# Generates an in-toto attestation carrying SLSA Provenance v1.0
# (predicateType https://slsa.dev/provenance/v1) for one or more build
# artifacts, populated from the metadata CodeBuild exposes to every build.
#
# How it is wired:
#   1. pipelines/buildspec-build.yml produces the deploy bundle and a
#      build-metadata.json (gitCommit / imageTag / builtBy / builtAt).
#   2. A post_build step invokes this script with the artifact(s) to attest
#      and the build-metadata.json, e.g.:
#
#        pipelines/generate-provenance.sh \
#          --artifact "build-output/app.tar.gz" \
#          --metadata-file "build-output/build-metadata.json" \
#          --output "build-output/app.provenance.json"
#
#   3. The resulting statement is uploaded with the artifact and, when image
#      signing is configured (see aws-supply-chain-security), handed to
#      `cosign attest` as the predicate.
#
# The statement subject is the SHA-256 digest of each artifact, so consumers
# can verify "this provenance describes exactly this byte stream". The
# predicate records the builder identity, the resolved source commit, and the
# build invocation — the fields a SLSA verifier checks against a policy.
#
# Only POSIX tooling plus `jq` is required; it runs unchanged inside the
# CodeBuild standard image and on a developer laptop.
#
# Exit codes:
#   0  — provenance written successfully
#   1  — a runtime error (missing artifact, hashing failure, jq error)
#   2  — argument / dependency misconfiguration
# ---------------------------------------------------------------------------

set -euo pipefail

# --- Constants ------------------------------------------------------------
readonly SCRIPT_NAME="$(basename "$0")"
readonly STATEMENT_TYPE="https://in-toto.io/Statement/v1"
readonly SLSA_PREDICATE_TYPE="https://slsa.dev/provenance/v1"
readonly DEFAULT_BUILD_TYPE="https://aws.amazon.com/codebuild/buildspec/v1"

# --- Colour helpers (silently no-op when stdout is not a tty) -------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BOLD="$(tput bold)"; RESET="$(tput sgr0)"
else
  RED=""; GREEN=""; YELLOW=""; BOLD=""; RESET=""
fi

# --- Logging --------------------------------------------------------------
log()  { printf "%s[%s]%s %s\n" "${BOLD}" "$(date -u +%FT%TZ)" "${RESET}" "$*" >&2; }
ok()   { printf "%s[ OK ]%s %s\n" "${GREEN}" "${RESET}" "$*" >&2; }
warn() { printf "%s[WARN]%s %s\n" "${YELLOW}" "${RESET}" "$*" >&2; }
fail() { printf "%s[FAIL]%s %s\n" "${RED}" "${RESET}" "$*" >&2; }

# --- Usage ----------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: ${SCRIPT_NAME} --artifact PATH [--artifact PATH ...] --output FILE [options]

Generates an in-toto statement with a SLSA Provenance v1.0 predicate for the
given artifact(s), using CodeBuild environment metadata.

Required:
  --artifact PATH        File (or directory) to attest. Repeatable. When a
                         directory is given every regular file beneath it is
                         hashed and added as a separate subject.
  --output FILE          Where to write the attestation JSON.

Optional:
  --metadata-file FILE   build-metadata.json emitted by the build stage. When
                         present, gitCommit / builtAt are read from it as a
                         fallback for the CodeBuild environment variables.
  --builder-id URI       SLSA builder id. Defaults to the CodeBuild build ARN,
                         then to https://codebuild.<region>.amazonaws.com.
  --build-type URI       SLSA buildType. Default: ${DEFAULT_BUILD_TYPE}
  --source-uri URI       Source repository URI. Default: CODEBUILD_SOURCE_REPO_URL.
  --source-ref REF       Source ref/branch. Default: CODEBUILD_SOURCE_VERSION.
  --commit SHA           Resolved source commit. Default:
                         CODEBUILD_RESOLVED_SOURCE_VERSION.
  --print                Also echo the statement to stdout.
  -h, --help             Show this help and exit.

Examples:
  ${SCRIPT_NAME} --artifact build-output/app.tar.gz \\
    --metadata-file build-output/build-metadata.json \\
    --output build-output/app.provenance.json --print
USAGE
}

# --- Defaults -------------------------------------------------------------
ARTIFACTS=()
OUTPUT_FILE=""
METADATA_FILE=""
BUILDER_ID=""
BUILD_TYPE="${DEFAULT_BUILD_TYPE}"
SOURCE_URI=""
SOURCE_REF=""
COMMIT_SHA=""
PRINT_STATEMENT="false"

# --- Arg parsing ----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --artifact)       ARTIFACTS+=("$2"); shift 2 ;;
    --output)         OUTPUT_FILE="$2"; shift 2 ;;
    --metadata-file)  METADATA_FILE="$2"; shift 2 ;;
    --builder-id)     BUILDER_ID="$2"; shift 2 ;;
    --build-type)     BUILD_TYPE="$2"; shift 2 ;;
    --source-uri)     SOURCE_URI="$2"; shift 2 ;;
    --source-ref)     SOURCE_REF="$2"; shift 2 ;;
    --commit)         COMMIT_SHA="$2"; shift 2 ;;
    --print)          PRINT_STATEMENT="true"; shift ;;
    -h|--help)        usage; exit 0 ;;
    *)                fail "Unknown argument: $1"; usage; exit 2 ;;
  esac
done

# --- Dependency / argument validation -------------------------------------
if ! command -v jq >/dev/null 2>&1; then
  fail "Required tool missing on PATH: jq"
  exit 2
fi

if [ "${#ARTIFACTS[@]}" -eq 0 ]; then
  fail "at least one --artifact is required"
  usage
  exit 2
fi

if [ -z "${OUTPUT_FILE}" ]; then
  fail "--output is required"
  usage
  exit 2
fi

# --- Cleanup / trap -------------------------------------------------------
WORK_DIR="$(mktemp -d)"
cleanup() { rm -rf "${WORK_DIR}"; }
trap cleanup EXIT

# --- SHA-256 helper -------------------------------------------------------
# Emits the lowercase hex digest of the file passed as $1, using whichever of
# sha256sum / shasum is available.
sha256_of() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "${file}" | awk '{ print $1 }'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "${file}" | awk '{ print $1 }'
  else
    fail "neither sha256sum nor shasum found on PATH"
    return 1
  fi
}

# --- Expand artifacts (directories -> their files) ------------------------
resolved_artifacts=()
for entry in "${ARTIFACTS[@]}"; do
  if [ -d "${entry}" ]; then
    while IFS= read -r f; do
      resolved_artifacts+=("${f}")
    done < <(find "${entry}" -type f | sort)
  elif [ -f "${entry}" ]; then
    resolved_artifacts+=("${entry}")
  else
    fail "artifact not found: ${entry}"
    exit 1
  fi
done

if [ "${#resolved_artifacts[@]}" -eq 0 ]; then
  fail "no regular files resolved from the supplied --artifact paths"
  exit 1
fi

# --- Build the subject array ----------------------------------------------
# Each subject names the artifact (basename) and pins its sha256 digest.
subjects_file="${WORK_DIR}/subjects.json"
: > "${subjects_file}"
for art in "${resolved_artifacts[@]}"; do
  digest="$(sha256_of "${art}")"
  name="$(basename "${art}")"
  log "subject ${name} sha256:${digest}"
  jq -n --arg name "${name}" --arg digest "${digest}" \
    '{name: $name, digest: {sha256: $digest}}' >> "${subjects_file}"
done
subjects_json="$(jq -s '.' "${subjects_file}")"

# --- Resolve build metadata -----------------------------------------------
# Prefer explicit flags, then CodeBuild env vars, then the metadata file,
# then a sensible default. Keeps the script usable locally and in-pipeline.
metadata_commit=""
metadata_built_at=""
if [ -n "${METADATA_FILE}" ] && [ -f "${METADATA_FILE}" ]; then
  metadata_commit="$(jq -r '.gitCommit // empty' "${METADATA_FILE}" 2>/dev/null || true)"
  metadata_built_at="$(jq -r '.builtAt // empty' "${METADATA_FILE}" 2>/dev/null || true)"
fi

region="${AWS_REGION:-${AWS_DEFAULT_REGION:-unknown}}"
build_arn="${CODEBUILD_BUILD_ARN:-}"
build_id="${CODEBUILD_BUILD_ID:-local}"
build_number="${CODEBUILD_BUILD_NUMBER:-0}"
build_image="${CODEBUILD_BUILD_IMAGE:-unknown}"
initiator="${CODEBUILD_INITIATOR:-unknown}"

COMMIT_SHA="${COMMIT_SHA:-${CODEBUILD_RESOLVED_SOURCE_VERSION:-${metadata_commit}}}"
SOURCE_URI="${SOURCE_URI:-${CODEBUILD_SOURCE_REPO_URL:-unknown}}"
SOURCE_REF="${SOURCE_REF:-${CODEBUILD_SOURCE_VERSION:-unknown}}"

if [ -z "${BUILDER_ID}" ]; then
  if [ -n "${build_arn}" ]; then
    BUILDER_ID="${build_arn}"
  else
    BUILDER_ID="https://codebuild.${region}.amazonaws.com"
  fi
fi

# started/finished timestamps — finished is "now"; started falls back to the
# build-metadata builtAt, otherwise also now.
finished_on="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
started_on="${metadata_built_at:-${finished_on}}"

# A resolvedDependency describing the source the build consumed.
if [ -n "${COMMIT_SHA}" ]; then
  resolved_deps_json="$(jq -n \
    --arg uri "git+${SOURCE_URI}@${SOURCE_REF}" \
    --arg commit "${COMMIT_SHA}" \
    '[{uri: $uri, digest: {gitCommit: $commit}}]')"
else
  resolved_deps_json='[]'
fi

# --- Assemble the in-toto statement ---------------------------------------
statement_json="$(jq -n \
  --arg stmt_type "${STATEMENT_TYPE}" \
  --arg pred_type "${SLSA_PREDICATE_TYPE}" \
  --argjson subjects "${subjects_json}" \
  --arg build_type "${BUILD_TYPE}" \
  --arg builder_id "${BUILDER_ID}" \
  --arg source_uri "${SOURCE_URI}" \
  --arg source_ref "${SOURCE_REF}" \
  --arg build_arn "${build_arn}" \
  --arg build_id "${build_id}" \
  --arg build_number "${build_number}" \
  --arg build_image "${build_image}" \
  --arg initiator "${initiator}" \
  --arg region "${region}" \
  --arg started_on "${started_on}" \
  --arg finished_on "${finished_on}" \
  --argjson resolved_deps "${resolved_deps_json}" \
  '{
    _type: $stmt_type,
    subject: $subjects,
    predicateType: $pred_type,
    predicate: {
      buildDefinition: {
        buildType: $build_type,
        externalParameters: {
          source: { uri: $source_uri, ref: $source_ref },
          buildspec: "pipelines/buildspec-build.yml"
        },
        internalParameters: {
          buildImage: $build_image,
          region: $region,
          buildNumber: ($build_number | tonumber? // 0)
        },
        resolvedDependencies: $resolved_deps
      },
      runDetails: {
        builder: {
          id: $builder_id,
          builderDependencies: []
        },
        metadata: {
          invocationId: (if $build_arn == "" then $build_id else $build_arn end),
          startedOn: $started_on,
          finishedOn: $finished_on
        },
        byproducts: [
          { name: "initiator", content: $initiator }
        ]
      }
    }
  }')"

# --- Write output ---------------------------------------------------------
output_dir="$(dirname "${OUTPUT_FILE}")"
mkdir -p "${output_dir}"
printf '%s\n' "${statement_json}" > "${OUTPUT_FILE}"

# Self-check: the file we just wrote must be valid JSON.
if ! jq -e . "${OUTPUT_FILE}" >/dev/null 2>&1; then
  fail "generated provenance is not valid JSON: ${OUTPUT_FILE}"
  exit 1
fi

ok "wrote SLSA provenance for ${#resolved_artifacts[@]} subject(s) to ${OUTPUT_FILE}"
log "predicateType=${SLSA_PREDICATE_TYPE} builder=${BUILDER_ID}"

if [ "${PRINT_STATEMENT}" = "true" ]; then
  cat "${OUTPUT_FILE}"
fi
