# OpenClaw Memory System

A four-layer memory architecture for OpenClaw (or similar) AI agents — backed by an Obsidian vault, hardened against the cron-fragility patterns that silently fail.

After multiple iterations of trying to keep a tiny "always-injected" memory file in sync with curated long-term memory — and watching each iteration break in a new way — this is what's left working. The lessons are baked into the structure.

---

## Bootstrap in one paste

The fastest path. Copy the block below, paste into Claude / ChatGPT / your preferred capable LLM, and answer the questions with your own specifics. The LLM scaffolds the whole system for you.

<details>
<summary><strong>Click to expand the bootstrap prompt</strong></summary>

```
You are setting up a four-layer memory system for me, based on the architecture
in https://github.com/prive8/openclaw-memory-system. My agent is OpenClaw (or a
similar long-running AI assistant). I want the architecture, file layout, cron
jobs, and operational rituals from that repo, customized for my environment.

Before you create any files, ask me these questions and wait for my answers:
  1. Absolute path to my Obsidian vault (e.g., /Users/me/Documents/Vault)
  2. Absolute path to my OpenClaw workspace (e.g., ~/.openclaw/workspace)
  3. My name and pronouns
  4. Any security boundary I want hardcoded into L1
     (e.g., "never put work email in external AI")
  5. My GitHub handle (or "skip" if I don't want a repo)
  6. Public or private repo preference

Then create the following:

## 1. Workspace files (in <WORKSPACE>/)

- AGENTS.md — session-start protocol:
    * Read SOUL.md, USER.md
    * Read L1 pointer file
    * Read shared vault files (user-profile, project-state, decisions-log)
    * Read working-context.md + today's daily log
    * Read MEMORY.md
    * Freshness checks: working-context >24h stale → warn;
      daily-log gap >2d → surface and close
    * Session-end ritual: append a paragraph to daily/YYYY-MM-DD.md
      for any meaningful turn
    * "Red lines" section: no exfiltration, no destructive commands
      without asking, prefer trash over rm

- SOUL.md — persona:
    * Name + emoji
    * Vibe / personality traits
    * How to operate (direct, no filler, ask one question when blocked)
    * Continuity (files are memory; read/update them)

- USER.md — about me:
    * Name, pronouns, timezone, location
    * Family / context I want kept
    * Anything else worth remembering

## 2. L1 pointer file

<VAULT>/Agent-OpenClaw/layer-1-memory.md. Under 2.2KB. Sections:
  - Pointers (vault, shared, working-context, daily, scripts)
  - Security boundary (from my answer)
  - Handles
  - Repos + auth notes
  - Local AI config
  - Memory & Rules (four layers + freshness thresholds + cron patterns)

Hard rule: hand-curated, NOT synced. Regular memory lives in MEMORY.md
and the vault files.

## 3. Obsidian vault structure

Create these under <VAULT>/:

  Agent-OpenClaw/
  ├── layer-1-memory.md
  ├── working-context.md        (with "Last Updated: YYYY-MM-DD" first line)
  ├── mistakes.md
  ├── events.log                (empty JSONL)
  └── daily/
      └── YYYY-MM-DD.md         (today's date)

  Agent-Shared/
  ├── project-state.md          (Front Line / Back Burner / Tabled sections)
  ├── decisions-log.md
  └── user-profile.md

## 4. The bash scripts

Create these in <WORKSPACE>/scripts/:

  - vault-preflight.sh        fail loudly if vault path doesn't resolve
                              (prevents WSL-vs-Windows confusion)
  - vault-write.sh            atomic write wrapper (temp file + rename)
  - refresh-working-context.sh bump "Last Updated:" line if >24h stale
  - memory-health.sh          compute metrics, write to HEARTBEAT.md
  - promotion-migrate.sh      move auto-promoted snippets from
                              MEMORY.md to memory-promotions.md
  - events-view.sh            view the events log

All scripts: bash with `set -euo pipefail`, log to <WORKSPACE>/logs/.

## 5. Cron jobs (every morning 03:00–04:00 local time)

Configure these as scheduled jobs. ALL of them use the same pattern:

  {
    "sessionTarget": "isolated",
    "payload": {
      "kind": "agentTurn",
      "message": "Run bash <script> and report the output.
                  If errors, surface them.",
      "lightContext": true
    },
    "delivery": { "mode": "none" }
  }

The four jobs:
  - Refresh Working Context      bash refresh-working-context.sh
  - Memory Dreaming Promotion    managed by memory-core plugin (LLM-mediated)
  - Promotion Migration          bash promotion-migrate.sh
  - Memory Health Metrics        bash memory-health.sh

CRITICAL: Do NOT use systemEvent payloads targeting the main session.
That delivery channel silently fails when the main session is dormant
(4 AM = when you want them, 4 AM = when no one's listening). The cron
reports status=ok because the message was queued; nothing executes.
You only notice when the output drifts.

The working pattern is isolated agentTurn with lightContext.

## 6. Daily log ritual

After every meaningful session turn, append a one-paragraph summary
to <VAULT>/Agent-OpenClaw/daily/YYYY-MM-DD.md. Mirror decisions into
decisions-log.md. Lessons into mistakes.md.

When done, walk me through:
  - chmod +x on the scripts
  - Wiring the cron jobs (with example curl / API calls)
  - Editing SOUL.md to fit my persona
  - (If applicable) Creating the GitHub repo
```

</details>

---

## What this is

This is not a product. It's an operating pattern.

Four layers:

