# The Cron Fragility Story

How a memory architecture got rebuilt four times in three days because of one broken cron pattern.

## The Setup

This repo's architecture went through four iterations in 2026. Each iteration tried to solve the same problem: keep a tiny always-injected memory file (`layer-1-memory.md`, aka L1) in sync with the curated long-form memory file (`MEMORY.md`) in the user's vault. Each iteration broke differently.

The pattern that broke every iteration was the same: a cron job that fired at 04:00 to do the sync, configured with a `systemEvent` payload targeting the main session.

## Iteration 1: LLM agentTurn

The first attempt used a full LLM agent turn for the sync. The cron spun up an isolated session, the LLM read MEMORY.md, generated a curated L1, and wrote it back. Total time: ~60 seconds per run.

**Problem:** Cost. Each run burned ~50K tokens to do what should have been a mechanical copy. Twice a day (the cron was also set on a 12-hour cadence during the early debugging) added up to real money for no benefit.

## Iteration 2: shell script + systemEvent

The second attempt replaced the LLM with a deterministic shell script. `l1-sync.sh` parsed MEMORY.md, picked the curated subset, wrote it back to L1. Fast, cheap, mechanical.

Wrapped in a cron job. Cron payload: `systemEvent` with text "Run: bash …/l1-sync.sh", targeting the main session.

**Problem:** Silently failed.

The cron reported `lastRunStatus: ok` every day. `consecutiveErrors: 0`. Everything looked healthy.

But `systemEvent` payloads inject text into the main session — and the main session is dormant at 04:00. The text "Run: bash …/l1-sync.sh" sat unprocessed because no LLM turn ever ran to interpret and execute it. The bash script never ran. L1's sync timestamp froze at `2026-08-14` for seven days while the cron cheerfully reported success.

The damage: the human opened a session and the L1 they expected to see was seven days stale. No error, no warning, just quiet rot.

## Iteration 3: session-start, but keep L1 mirrored

The third attempt dropped the cron entirely and ran the sync at session-start. Every session would refresh L1 before reading it. Reliable because the session IS the trigger — when the human is present, the syncing happens.

**Problem:** Drift from intent.

With session-start doing the sync, L1 became a derivative of MEMORY.md — a small mirror of larger content. But L1's purpose is "tiny always-injected pointers + must-have facts," not "mirror of curated memory." Treating L1 as a mirror meant every session was busy maintaining a derivative file when the human could've just read MEMORY.md directly.

## Iteration 4: kill the mirror

The fourth attempt re-thought the role of L1 entirely.

L1 isn't a mirror. L1 is bootstrapping: pointers to where the real memory lives, plus security boundaries and always-present facts. The curated long-form memory doesn't need to fit in 2KB of always-injected context — it can grow unbounded in `MEMORY.md` and vault files, and session-start reads it.

So:
- L1 stays. Hand-curated. ~2KB.
- `l1-sync.sh` deleted.
- AGENTS.md session-start reads `MEMORY.md` directly for regular memory.
- The cron job for L1 sync was deleted.
- The "deterministic shell script + systemEvent" rewrite that broke iteration 2 was retroactively diagnosed: same bug pattern, different script.

## The Pattern Audit

After iteration 4, every cron in the system was audited. Of the seven jobs:

| Job | Pattern | Status |
|---|---|---|
| Refresh Working Context | isolated agentTurn | ✅ working |
| Memory Dreaming Promotion | isolated agentTurn | ✅ working |
| Promotion Migration | isolated agentTurn | ✅ working |
| Memory Health Metrics | main + systemEvent | ❌ broken (same bug) |
| Vault Backup to Google Drive | webhook delivery | ✅ working |
| Daily Digest | isolated agentTurn | ✅ working |
| Grok World + AI News Digest | (disabled) | n/a |

The audit found one remaining broken job (`Memory Health Metrics`) using the same `systemEvent → main` pattern that broke L1 sync. Same fix applied: convert to `isolated agentTurn` with `lightContext: true`. Audit closed.

## The Rule

Every cron job in this repo uses the same pattern:

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

That's the whole pattern. Any deviation is the bug.

## Iteration 5: HEARTBEAT.md pollution (postscript, 2026-08-26)

The cron audit closed with Memory Health Metrics on the right pattern (`isolated agentTurn + lightContext: true`). But the audit fixed the *delivery channel* without auditing the *write target*. The script was still appending its metrics block into `HEARTBEAT.md` — and `HEARTBEAT.md` is the file the OpenClaw heartbeat handler reads every tick to decide whether to fire.

The heartbeat docs are explicit:

