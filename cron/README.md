# Cron Patterns

This directory contains sample cron configurations for the four jobs the memory system ships with. Read this first before wiring them up.

## The Rule

**Every cron job in this system uses the same pattern:**

```json
{
  "sessionTarget": "isolated",
  "payload": {
    "kind": "agentTurn",
    "message": "Run bash <script> and report the output. If errors, surface them.",
    "lightContext": true
  },
  "delivery": { "mode": "none" }
}
```

That's the whole pattern. Any cron that uses `systemEvent` payloads targeting the main session is **broken by design** — the main session is dormant at 04:00, the text never gets interpreted, and the cron reports `status: ok` while doing nothing.

## Why

OpenClaw cron supports two payload kinds: `systemEvent` and `agentTurn`. The difference:

| Payload | Target | Reliability |
|---|---|---|
| `systemEvent` | `sessionTarget: "main"` | ❌ silently fails when main session is dormant |
| `agentTurn` | `sessionTarget: "isolated"` | ✅ works — isolated session wakes for each job |

`systemEvent` injects text into the main session. If the main session is asleep (4 AM is exactly when you want the cron to fire), the text sits in a queue or gets dropped. The cron thinks it ran; nothing actually executed.

`agentTurn` to `isolated` spins up a fresh ephemeral session per run. The LLM loads, the bash actually runs, the output gets reported. That's what works.

## The Four Jobs

This system ships with four cron jobs, all running 03:00–04:00 local time:

| Job | Schedule | What it does | Sample |
|---|---|---|---|
| **Refresh Working Context** | `55 3 * * *` | `bash refresh-working-context.sh` — bump `Last Updated:` line if >24h stale | [`refresh-working-context.json`](refresh-working-context.json) |
| **Memory Dreaming Promotion** | `0 3 * * *` | Managed by `memory-core` plugin (LLM-mediated, no bash) | [`memory-dreaming-promotion.json`](memory-dreaming-promotion.json) |
| **Promotion Migration** | `30 3 * * *` | `bash promotion-migrate.sh` — move auto-promoted snippets from MEMORY.md to memory-promotions.md | [`promotion-migration.json`](promotion-migration.json) |
| **Memory Health Metrics** | `5 4 * * *` | `bash memory-health.sh` — write health snapshot to HEARTBEAT.md | [`memory-health-metrics.json`](memory-health-metrics.json) |

## Wiring them up

The samples are JSON templates. To install:

1. **Edit the placeholders** in each JSON file:
   - `~/.openclaw/workspace/scripts/...` → your actual scripts directory
   - `user:YOUR_DISCORD_ID` → your Discord user ID (for `failureAlert.to`)
   - `"channel": "discord"` → your alert channel
2. **Use the cron tool to register each one:**
   ```bash
   # Example: openclaw-style cron registration
   # The OpenClaw runtime accepts cron configs with the schema below.
   ```
3. **Verify**: after registration, check `cron list --includeDisabled` for the new jobs. Each one should show `sessionTarget: "isolated"` and a proper `agentTurn` payload.

## Placeholders every config needs

- **Script path** — wherever you put the bash scripts. Default in samples: `~/.openclaw/workspace/scripts/`.
- **Alert target** — your Discord user ID for `failureAlert.to`. Get it from Discord (right-click your username, "Copy User ID" with Developer Mode on).
- **Log paths** — `${LOG_DIR:-/path/to/your/logs}` is set by each script via the `LOG_DIR` env var. Default works if your logs dir matches.
- **Vault root** — `scripts/*.sh` use `${VAULT_ROOT:-/path/to/your/vault}`. Set this in your shell rc (`export VAULT_ROOT=/path/to/vault`) or in the cron job's payload message.

## Before you ship

Run an audit:

```bash
openclaw cron list --includeDisabled
```

For each job, verify:
- `sessionTarget` is `"isolated"` (NOT `"main"`)
- `payload.kind` is `"agentTurn"` (NOT `"systemEvent"`)
- `payload.lightContext` is `true`
- `lastDurationMs` after a recent run is > 1000 (a real run, not a 39ms silent no-op)

Any job that fails any of these checks is broken. The systemEvent-on-main-session pattern is the bug; convert or kill.