1. **L1** — built-in always-injected file of pointers and security-critical facts. Hand-curated. Under 2.2KB. Not synced.
2. **L2** — `AGENTS.md` + `SOUL.md` + `USER.md` in the OpenClaw workspace. Mandatory session-start reading order.
3. **L3** — Obsidian vault as canonical knowledge. Long-form memory, project state, decisions, user profile, daily logs. Always-current.
4. **L4** — session transcripts + archived notes for last-resort historical recall.

The OpenClaw runtime injects L1 automatically. L2 and L3 are read at session-start per `AGENTS.md`. The agent treats them as load-bearing, not optional.

## The cron fragility story (the reason this exists)

The cron landscape in OpenClaw has two patterns:

| Pattern | Reliability |
|---|---|
| `sessionTarget: "isolated"` + `payload.kind: "agentTurn"` + `lightContext: true` | ✅ actually runs |
| `sessionTarget: "main"` + `payload.kind: "systemEvent"` | ❌ silently fails |

The second pattern looks fine from the cron dashboard — `lastRunStatus: ok`, `consecutiveErrors: 0`. But the `systemEvent` payload targets the main session, which is dormant at 04:00. The injected text "Run: bash …" sits unprocessed because no LLM turn ever runs to interpret and execute it. You only notice when the output drifts — and by then it's been failing for days or weeks.

The pattern this repo ships is the first one. Every cron job — refresh, health, migration, dreaming — uses isolated agentTurn. Session-start handles the sync work; cron handles distillation.

Full debug case study → [`docs/fragility-story.md`](docs/fragility-story.md)

## Quick start (DIY path)

```bash
# 1. Clone
git clone https://github.com/prive8/openclaw-memory-system
cd openclaw-memory-system

# 2. Copy templates into your OpenClaw workspace
cp AGENTS.md.example SOUL.md.example ~/.openclaw/workspace/
cd ~/.openclaw/workspace
mv AGENTS.md.example AGENTS.md
mv SOUL.md.example SOUL.md
cp USER.md.example USER.md

# 3. Set up your vault
cp -r ../openclaw-memory-system/vault-template/* /path/to/your/obsidian/vault/

# 4. Install scripts
chmod +x scripts/*.sh

# 5. Wire up the crons (see cron/README.md)
# Each sample JSON file is the exact payload + schedule for one job.
```

Then edit SOUL.md, USER.md, and the vault files to fit you.

## Repository layout

```
.
├── README.md                  — this file
├── AGENTS.md.example          — drop-in session-start protocol
├── SOUL.md.example            — minimal persona template
├── USER.md.example            — about-the-human template
├── scripts/                   — bash helpers
│   ├── vault-preflight.sh     — path validation (prevents WSL-vs-Windows confusion)
│   ├── vault-write.sh         — atomic vault writes
│   ├── refresh-working-context.sh
│   ├── memory-health.sh
│   ├── promotion-migrate.sh
│   ├── events-view.sh
│   └── embedding-version-check.sh
├── cron/
│   ├── README.md              — the pattern doc (READ THIS FIRST)
│   └── *.json                 — sample cron configs
├── vault-template/            — skeleton Obsidian vault
│   ├── Agent-OpenClaw/
│   │   ├── layer-1-memory.md.example
│   │   ├── working-context.md.example
│   │   ├── mistakes.md
│   │   └── events.log
│   └── Agent-Shared/
│       ├── project-state.md
│       ├── decisions-log.md
│       └── user-profile.md
└── docs/
    ├── architecture.md        — four-layer architecture deep-dive
    └── fragility-story.md     — the day main+systemEvent broke silently
```

## Operational patterns

### Session start (don't cron this)

Sync at session-start. The session is the trigger; if the agent isn't loaded, the syncing doesn't matter. `AGENTS.md` encodes the read order:

1. `SOUL.md`, `USER.md`
2. L1 pointer file
3. Shared vault files (user-profile, project-state, decisions-log)
4. Working-context + daily logs (today + yesterday)
5. `MEMORY.md` (the curated long-term memory)

Plus freshness checks: working-context >24h stale → warn. Daily-log gap >2d → surface and close.

### The cron pattern (when you do need cron)

For work that benefits from a scheduled run — memory distillation, health metrics, fresh working-context — use `sessionTarget: "isolated"` + `payload.kind: "agentTurn"` + `lightContext: true`. Each job gets a fresh session. The LLM actually loads, the bash actually runs, and `failureAlert` routes errors to your alerting channel.

The pattern:
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

That is the entire pattern. Anything using `systemEvent` or `sessionTarget: "main"` is the buggy pattern.

### Daily log ritual

Every meaningful session ends with a paragraph appended to `daily/YYYY-MM-DD.md`. Decisions get mirrored into `decisions-log.md`. This is your continuity across sessions.

### MEMORY.md is the canvas

Long-form curated memory. Updated by hand when you have something worth remembering. Promoted short-term memories from session search get appended here with markers; a separate promotion-migration script moves them out when they get old.

## Why this exists as a public repo

OpenClaw ships with a small always-injected L1 file but no opinion about how the rest of the memory should be structured. The first three attempts at keeping L1 in sync with curated long-term memory each broke in a new way. The fourth attempt (this one) keeps L1 hand-curated and pushes regular memory into the vault where it can grow without sync machinery.

Publishing it because the bootstrap-prompt approach is the gift that keeps giving: paste it into a fresh LLM, get a working memory system in 10 minutes.

## License

MIT. Take it, fork it, ship your own flavor.
