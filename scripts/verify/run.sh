#!/usr/bin/env bash
# One local pass: script tests, CLI launch, doctor, check, one drive, AWS gate, cleanup.
# Evidence stays in evidence/runs/<run-id>/. Scratch under /tmp is removed.
# Exit 0 when doctor, check, and the cli-version drive succeed and the AWS gate
# is PASS, SKIP, or BLOCKED. Exit 1 when check or drive fails or the gate is FAIL.
set -euo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib.sh"

export VERIFY_RUN_ID="${VERIFY_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
export VERIFY_EVIDENCE_DIR="$VERIFY_REPO_ROOT/evidence/runs/$VERIFY_RUN_ID"
mkdir -p "$VERIFY_EVIDENCE_DIR"
printf '%s\n' "$VERIFY_RUN_ID" >"$VERIFY_REPO_ROOT/evidence/current-run"

cleaned=0
cleanup_run() {
  if [ "$cleaned" -eq 0 ]; then
    cleaned=1
    bash "$SCRIPT_DIR/cleanup.sh" || true
  fi
}
trap cleanup_run EXIT

bash "$SCRIPT_DIR/launch.test.sh"
bash "$SCRIPT_DIR/aws-gate.test.sh"
bash "$SCRIPT_DIR/launch.sh"
bash "$SCRIPT_DIR/doctor.sh"

set +e
bash "$SCRIPT_DIR/check.sh"
check_code=$?
bash "$SCRIPT_DIR/drive.sh" cli-version
drive_code=$?
bash "$SCRIPT_DIR/aws-gate.sh"
aws_code=$?
set -e

cleanup_run

for required in launch.env launch.log doctor.txt check.log check-status.txt aws-gate.json aws-gate.log cleanup.log drive/cli-version.json drive/cli-version.meta.txt; do
  if [ ! -s "$VERIFY_EVIDENCE_DIR/$required" ]; then
    echo "missing evidence file: $required" >&2
    exit 1
  fi
done

if [ -d "${VERIFY_SCRATCH:-/tmp/verify-agenticworld-$VERIFY_RUN_ID}" ]; then
  echo "scratch survived cleanup" >&2
  exit 1
fi

python3 - "$VERIFY_EVIDENCE_DIR" "$check_code" "$drive_code" "$aws_code" <<'PY'
import json, pathlib, sys
evidence = pathlib.Path(sys.argv[1])
check_code, drive_code, aws_code = (int(v) for v in sys.argv[2:])
gate = json.loads((evidence / "aws-gate.json").read_text())
status = gate["status"]
if status not in {"PASS", "FAIL", "BLOCKED", "SKIP"}:
    raise SystemExit(f"unexpected aws status {status}")
if status == "PASS" and (gate.get("seams") or not gate.get("live_cluster_proven")):
    raise SystemExit("PASS without a live cluster proof")
if aws_code == 1 and status != "FAIL":
    raise SystemExit("exit 1 but status is not FAIL")
if aws_code == 2 and status != "BLOCKED":
    raise SystemExit("exit 2 but status is not BLOCKED")
if aws_code == 0 and status not in {"PASS", "SKIP"}:
    raise SystemExit("exit 0 but status is not PASS or SKIP")
summary = evidence / "summary.md"
summary.write_text(
    "\n".join(
        [
            f"# Verification run {evidence.name}",
            "",
            "- Skill: `.cursor/skills/verify-agenticworld`",
            f"- Evidence: `{evidence}`",
            "- Doctor: `doctor.txt`",
            "- Check: `check-status.txt` and `check.log`",
            "- Drive: `cli-version` (`drive/cli-version.json`)",
            f"- AWS gate: `{status}` (`aws-gate.json`)",
            f"- live_cluster_proven: `{str(gate.get('live_cluster_proven')).lower()}`",
            f"- seams: `{str(gate.get('seams')).lower()}`",
            "",
            gate.get("reason", ""),
            "",
        ]
    )
)
print(summary.read_text())
if check_code != 0 or drive_code != 0 or aws_code == 1:
    raise SystemExit(1)
PY
