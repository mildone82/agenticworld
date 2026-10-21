#!/usr/bin/env bash
# Decision-table tests for the AWS gate. No cluster and no credentials required.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GATE="$SCRIPT_DIR/aws-gate.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

status_of() {
  python3 - "$1/aws-gate.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["status"])
PY
}

field_of() {
  python3 - "$1/aws-gate.json" "$2" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
value = doc[sys.argv[2]]
print("true" if value is True else "false" if value is False else value)
PY
}

run_gate() {
  local dir=$1
  shift
  set +e
  env -u VERIFY_RUN_ID -u VERIFY_EVIDENCE_DIR \
    VERIFY_EVIDENCE_DIR="$dir" \
    "$@" \
    bash "$GATE"
  local code=$?
  set -e
  printf '%s' "$code"
}

assert_status() {
  local dir=$1
  local want=$2
  local got
  got=$(status_of "$dir")
  [ "$got" = "$want" ] || fail "$dir status $got != $want"
  grep -q "^status: $want$" "$dir/aws-gate.log" || fail "$dir log missing status: $want"
  if [ "$want" != "PASS" ]; then
    if grep -q '"status": "PASS"' "$dir/aws-gate.json"; then
      fail "$dir json claimed PASS"
    fi
    [ "$(field_of "$dir" live_cluster_proven)" = "false" ] || fail "$dir proved a cluster"
  fi
}

# 1. Documentation-only diff skips before any validator.
dir=$(mktemp -d)
code=$(run_gate "$dir" VERIFY_AWS_GATE_TEST_SEAMS=1 VERIFY_CHANGED_FILES="$(printf '%s\n' docs/AGENT_SHARE_PROGRESS.md README.md docs/assets/banner.jpg)")
[ "$code" = "0" ] || fail "doc-only exit $code"
assert_status "$dir" SKIP
[ ! -s "$dir/aws-static.log" ] || fail "doc-only ran static validation"
rm -rf "$dir"

# 2. Without test seams, injected commands and a markdown file list are ignored.
#    A PASS is allowed only when the real cluster probe proved it.
dir=$(mktemp -d)
code=$(run_gate "$dir" VERIFY_CHANGED_FILES="$(printf '%s\n' docs/only.md)" VERIFY_STATIC_CMD=true VERIFY_AWS_CREDS_CMD=true VERIFY_CLUSTER_CMD=true VERIFY_LIVE_CMD=true)
[ "$(field_of "$dir" seams)" = "false" ] || fail "seams leaked"
case "$(status_of "$dir")" in
  PASS)
    [ "$code" = "0" ] || fail "proven PASS exit $code"
    [ "$(field_of "$dir" live_cluster_proven)" = "true" ] || fail "unproven PASS"
    ;;
  BLOCKED)
    [ "$code" = "2" ] || fail "BLOCKED exit $code"
    assert_status "$dir" BLOCKED
    ;;
  FAIL)
    [ "$code" = "1" ] || fail "FAIL exit $code"
    assert_status "$dir" FAIL
    ;;
  *) fail "unexpected unseamed status" ;;
esac
rm -rf "$dir"

# 3. Static failure is FAIL even when creds and a cluster are pretended.
dir=$(mktemp -d)
code=$(run_gate "$dir" \
  VERIFY_AWS_GATE_TEST_SEAMS=1 \
  VERIFY_CHANGED_FILES="deploy/aws/helm/values.yaml" \
  VERIFY_STATIC_CMD=false \
  VERIFY_AWS_CREDS_CMD=true \
  VERIFY_CLUSTER_CMD=true)
[ "$code" = "1" ] || fail "static fail exit $code"
assert_status "$dir" FAIL
rm -rf "$dir"

# 4. Static success without creds is BLOCKED, never PASS.
dir=$(mktemp -d)
code=$(run_gate "$dir" \
  VERIFY_AWS_GATE_TEST_SEAMS=1 \
  VERIFY_CHANGED_FILES="deploy/aws/helm/values.yaml" \
  VERIFY_STATIC_CMD=true \
  VERIFY_AWS_CREDS_CMD=false \
  VERIFY_CLUSTER_CMD=true)
[ "$code" = "2" ] || fail "no-creds exit $code"
assert_status "$dir" BLOCKED
grep -q 'not a live deployment PASS' "$dir/aws-gate.json" || fail "blocked reason missing"
rm -rf "$dir"

# 5. Static success, creds, cluster, live failure is FAIL.
dir=$(mktemp -d)
code=$(run_gate "$dir" \
  VERIFY_AWS_GATE_TEST_SEAMS=1 \
  VERIFY_CHANGED_FILES="deploy/aws/helm/values.yaml" \
  VERIFY_STATIC_CMD=true \
  VERIFY_AWS_CREDS_CMD=true \
  VERIFY_CLUSTER_CMD=true \
  VERIFY_LIVE_CMD=false)
[ "$code" = "1" ] || fail "live fail exit $code"
assert_status "$dir" FAIL
rm -rf "$dir"

# 6. Decision-table pass under seams is not a live cluster proof.
dir=$(mktemp -d)
code=$(run_gate "$dir" \
  VERIFY_AWS_GATE_TEST_SEAMS=1 \
  VERIFY_CHANGED_FILES="deploy/aws/helm/values.yaml" \
  VERIFY_STATIC_CMD=true \
  VERIFY_AWS_CREDS_CMD=true \
  VERIFY_CLUSTER_CMD=true \
  VERIFY_LIVE_CMD=true)
[ "$code" = "0" ] || fail "seam pass exit $code"
assert_status "$dir" PASS
[ "$(field_of "$dir" seams)" = "true" ] || fail "expected seams"
[ "$(field_of "$dir" live_cluster_proven)" = "false" ] || fail "seam pass proved a cluster"
rm -rf "$dir"

# 7. Empty injected diff is not documentation-only.
dir=$(mktemp -d)
code=$(run_gate "$dir" \
  VERIFY_AWS_GATE_TEST_SEAMS=1 \
  VERIFY_CHANGED_FILES="" \
  VERIFY_STATIC_CMD=true \
  VERIFY_AWS_CREDS_CMD=false \
  VERIFY_CLUSTER_CMD=false)
[ "$code" = "2" ] || fail "empty diff exit $code"
assert_status "$dir" BLOCKED
rm -rf "$dir"

echo "aws-gate decision table passed"
