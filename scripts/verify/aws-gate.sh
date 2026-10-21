#!/usr/bin/env bash
# AWS deployment gate.
#
# Reads scripts/validate-deployment.sh (Helm/Terraform artifact checks) and a
# live cluster probe. The status written to aws-gate.json is the only verdict:
#
#   PASS     static script passed AND AWS credentials work AND a cluster
#            answers AND pods in the target namespace are Running/Completed.
#            seams must be false and live_cluster_proven true.
#   FAIL     the static script ran and failed, or the live probe ran and failed.
#   BLOCKED  no usable credentials and/or no reachable cluster, or the static
#            script could not be executed. Never a pass. Static success alone
#            cannot set PASS.
#   SKIP     every path in the diff is documentation (markdown, docs/, LICENSE,
#            NOTICE). Reason lists those paths. An empty diff is not a skip.
#
# Exit codes: PASS/SKIP 0, FAIL 1, BLOCKED 2.
# VERIFY_AWS_GATE_TEST_SEAMS=1 is reserved for aws-gate.test.sh. It is not a
# live cluster result.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

EVIDENCE=$(verify_evidence_dir)
LOG="$EVIDENCE/aws-gate.log"
JSON="$EVIDENCE/aws-gate.json"
STATIC_LOG="$EVIDENCE/aws-static.log"
LIVE_LOG="$EVIDENCE/aws-live.log"
: >"$LOG"

note() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

SEAMS=false
if [ "${VERIFY_AWS_GATE_TEST_SEAMS:-}" = "1" ]; then
  SEAMS=true
  note "test seams enabled; this result is not a live cluster result"
fi

CHANGED_FILE="$EVIDENCE/aws-changed-files.txt"
verify_list_changed_files >"$CHANGED_FILE" || true

DOC_ONLY=false
if verify_diff_is_doc_only <"$CHANGED_FILE"; then
  DOC_ONLY=true
fi

STATIC="not_run"
STATIC_REASON=""
AWS_CREDENTIALS="absent"
CLUSTER="absent"
LIVE="not_run"
STATUS="BLOCKED"
REASON=""
PROVEN=false
NS=${MULTICA_NAMESPACE:-multica}

run_static() {
  : >"$STATIC_LOG"
  if [ "$SEAMS" = true ] && [ -n "${VERIFY_STATIC_CMD+x}" ]; then
    if bash -c "$VERIFY_STATIC_CMD" >>"$STATIC_LOG" 2>&1; then
      STATIC="PASS"
      STATIC_REASON="seam static command exited 0"
    else
      STATIC="FAIL"
      STATIC_REASON="seam static command failed"
    fi
    return 0
  fi
  local missing=""
  command -v helm >/dev/null 2>&1 || missing+=" helm"
  command -v terraform >/dev/null 2>&1 || missing+=" terraform"
  command -v python3 >/dev/null 2>&1 || missing+=" python3"
  if [ -n "$missing" ]; then
    STATIC="BLOCKED"
    STATIC_REASON="missing tools:${missing}; scripts/validate-deployment.sh was not run"
    printf '%s\n' "$STATIC_REASON" >"$STATIC_LOG"
    return 0
  fi
  if bash "$VERIFY_REPO_ROOT/scripts/validate-deployment.sh" >"$STATIC_LOG" 2>&1; then
    STATIC="PASS"
    STATIC_REASON="scripts/validate-deployment.sh exited 0 (chart and terraform artifacts only)"
  else
    STATIC="FAIL"
    STATIC_REASON="scripts/validate-deployment.sh exited non-zero"
  fi
}

probe_creds() {
  if [ "$SEAMS" = true ] && [ -n "${VERIFY_AWS_CREDS_CMD+x}" ]; then
    if bash -c "$VERIFY_AWS_CREDS_CMD" >/dev/null 2>&1; then
      AWS_CREDENTIALS="present"
    fi
    return 0
  fi
  if ! command -v aws >/dev/null 2>&1; then
    return 0
  fi
  # Short timeouts so a missing IMDS endpoint cannot hang the gate.
  # stdout is discarded so account identifiers are not copied into the log.
  if AWS_PAGER="" aws sts get-caller-identity --output text \
    --cli-connect-timeout 3 --cli-read-timeout 8 >/dev/null 2>&1; then
    AWS_CREDENTIALS="present"
  fi
}

probe_cluster() {
  if [ "$SEAMS" = true ] && [ -n "${VERIFY_CLUSTER_CMD+x}" ]; then
    if bash -c "$VERIFY_CLUSTER_CMD" >/dev/null 2>&1; then
      CLUSTER="present"
    fi
    return 0
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  if ! kubectl config current-context >/dev/null 2>&1; then
    return 0
  fi
  if kubectl --request-timeout=8s get --raw=/readyz >/dev/null 2>&1; then
    CLUSTER="present"
  fi
}

