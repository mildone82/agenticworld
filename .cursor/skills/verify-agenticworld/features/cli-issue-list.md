# Issue list

Issue list shows the issues in the current workspace, on the web board and from the CLI.

## Sub-features

- `issue-list-cli` prints the workspace issues as a table or JSON.
- `issue-list-web` shows the same workspace on `/{workspaceSlug}/issues`.

## How to get to it (user POV)

- In the web app, open `/{workspaceSlug}/issues`.
- In a terminal, run `multica issue list`.
- In a terminal, run `multica issue list --output json`.
- Optional filters that exist on the command: `--status`, `--priority`, `--assignee`, `--limit`, `--offset`.

## Driving it with verify-agenticworld

Preconditions:

- CLI binary from `./scripts/verify/launch.sh`, doctor `instance.cli=ok`.
- A server URL is configured (`--server-url`, `MULTICA_SERVER_URL`, or `multica config set server_url`).
- The command is authenticated and a workspace id is set. Without those, the command exits non-zero.
- Web proof additionally needs full launch and a signed-in browser session. This drive script does not sign in.

- **CLI list.** Run `./scripts/verify/drive.sh cli-issue-list`. Exit code 0. `drive/cli-issue-list.json` is JSON. `drive/cli-issue-list.meta.txt` records `exit=0` and the binary path.
- **Web board.** After a real sign-in, open `/{workspaceSlug}/issues` and save the page body or a snapshot that shows the same workspace slug. Do not claim this step from the CLI JSON alone.

## Gotchas

- With no server URL the CLI returns `server URL not set: use --server-url flag, MULTICA_SERVER_URL env, or 'multica config set server_url <url>'` and the drive exits 1 as `unmet_precondition`. That is not a successful empty list.
- `multica version` does not list issues.
- The drive does not pass `--server-url` for you and does not read `.env` secrets into the evidence directory.
- Listing issues does not prove create, assign, or agent execution.
