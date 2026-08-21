# Four-Layer Memory Architecture

The memory architecture that ships with this repo uses four layers, each with a different purpose, lifetime, and update mechanism. They're not redundant — each one solves a problem the others can't.

## Layer 1: Built-in Always-Injected (`layer-1-memory.md`)

**What:** A tiny file (~2.2KB) of pointers and security-critical facts.

**Who updates it:** Hand-curated by the human. Never synced.

**Why it exists:** The OpenClaw runtime injects this file into every session automatically, before the user even types. Anything that must be present in every session — vault paths, security boundaries, "don't exfiltrate work email" — lives here.

**Why it's tiny:** Auto-injected context costs tokens on every turn. A 2KB file is cheap; a 50KB mirror file would balloon model bills and pollute every response.

**Why hand-curated:** Any sync mechanism (L1 ← MEMORY.md, or session-start, or cron) is a chance for drift. Drift is silent. A hand-curated file is correct by construction — every fact there was deliberately placed.

**What goes in:** Pointers to other files (vault, shared, working-context). Security boundaries. Handles. Auth notes. A one-line map of the four layers so the agent knows where to look.

**What stays out:** Project status (lives in `project-state.md`). Decisions (lives in `decisions-log.md`). User history (lives in `user-profile.md`). Anything that grows over time.

## Layer 2: Workspace Behavior (`AGENTS.md` + `SOUL.md` + `USER.md`)

**What:** The contract between the human and the agent. Mandatory session-start reads.

**Who updates it:** Hand-edited when the contract changes.

**Why it exists:** Sessions start cold. Without explicit instructions, the agent has no opinion about how to behave, what to read, or what to refuse. These files encode the operating rules.

**`AGENTS.md`** is structural: read order, freshness checks, session-end ritual, red lines, group chat behavior. The agent follows this file before doing anything else.

**`SOUL.md`** is identity: persona, tone, how to operate. Distinct from `AGENTS.md` because personality shouldn't drift with structural changes.

**`USER.md`** is context: who the human is. Loaded every session because it's small and useful.

**Why three files instead of one:** SOUL changes rarely and is shareable (you can publish your soul without revealing your user). AGENTS changes when the system architecture changes. USER changes when the human's life changes. Splitting them keeps each one stable.

## Layer 3: Obsidian Vault (canonical knowledge)

**What:** A directory of Markdown files in the user's Obsidian vault. The actual knowledge base.

**Who updates it:** Anyone. The agent writes daily logs and decision entries. The human writes project state and profile updates.

**Why it exists:** Long-term memory needs to grow unbounded, be browsable, and be queryable. Markdown on the filesystem wins on all three counts.

**Structure:**

```
<VAULT>/Agent-OpenClaw/
├── layer-1-memory.md      ← L1 (mirror of always-injected file)
├── working-context.md     ← L2-adjacent: current focus + last-updated
├── mistakes.md            ← L3: durable lessons
├── events.log             ← L3: machine-readable trail (JSONL)
└── daily/
    └── YYYY-MM-DD.md      ← L3: one file per session-day

<VAULT>/Agent-Shared/
├── project-state.md       ← L3: Front Line / Back Burner / Tabled
├── decisions-log.md       ← L3: durable choices
└── user-profile.md        ← L3: long-form notes about the human
```

**Why it's separate from the OpenClaw workspace:** The vault is durable. It can be backed up, synced, browsed in Obsidian, version-controlled in git. The workspace is operational. Mixing the two means deletions in one cascade to the other.

**Why no sync to L1:** Because L1 is hand-curated. The vault is auto-curated (sessions write to it). Bridging auto-curated content into auto-injected context is the drift trap this architecture explicitly avoids.

## Layer 4: Archive Recall (session transcripts + Archive/)

**What:** Everything we've ever said. Session search. Archived notes from old sessions.

**Who updates it:** The runtime auto-logs sessions. The agent archives notes when projects wrap up.

**Why it exists:** Last-resort recall. When the agent doesn't have enough context from Layers 1–3 to answer a question, search falls through to: "What did we say about this in the past?"

**Performance:** Slow. Expensive (embeddings + vector search). Don't make it the default.

**Trigger:** `memory_search` only when the answer isn't in L1, L2, L3. If it's there, use it directly.

## How they interact

At session start:

1. **Runtime injects L1** (automatic; ~0ms).
2. **Agent reads AGENTS.md, SOUL.md, USER.md** (mandatory; ~100ms).
3. **Agent reads vault files** in the order AGENTS.md specifies (~500ms).
4. **Agent reads MEMORY.md** if main session (~1s for a 30KB file).
5. **Agent runs freshness checks**; stale → warn; gap → surface.
6. **Session begins.**

When the session ends:

1. **Agent appends to `daily/YYYY-MM-DD.md`.**
2. **Decisions → `decisions-log.md`.**
3. **Lessons → `mistakes.md`.**
4. **Profile updates → `user-profile.md` in the same turn.**
5. **JSONL event appended to `events.log`.**

When something needs long-term memory that's not yet captured:

- New project → `project-state.md` (Front Line)
- Durable decision → `decisions-log.md`
- Lesson learned → `mistakes.md`
- Profile-affecting fact → `user-profile.md`

When L1 needs to change (rare):

- Open the file. Edit by hand. Commit if version-controlled. Done.

## What this isn't

This isn't a fancy retrieval-augmented generation (RAG) system. There's no vector database on the hot path, no embedding pipeline, no chunker. The hot path is "read these specific files in this order." L4 search is opt-in via the `memory_search` tool, gated by relevance.

This tradeoff is deliberate. RAG is impressive until the moment a retrieval miss costs you the answer to a question your human asked. Reading specific files in order is boring but reliable.

## What this is for

Long-lived personal agents. Not customer service bots. Not chat assistants. The kind of agent where the same human talks to it for months or years, accumulates a real working relationship, and notices when it gets something wrong.

The four layers are the minimum viable structure for that. Less than this and you lose continuity. More than this and the operational complexity starts eating the agent's attention budget.
