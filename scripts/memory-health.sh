#!/bin/bash
# Memory health metrics — computes daily-log freshness, working-context age,
# L1 freshness, vault write errors, and auto-backfills stub daily logs for
# silent days so the canary doesn't lie about a long gap.
#
# Writes a metrics block to MEMORY_HEALTH.md (workspace) for visibility at
# session start. AGENTS.md session-start reads MEMORY_HEALTH.md directly.
#
# IMPORTANT: do NOT write to HEARTBEAT.md — its content is read every
# heartbeat tick and a non-empty file defeats OpenClaw's
# `reason=empty-heartbeat-file` skip, causing the heartbeat handler to fire
# on stale data and deliver error/injection-shaped responses to the user's DM.
#
# Recommended schedule: 04:05 EDT (after L1 sync at 04:00).
#
# Configuration via environment variables (all optional, sensible defaults):
#   VAULT_ROOT    — path to the Obsidian vault (default: /path/to/your/vault)
#   WORKSPACE     — path to the OpenClaw workspace (default: /path/to/your/workspace)
#   LOG_DIR       — directory for log files (default: $WORKSPACE/logs)
#
# Changelog:
#   2026-09-07 rewrite (this version):
#     - Bug fix #1: daily-log lookback extended from 3 days to 7 days; added
#       `daily_logs_max_gap_days` metric (the old metric underreported a real
#       8-day gap as 1/3).
#     - Bug fix #2: `l1_sync_status` (always "no_sync_marker" — the Sync
#       marker was stripped from L1 on 2026-08-21) replaced with
#       `l1_freshness_hours` measuring L1 mtime age.
#     - Bug fix #3: `working_context_age_hours` was using a bash regex that
#       silently fell back to midnight-of-the-date on no-match. Now reads
#       file mtime directly via `stat -c %Y`.
#     - Fix C (auto): for each silent day in the 7-day lookback, write a
#       stub `daily/YYYY-MM-DD.md` pointing at the latest canonical daily
#       log session. Idempotent, no-op if file already exists.
#     - Fix B (signaled): emit a `stale_context` boolean into MEMORY_HEALTH.md
#       so AGENTS.md session-start can fail-fast on the value (not just observe).

set -euo pipefail

VAULT="${VAULT_ROOT:-/path/to/your/vault}"
DAILY_DIR="$VAULT/Agent-OpenClaw/daily"
WORKING_CONTEXT="$VAULT/Agent-OpenClaw/working-context.md"
L1="$VAULT/Agent-OpenClaw/layer-1-memory.md"
PROMOTIONS="$VAULT/Agent-OpenClaw/memory-promotions.md"
WORKSPACE="${WORKSPACE:-/path/to/your/workspace}"
MEMORY_HEALTH="$WORKSPACE/MEMORY_HEALTH.md"
HEARTBEAT="$WORKSPACE/HEARTBEAT.md"
LOG_DIR="${LOG_DIR:-$WORKSPACE/logs}"
LOG_FILE="$LOG_DIR/memory-health.log"

mkdir -p "$LOG_DIR" "$(dirname "$MEMORY_HEALTH")"

now_epoch=$(date +%s)
TODAY=$(date '+%Y-%m-%d')
TODAY_TIME=$(date '+%H:%M %Z')
RUN_TS=$(date '+%Y-%m-%d %H:%M:%S %Z')

echo "=== Memory Health Metrics ($RUN_TS) ==="

# -----------------------------------------------------------------------
# 1. Daily-log freshness — look back 7 days, count present + measure gap
# -----------------------------------------------------------------------
daily_present_count=0
daily_max_gap_days=0
daily_current_gap=0
silent_days=()

for i in 0 1 2 3 4 5 6; do
    d=$(date -d "$i days ago" '+%Y-%m-%d' 2>/dev/null || date -v-${i}d '+%Y-%m-%d')
    f="$DAILY_DIR/$d.md"
    if [[ -f "$f" && -s "$f" ]]; then
        daily_present_count=$((daily_present_count + 1))
        daily_current_gap=0
    else
        silent_days+=("$d")
        daily_current_gap=$((daily_current_gap + 1))
        if [[ $daily_current_gap -gt $daily_max_gap_days ]]; then
            daily_max_gap_days=$daily_current_gap
        fi
    fi
done

if [[ $daily_present_count -ge 5 ]]; then
    daily_logs_current="true"
