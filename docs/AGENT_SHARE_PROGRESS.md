# Agent-share verification note

When you hand work to another agent or open a PR, link the evidence directory. Do not paste tokens, kubeconfigs, AWS keys, or `.env` contents.

## Template

```markdown
- Verification skill: `.cursor/skills/verify-agenticworld`
- Evidence: `evidence/runs/<run-id>/` (see `summary.md`)
- Doctor: `evidence/runs/<run-id>/doctor.txt`
- Check: `evidence/runs/<run-id>/check-status.txt` (`mode` is `full`, `minimal`, or `go`)
- Drive: `<feature-id>` in `evidence/runs/<run-id>/drive/`
- AWS gate: `PASS` | `FAIL` | `BLOCKED` | `SKIP` — `evidence/runs/<run-id>/aws-gate.json`
```

`BLOCKED` is not a pass. It means AWS credentials or the Kubernetes cluster were missing, or `scripts/validate-deployment.sh` could not be run. A static Helm/Terraform success does not make the gate `PASS`.

`SKIP` is only for a documentation-only diff. The JSON `reason` names that, and `changed_files` lists the paths.

`PASS` counts only when `status` is `PASS`, `seams` is false, and `live_cluster_proven` is true.

Local entrypoint: `./scripts/verify/run.sh`
