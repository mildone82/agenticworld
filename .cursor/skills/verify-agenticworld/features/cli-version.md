# CLI version

CLI version prints the build identity of the `multica` binary: version, commit, build time, Go version, OS, and architecture. It does not contact a server.

## Sub-features

- `version-text` prints `multica <version>` and the Go line.
- `version-json` prints a JSON object a later step can parse.

## How to get to it (user POV)

- From a terminal, run `multica version`.
- From a terminal, run `multica version --output json`.
- From a terminal, run `multica --version`.

## Driving it with verify-agenticworld

Preconditions:

- `./scripts/verify/doctor.sh` reports `doctor=ok` and `instance.cli=ok`.
- `MULTICA_BIN` in `evidence/runs/<run-id>/launch.env` is executable.

- **JSON identity.** Run `./scripts/verify/drive.sh cli-version`. Exit code 0. `drive/cli-version.json` contains `version`, `commit`, `go`, `os`, and `arch`. `drive/cli-version.meta.txt` records the binary path and `exit=0`.
- **Text identity.** Run `"$MULTICA_BIN" version`. Exit code 0. Stdout starts with `multica ` and contains a `go:` line. Save stdout next to the JSON proof if you need both shapes.

## Gotchas

- `go version` on the host outside `multica/server` can be older than 1.26.1. The proof is the `go` field from the binary built inside that module, not the host `go version` typed in another directory.
- A missing binary is `unmet_precondition`. Do not parse a stale JSON file from an older run.
- Version output does not prove the API, the web app, or an AWS deployment.