live_pods_ok() {
  local bad=0
  local line=""
  local status_field=""
  if [ ! -s "$LIVE_LOG" ]; then
    return 1
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    status_field=$(printf '%s\n' "$line" | awk '{print $3}')
    case "$status_field" in
      Running|Completed|Succeeded) ;;
      *) bad=1 ;;
    esac
  done <"$LIVE_LOG"
  [ "$bad" -eq 0 ]
}

probe_live() {
  : >"$LIVE_LOG"
  if [ "$SEAMS" = true ] && [ -n "${VERIFY_LIVE_CMD+x}" ]; then
    if bash -c "$VERIFY_LIVE_CMD" >"$LIVE_LOG" 2>&1; then
      LIVE="pass"
    else
      LIVE="fail"
    fi
    return 0
  fi
  if kubectl --request-timeout=15s -n "$NS" get pods --no-headers >"$LIVE_LOG" 2>>"$LOG"; then
    if live_pods_ok; then
      LIVE="pass"
    else
      LIVE="fail"
    fi
  else
    LIVE="fail"
  fi
}

if [ "$DOC_ONLY" = true ]; then
  STATUS="SKIP"
  REASON="documentation-only diff; scripts/validate-deployment.sh not run"
  STATIC="not_run"
  STATIC_REASON="$REASON"
  note "status: SKIP"
  note "reason: $REASON"
else
  run_static
  probe_creds
  probe_cluster
  note "static_validation=$STATIC"
  note "aws_credentials=$AWS_CREDENTIALS"
  note "cluster=$CLUSTER"
  if [ "$STATIC" = "FAIL" ]; then
    STATUS="FAIL"
    REASON="$STATIC_REASON"
  elif [ "$AWS_CREDENTIALS" != "present" ] || [ "$CLUSTER" != "present" ]; then
    STATUS="BLOCKED"
    REASON="no usable AWS credentials and/or no reachable Kubernetes cluster; static_validation=${STATIC} is not a live deployment PASS"
  elif [ "$STATIC" != "PASS" ]; then
    STATUS="BLOCKED"
    REASON="credentials and cluster are present but scripts/validate-deployment.sh did not pass (static_validation=${STATIC}); refusing to report PASS"
  else
    probe_live
    note "live_probe=$LIVE namespace=$NS"
    if [ "$LIVE" = "pass" ]; then
      if [ "$SEAMS" = true ]; then
        STATUS="PASS"
        PROVEN=false
        REASON="decision-table live probe succeeded under test seams; not a live cluster PASS"
      else
        STATUS="PASS"
        PROVEN=true
        REASON="scripts/validate-deployment.sh passed and namespace ${NS} pods are Running or Completed"
      fi
    else
      STATUS="FAIL"
      REASON="live probe failed for namespace ${NS}"
    fi
  fi
  note "status: $STATUS"
  note "reason: $REASON"
fi

export GATE_STATUS="$STATUS"
export GATE_REASON="$REASON"
export GATE_STATIC="$STATIC"
export GATE_STATIC_REASON="$STATIC_REASON"
export GATE_AWS="$AWS_CREDENTIALS"
export GATE_CLUSTER="$CLUSTER"
export GATE_LIVE="$LIVE"
export GATE_DOC_ONLY="$DOC_ONLY"
export GATE_SEAMS="$SEAMS"
export GATE_PROVEN="$PROVEN"
export GATE_NS="$NS"
export GATE_CHANGED="$CHANGED_FILE"
export GATE_JSON="$JSON"

python3 - <<'PY'
import json, os
changed = []
path = os.environ["GATE_CHANGED"]
if os.path.exists(path):
    with open(path) as fh:
        changed = [line.strip() for line in fh if line.strip()]
def flag(name):
    return os.environ[name] == "true"
doc = {
    "status": os.environ["GATE_STATUS"],
    "reason": os.environ["GATE_REASON"],
    "static_validation": os.environ["GATE_STATIC"],
    "static_reason": os.environ["GATE_STATIC_REASON"],
    "aws_credentials": os.environ["GATE_AWS"],
    "cluster": os.environ["GATE_CLUSTER"],
    "live_probe": os.environ["GATE_LIVE"],
    "namespace": os.environ["GATE_NS"],
    "doc_only": flag("GATE_DOC_ONLY"),
    "seams": flag("GATE_SEAMS"),
    "live_cluster_proven": flag("GATE_PROVEN"),
    "script": "scripts/validate-deployment.sh",
    "changed_files": changed[:200],
}
with open(os.environ["GATE_JSON"], "w") as fh:
    json.dump(doc, fh, indent=2)
    fh.write("\n")
PY

case "$STATUS" in
  PASS|SKIP) exit 0 ;;
  FAIL) exit 1 ;;
  BLOCKED) exit 2 ;;
  *) exit 1 ;;
esac
