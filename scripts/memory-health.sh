#!/bin/bash
# Memory health metrics — computes daily-log freshness, working-context age, L1 sync status, vault write errors
# Writes a metrics block to HEARTBEAT.md for visibility at session start
# Recommended schedule: 04:05 EDT (after L1 sync at 04:00)

set -e

VAULT="${VAULT_ROOT:-/path/to/your/vault}"
DAILY_DIR="$VAULT/Agent-OpenClaw/daily"
WORKING_CONTEXT="$VAULT/Agent-OpenClaw/working-context.md"
L1="$VAULT/Agent-OpenClaw/layer-1-memory.md"
HEARTBEAT="${WORKSPACE:-/path/to/your/workspace}/HEARTBEAT.md"
LOG_FILE="${LOG_DIR:-/path/to/your/logs}/memory-health.log"

# Ensure log dir exists
mkdir -p "$(dirname "$LOG_FILE")"

metric() {
    local key="$1"
    local value="$2"
    echo "  $key: $value"
}

echo "=== Memory Health Metrics ($(date '+%Y-%m-%d %H:%M:%S %Z')) ==="

# 1. Daily-log freshness — check if today + yesterday + day-before exist
TODAY=$(date '+%Y-%m-%d')
YESTERDAY=$(date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || date -v-1d '+%Y-%m-%d')
DAY_BEFORE=$(date -d '2 days ago' '+%Y-%m-%d' 2>/dev/null || date -v-2d '+%Y-%m-%d')

daily_count=0
[[ -f "$DAILY_DIR/$TODAY.md" && -s "$DAILY_DIR/$TODAY.md" ]] && daily_count=$((daily_count + 1))
[[ -f "$DAILY_DIR/$YESTERDAY.md" && -s "$DAILY_DIR/$YESTERDAY.md" ]] && daily_count=$((daily_count + 1))
[[ -f "$DAILY_DIR/$DAY_BEFORE.md" && -s "$DAILY_DIR/$DAY_BEFORE.md" ]] && daily_count=$((daily_count + 1))

daily_logs_current="true"
[[ $daily_count -lt 2 ]] && daily_logs_current="false"
metric "daily_logs_current" "$daily_logs_current ($daily_count/3 days present)"

# 2. Working-context age — parse "Last Updated" line
if [[ -f "$WORKING_CONTEXT" ]]; then
    last_updated=$(grep -m 1 "^## Last Updated" -A 1 "$WORKING_CONTEXT" | tail -1 | sed 's/^[- ]*//' | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
    if [[ -n "$last_updated" ]]; then
        # Calculate hours since last update
        last_epoch=$(date -d "$last_updated" '+%s' 2>/dev/null || echo "0")
        now_epoch=$(date '+%s')
        if [[ "$last_epoch" != "0" ]]; then
            age_hours=$(( (now_epoch - last_epoch) / 3600 ))
        else
            age_hours="unknown"
        fi
    else
        age_hours="unknown"
    fi
else
    age_hours="missing"
fi
metric "working_context_age_hours" "$age_hours"

# 3. L1 sync status — check "Sync:" line timestamp
if [[ -f "$L1" ]]; then
    sync_line=$(grep -m 1 "^\*\*Sync:" "$L1" | sed 's/\*\*Sync: //' | sed 's/\*\*//')
    if [[ -n "$sync_line" ]]; then
        sync_date=$(echo "$sync_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
        sync_epoch=$(date -d "$sync_date" '+%s' 2>/dev/null || echo "0")
        now_epoch=$(date '+%s')
        if [[ "$sync_epoch" != "0" ]]; then
            sync_age_hours=$(( (now_epoch - sync_epoch) / 3600 ))
            if [[ $sync_age_hours -lt 26 ]]; then
                l1_status="ok"
            else
                l1_status="drift"
            fi
        else
            l1_status="unparseable"
        fi
    else
        l1_status="no_sync_marker"
    fi
else
    l1_status="missing"
fi
metric "l1_sync_status" "$l1_status (age: ${sync_age_hours:-?}h)"

# 4. Vault write errors — count from OpenClaw logs in last 24h
if [[ -d "${LOG_DIR:-/path/to/your/logs}" ]]; then
    vault_errors=$(find ${LOG_DIR:-/path/to/your/logs} -name "*.log" -mtime -1 -exec grep -l "vault.*error\|VAULT PREFLIGHT FAIL" {} \; 2>/dev/null | wc -l)
else
    vault_errors=0
fi
metric "vault_write_errors" "$vault_errors"

# 5. Memory-promotions file size (sanity check it's not exploding)
if [[ -f "$VAULT/Agent-OpenClaw/memory-promotions.md" ]]; then
    promo_size=$(wc -c < "$VAULT/Agent-OpenClaw/memory-promotions.md")
else
    promo_size=0
fi
metric "memory_promotions_bytes" "$promo_size"

# 6. L1 size (should be under 2200 chars)
if [[ -f "$L1" ]]; then
    l1_size=$(wc -c < "$L1")
else
    l1_size=0
fi
metric "l1_size_bytes" "$l1_size"

# Write to HEARTBEAT.md (append/replace a memory-health block)
if [[ -f "$HEARTBEAT" ]]; then
    # Remove old memory-health block if present
    if grep -q "<!-- memory-health-block -->" "$HEARTBEAT"; then
        # Remove old block (between markers, exclusive)
        python3 << 'PYEOF'
import re
with open('${WORKSPACE:-/path/to/your/workspace}/HEARTBEAT.md', 'r') as f:
    content = f.read()
# Remove old block
pattern = r'<!-- memory-health-block -->\n.*?<!-- /memory-health-block -->\n?'
new_content = re.sub(pattern, '', content, flags=re.DOTALL)
with open('${WORKSPACE:-/path/to/your/workspace}/HEARTBEAT.md', 'w') as f:
    f.write(new_content)
PYEOF
    fi
    # Append new block
    cat >> "$HEARTBEAT" << EOF

<!-- memory-health-block -->
## Memory Health (last run: $(date '+%Y-%m-%d %H:%M %Z'))
- daily_logs_current: $daily_logs_current ($daily_count/3 days present)
- working_context_age_hours: $age_hours
- l1_sync_status: $l1_status (age: ${sync_age_hours:-?}h)
- vault_write_errors: $vault_errors
- memory_promotions_bytes: $promo_size
- l1_size_bytes: $l1_size
<!-- /memory-health-block -->
EOF
    echo "✓ Metrics written to HEARTBEAT.md"
fi

# Also log to file
echo "$(date '+%Y-%m-%d %H:%M:%S') | daily=$daily_logs_current | wc_age=${age_hours}h | l1=$l1_status | vault_err=$vault_errors" >> "$LOG_FILE"

echo "✓ Memory health check complete"
exit 0