# Phase 0 ccc Findings

Date: 2026-05-03

## Environment

- `ccc` v0.3.0 at `/opt/homebrew/bin/ccc`
- `tmux` 3.6a
- Claude Code 2.1.126 at `/opt/homebrew/bin/claude`
- Codex CLI 0.128.0 at `/opt/homebrew/bin/codex`

## CLI Findings

- `ccc run` uses Claude as the default backend. The current command shape is `ccc run <name> --cwd <cwd>`.
- The previous `--claude` flag is not part of the current `ccc run --help` output, so the Bridge no longer sends it.
- `ccc ps --json` includes historical dead sessions with `alive:false`. The Bridge now preserves `alive` from ccc output and skips dead sessions in `session.list`.
- `ccc read <name> --json` worked through the Bridge `session.attach` path for newly created sessions.

## Bridge E2E Results

Started the Bridge locally with:

```bash
CCM_TOKEN=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
CCM_WORKSPACE_ROOT=/private/tmp/ccm-e2e-workspace \
CCM_PORT=8910 \
npm run dev
```

Smoke test without prompt:

```bash
CCM_E2E_TOKEN=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee npm run e2e:smoke
```

Verified:

- `auth`
- `workspace.create`
- `workspace.list`
- `session.run`
- `session.attach`
- `session.kill`

Smoke test with prompt:

```bash
CCM_E2E_TOKEN=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee \
CCM_E2E_PROMPT="Do not edit files. Reply with exactly: OK" \
npm run e2e:smoke
```

Verified:

- `message.send`
- cleanup through `session.kill`

The first kill cleanup run exposed a Bridge bug where an in-flight poll could reschedule itself after `session.kill`. The poller now checks whether the session is still active before logging or scheduling after an awaited `ccc read`.

After rerunning the prompt smoke against the fix:

- no post-kill `state_poll_failed` warnings were emitted during a 12 second observation window
- `ccc ps --json` showed no new alive E2E sessions

## Remaining Manual Checks

- Approval prompts still need a scenario that reliably triggers Claude Code permission approval.
- Android device testing still needs installing the APK and connecting to the local or Tailscale Bridge URL.