> If `HEARTBEAT.md` exists but is effectively empty (only blank lines, Markdown/HTML comments, Markdown headings like `# Heading`, fence markers, or empty checklist stubs), OpenClaw skips the heartbeat run to save API calls. That skip is reported as `reason=empty-heartbeat-file`.

The metrics block was populated bullets (real key:value data like `- daily_logs_current: false (0/3 days present)`). Not empty stubs. So `reason=empty-heartbeat-file` never fired. Heartbeats ran every hour reading the same stale metrics, and the isolated agent turn interpreted the colon-prefixed bullets as instructions-shaped content. The handler's confused response — `"Same injection. Ignoring. No heartbeat poll in this one — what do you want?"` — got delivered to the user's Discord DM via the `last` target.

The damage: random webhook messages every hour in the user's main chat, asking them what to do. Not malicious, not urgent, just noise that polluted the signal channel.

**The fix:** move the write target. `memory-health.sh` now writes to `MEMORY_HEALTH.md` in the workspace. `HEARTBEAT.md` stays effectively empty. Heartbeats skip with `reason=empty-heartbeat-file`. No model call, no delivery, no noise.

Defense in depth (in case anything else adds content to `HEARTBEAT.md`): the script also strips any legacy `<!-- memory-health-block -->` from `HEARTBEAT.md` on each run. And `AGENTS.md` session-start reads `MEMORY_HEALTH.md` directly, so the metrics remain visible at session start without being on the heartbeat hot path.

The gateway-level `agents.defaults.heartbeat.target` and `directPolicy` keys are protected config paths and cannot be patched at runtime. The script-level scrub is the actual root-cause fix; those gateway knobs would be belt-and-suspenders for a different failure mode.

## The Rule (revised)

Every cron job in this repo uses the same pattern:

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

And every script that writes to the workspace:

- Writes to a dedicated file (`MEMORY_HEALTH.md`, `events.log`, etc.) — never to `HEARTBEAT.md` unless the content is a stable checklist the heartbeat handler should read.
- Idempotent: removes its own block before re-writing, defends against legacy pollution in hot-path files.
- Logs to `LOG_FILE` for audit even when writes succeed (so the cron `status=ok` has a real log line backing it).

## The Lesson

Cron jobs that fire at fixed times targeting a dormant session are systematically fragile. The session is dormant because that's when you want them. The text payload is unprocessed because no LLM turn runs. The cron reports `status: ok` because the message was queued.

Cost discovery loop: a sync mechanism that runs twice a day, costs 50K tokens per run, fails silently for seven days, and doesn't actually fix the problem you built it for is a tax on the user without delivering value.

The fix is structural: stop syncing at scheduled times. Sync at the only reliable trigger — session start. Stop mirroring long-form memory into the always-injected file. Keep L1 hand-curated. Move regular memory to `MEMORY.md` and let it grow.

**The second-order lesson (added 2026-08-26):** a script that does the right thing on the wrong file is still broken. The cron audit checked delivery. It didn't check destination. The HEARTBEAT.md pollution shipped because the audit's scope was narrower than the bug's blast radius. When auditing a pipeline, trace every write target. If a script touches a file that another system reads on a schedule, that's a coupling — and the write target deserves the same scrutiny as the delivery channel.

## What this looks like in production

After the rebuild:

- `l1-sync.sh` — deleted
- The "L1 sync" cron — deleted
- AGENTS.md session-start — reads L1 + MEMORY.md + vault files, no script needed
- L1 — 1448 bytes, pointers + always-present facts only, hand-curated
- All crons — `isolated agentTurn` pattern, no `systemEvent` anywhere
- `cron list --includeDisabled` — audit-friendly, every job shows a verified payload pattern
- 04:05 local — `Memory Health Metrics` runs cleanly, writes to `MEMORY_HEALTH.md`, defensively scrubs any legacy `<!-- memory-health-block -->` from `HEARTBEAT.md`, `lastDurationMs` shows real work happened
- Subsequent sessions — L1 is fresh because the human is here and the session read it

After iteration 5:

- `HEARTBEAT.md` — effectively empty, heartbeats skip with `reason=empty-heartbeat-file`
- `MEMORY_HEALTH.md` — carries the metrics block; read by AGENTS.md session-start step 7
- `memory-health.sh` — touches both files; idempotent and self-healing for HEARTBEAT.md pollution
- Main chat — no more hourly noise from the heartbeat handler

The system has one moving part in the hot path (the session), not three (session + cron + sync script), and the cron no longer feeds a file the heartbeat handler will misread.
