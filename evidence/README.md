# Verification evidence

`scripts/verify/` writes one directory per run:

```text
evidence/runs/<run-id>/
  summary.md
  doctor.txt
  check-status.txt
  check.log
  aws-gate.json
  aws-gate.log
  drive/
  cleanup.log
```

`evidence/runs/` and `evidence/current-run` are gitignored. Scratch binaries and pid files live under `/tmp/verify-agenticworld-<run-id>/` and are deleted by `scripts/verify/cleanup.sh`. Cleanup does not delete this tree.

Read `aws-gate.json` for the AWS verdict. Do not treat a line in `aws-static.log` that says the artifact script passed as a live deployment pass.
