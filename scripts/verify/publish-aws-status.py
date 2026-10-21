#!/usr/bin/env python3
"""Write the AWS gate verdict to the GitHub step summary. Exit 1 on FAIL."""

import glob
import json
import os
import pathlib
import sys

matches = sorted(glob.glob("evidence/runs/*/aws-gate.json"))
if not matches:
    sys.exit("aws-gate.json was not written")

path = pathlib.Path(matches[-1])
doc = json.loads(path.read_text())
status = doc.get("status")
if status not in {"PASS", "FAIL", "BLOCKED", "SKIP"}:
    sys.exit(f"bad status {status}")
if status == "PASS" and (doc.get("seams") or not doc.get("live_cluster_proven")):
    sys.exit("refusing to publish an unproven PASS")

summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
text = "\n".join(
    [
        f"### AWS gate: {status}",
        "",
        doc.get("reason", ""),
        "",
        f"- static_validation: `{doc.get('static_validation')}`",
        f"- aws_credentials: `{doc.get('aws_credentials')}`",
        f"- cluster: `{doc.get('cluster')}`",
        f"- live_cluster_proven: `{doc.get('live_cluster_proven')}`",
        f"- evidence: `{path}`",
        "",
    ]
)
if summary_path:
    with open(summary_path, "a", encoding="utf-8") as handle:
        handle.write(text)
else:
    print(text)
if status == "FAIL":
    sys.exit("AWS gate FAIL")
