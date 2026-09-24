# squink for AI agents

`squink` prints on the user's printer through CUPS. Always pass `--json`: stdout is then
exactly one JSON object, errors included. Progress text goes to stderr.

## Recipes

| Goal | Command |
|---|---|
| Is the printer ready? | `squink status --json` → `.ready` |
| Print a file and confirm it printed | `squink print PATH --wait --json` → `.state == "completed"` |
| Print a URL | `squink print --url URL --wait --json` |
| Print generated text | `squink print --text "TEXT" --wait --json` |
| Print command output | `CMD \| squink print - --wait --json` |
| Several copies / pages / black and white | add `--copies N`, `--pages 1-3`, `--mono` |
| Preview without printing | add `--dry-run` |
| What is in the queue? | `squink jobs --json` |
| Cancel a job | `squink cancel JOB_ID --json` |
| First use, or printer moved | `squink setup --json` (or `--ip IP` if the user gives the address) |

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | Success | Done. |
| 1 | Failure (`.error` says why) | Read `.error`. Unreachable printer: ask the user to turn it on. |
| 2 | Bad usage | Fix the command. `squink help <command>` shows the flags. |
| 3 | `--wait` timed out; the job is still queued | `.message` has the printer's last word. Tell the user; `squink cancel ID` if they want. |

## Rules

- Print only when the user clearly asked for it.
- More than 3 copies: confirm with the user first.
- Never print secrets, passwords, keys or authentication codes unless the user explicitly
  asks in the same message.
- Use `--job-name` with a short, descriptive title.
- `"state": "sent"` (no `--wait`) means CUPS accepted the job, not that it printed.
- Do not retry a failed print in a loop: check `squink status --json` and report.
- Nothing works? Run `squink status --json`, then `squink discover --json`, and show the user.