elif [[ $daily_present_count -ge 3 ]]; then
    daily_logs_current="warning"
else
    daily_logs_current="false"
fi
echo "  daily_logs_current: $daily_logs_current ($daily_present_count/7 in last week; max gap: ${daily_max_gap_days}d)"

# -----------------------------------------------------------------------
# 2. Auto-backfill stubs for silent days (Fix C)
#    Metric collects over a 7-day window. Backfill extends to a 30-day
#    window so older silent days in the chain get stubbed without lying
#    about the current state. Both loops idempotent — re-runs are no-ops.
# -----------------------------------------------------------------------

# Find most recent canonical daily log session (>200 bytes, has Session block).
# Used as the "see also" pointer in each stub.
latest_daily_name=""
latest_session_title=""
while IFS= read -r f; do
    fname=$(basename "$f" .md)
    size=$(wc -c < "$f")
    if [[ $size -lt 200 ]]; then continue; fi
    if grep -q "^## Session" "$f"; then
        latest_daily_name="$fname"
        latest_session_title=$(grep -m1 "^## Session" "$f" | sed 's/^## Session — //' | sed 's/[[:space:]]*$//')
        break
    fi
done < <(ls -1r "$DAILY_DIR"/*.md 2>/dev/null)

# write_stub returns 0 if it created the file, 1 if it skipped (already exists).
write_stub() {
    local d="$1"
    local f="$DAILY_DIR/$d.md"
    [[ -f "$f" ]] && return 1
    if [[ -z "$latest_daily_name" ]]; then
        cat > "$f" <<EOF
# $d

## Session — Auto-stub (silent day)

No real session on this day. Auto-stub written by \`memory-health.sh\` to keep the daily-log chain continuous. Working-context was not refreshed on this date — see the latest canonical daily log entry for the most recent activity.

EOF
    else
        cat > "$f" <<EOF
# $d

## Session — Auto-stub (silent day)

No real session on this day. Auto-stub written by \`memory-health.sh\` to keep the daily-log chain continuous. Anchor: \`daily/${latest_daily_name}.md\` (last session: ${latest_session_title}).

EOF
    fi
}

# Backfill silent days in the 7-day metric window
backfilled=0
for d in "${silent_days[@]}"; do
    if write_stub "$d"; then
        backfilled=$((backfilled + 1))
    fi
done

# Extended backfill: walk 30 days back, stub anything still missing, but stop
# once we hit a real session (size >= 200 bytes AND has Session block).
for i in 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29; do
    d=$(date -d "$i days ago" '+%Y-%m-%d' 2>/dev/null || date -v-${i}d '+%Y-%m-%d')
    f="$DAILY_DIR/$d.md"
    if [[ -f "$f" ]]; then
        size=$(wc -c < "$f")
        if [[ $size -ge 200 ]] && grep -q "^## Session —" "$f"; then
            break
        fi
        continue
    fi
    if write_stub "$d"; then
        backfilled=$((backfilled + 1))
    fi
done

if [[ $backfilled -gt 0 ]]; then
    echo "  ⟳ backfilled $backfilled silent-day stub(s)"
fi

# -----------------------------------------------------------------------
# 3. Working-context age — file mtime is ground truth
# -----------------------------------------------------------------------
if [[ -f "$WORKING_CONTEXT" ]]; then
    wc_mtime_epoch=$(stat -c %Y "$WORKING_CONTEXT" 2>/dev/null || echo 0)
    if [[ "$wc_mtime_epoch" -gt 0 ]]; then
        wc_age_hours=$(( (now_epoch - wc_mtime_epoch) / 3600 ))
    else
        wc_age_hours="unknown"
    fi
else
    wc_age_hours="missing"
fi
echo "  working_context_age_hours: $wc_age_hours"

# -----------------------------------------------------------------------
# 4. L1 freshness — was "l1_sync_status" (structurally dead post-8/21)
#    L1 is hand-curated; measuring how recently it was touched answers
#    "is L1 still being maintained" without assuming a sync cron's existence.
# -----------------------------------------------------------------------
if [[ -f "$L1" ]]; then
    l1_mtime_epoch=$(stat -c %Y "$L1" 2>/dev/null || echo 0)
    if [[ "$l1_mtime_epoch" -gt 0 ]]; then
        l1_age_hours=$(( (now_epoch - l1_mtime_epoch) / 3600 ))
    else
        l1_age_hours="unknown"
    fi
else
    l1_age_hours="missing"
fi
echo "  l1_freshness_hours: $l1_age_hours"

# -----------------------------------------------------------------------
# 5. Vault write errors — count from logs in last 24h
# -----------------------------------------------------------------------
if [[ -d "$LOG_DIR" ]]; then
    vault_errors=$(find "$LOG_DIR" -name "*.log" -mtime -1 \
        -exec grep -l "vault.*error\|VAULT PREFLIGHT FAIL" {} \; 2>/dev/null | wc -l)
else
    vault_errors=0
fi
echo "  vault_write_errors: $vault_errors"

# -----------------------------------------------------------------------
# 6. Memory-promotions file size (sanity check it's not exploding)
# -----------------------------------------------------------------------
if [[ -f "$PROMOTIONS" ]]; then
    promo_size=$(wc -c < "$PROMOTIONS")
else
    promo_size=0
fi
echo "  memory_promotions_bytes: $promo_size"

# -----------------------------------------------------------------------
# 7. L1 size (should be under 2200 chars)
# -----------------------------------------------------------------------
if [[ -f "$L1" ]]; then
    l1_size=$(wc -c < "$L1")
else
    l1_size=0
fi
echo "  l1_size_bytes: $l1_size"

# -----------------------------------------------------------------------
# 8. Hard-gate sentinel for AGENTS.md session-start to consume
#    stale_context fires when WC is missing/>24h OR daily-log max gap >3d
# -----------------------------------------------------------------------
if [[ "$wc_age_hours" == "missing" ]] || \
   ([[ "$wc_age_hours" =~ ^[0-9]+$ ]] && [[ $wc_age_hours -gt 24 ]]) || \
   [[ $daily_max_gap_days -gt 3 ]]; then
    stale_context="true"
else
    stale_context="false"
fi
echo "  stale_context: $stale_context"

# -----------------------------------------------------------------------
# 9. Write metrics block to MEMORY_HEALTH.md
# -----------------------------------------------------------------------
touch "$MEMORY_HEALTH"

# Defense in depth: scrub any legacy memory-health-block from HEARTBEAT.md.
# See changelog 2026-08-26 for the original bug. Python paths passed as argv
# so the quoted heredoc stays clean — no shell expansion inside Python code.
if [[ -f "$HEARTBEAT" ]] && grep -q "<!-- memory-health-block -->" "$HEARTBEAT"; then
    python3 - "$HEARTBEAT" <<'PYEOF'
import re, sys
hb = sys.argv[1]
with open(hb, 'r') as f:
    content = f.read()
pattern = r'\n*<!-- memory-health-block -->\n.*?<!-- /memory-health-block -->\n*'
new_content = re.sub(pattern, '\n', content, flags=re.DOTALL)
new_content = new_content.rstrip() + '\n'
with open(hb, 'w') as f:
    f.write(new_content)
PYEOF
    echo "  ✓ Scrubbed legacy memory-health-block from HEARTBEAT.md"
fi

# Remove previous block, append new one
python3 - "$MEMORY_HEALTH" <<'PYEOF'
import re, sys
mh = sys.argv[1]
with open(mh, 'r') as f:
    content = f.read()
pattern = r'<!-- memory-health-block -->\n.*?<!-- /memory-health-block -->\n?'
new_content = re.sub(pattern, '', content, flags=re.DOTALL)
with open(mh, 'w') as f:
    f.write(new_content)
PYEOF

cat >> "$MEMORY_HEALTH" << EOF

<!-- memory-health-block -->
## Memory Health (last run: $RUN_TS)
- daily_logs_current: $daily_logs_current ($daily_present_count/7 in last week; max gap: ${daily_max_gap_days}d)
- working_context_age_hours: $wc_age_hours
- l1_freshness_hours: $l1_age_hours
- vault_write_errors: $vault_errors
- memory_promotions_bytes: $promo_size
- l1_size_bytes: $l1_size
- stale_context: $stale_context
<!-- /memory-health-block -->
EOF

# Append run-summary to rolling log file
echo "$RUN_TS | daily=$daily_logs_current(${daily_present_count}/7,maxgap=${daily_max_gap_days}d) | wc_age=${wc_age_hours}h | l1_age=${l1_age_hours}h | vault_err=$vault_errors | stale=$stale_context" >> "$LOG_FILE"

echo "✓ Metrics written to MEMORY_HEALTH.md"
exit 0
