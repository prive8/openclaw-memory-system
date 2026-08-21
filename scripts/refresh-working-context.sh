#!/bin/bash
# Working-context refresh — bumps Last Updated if >24h stale, adds Recent Activity
# entry pointing at the latest daily log session. Designed to run before the L1
# sync cron so the L1 agentTurn reads a fresh working-context.
#
# Deterministic. No LLM. Idempotent (no-op if fresh).
#
# Recommended schedule: 03:55 EDT (5 min before L1 sync at 04:00).

set -euo pipefail

VAULT="${VAULT_ROOT:-/path/to/your/vault}"
WC="$VAULT/Agent-OpenClaw/working-context.md"
DAILY_DIR="$VAULT/Agent-OpenClaw/daily"
LOG="${LOG_DIR:-/path/to/your/logs}/working-context-refresh.log"

mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S %Z') | $*" | tee -a "$LOG"; }

# Preflight — vault preflight guard (don't write outside canonical root)
case "$WC" in
    "$VAULT"/*) ;;
    *) log "❌ working-context path not under canonical vault root: $WC"; exit 1 ;;
esac

if [[ ! -f "$WC" ]]; then
    log "❌ working-context.md not found at $WC"
    exit 1
fi

# Parse Last Updated date
last_date=$(grep -m1 "^## Last Updated" -A 1 "$WC" | tail -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
if [[ -z "$last_date" ]]; then
    log "❌ could not parse Last Updated date from $WC"
    exit 1
fi

last_epoch=$(date -d "$last_date" +%s 2>/dev/null || echo 0)
now_epoch=$(date +%s)
age_hours=$(( (now_epoch - last_epoch) / 3600 ))

if [[ $age_hours -lt 24 ]]; then
    log "✓ fresh (${age_hours}h); no-op"
    exit 0
fi

log "→ stale (${age_hours}h); refreshing"

# Find most recent daily log file with content (size > 200 bytes) AND a Session block
latest_daily_name=""
latest_session_title=""
while IFS= read -r d; do
    fname=$(basename "$d" .md)
    size=$(wc -c < "$d")
    if [[ $size -lt 200 ]]; then continue; fi
    if grep -q "^## Session" "$d"; then
        latest_daily_name="$fname"
        latest_session_title=$(grep -m1 "^## Session" "$d" | sed 's/^## Session — //' | sed 's/[[:space:]]*$//')
        break
    fi
done < <(ls -1r "$DAILY_DIR"/*.md 2>/dev/null | head -10)

today_date=$(date '+%Y-%m-%d')
today_time=$(date '+%H:%M %Z')

# Apply edits via Python (single-line stdin avoids heredoc escaping pain).
# Args: <wc_path> <today_date> <today_time> <latest_daily_name> <latest_session_title>
python3 - "$WC" "$today_date" "$today_time" "$latest_daily_name" "$latest_session_title" <<'PYEOF'
import re, sys, os

wc_path, today_date, today_time, latest_daily_name, latest_session_title = sys.argv[1:6]

with open(wc_path, 'r') as f:
    content = f.read()

# 1. Bump ## Last Updated
new_header = f'## Last Updated\n- {today_date} ({today_time})'
new_content, n = re.subn(
    r'## Last Updated\n- \d{4}-\d{2}-\d{2} \([^\)]+\)',
    new_header,
    content,
    count=1,
)
if n == 0:
    print(f'WARN: did not match Last Updated line in {wc_path}', file=sys.stderr)
    sys.exit(2)
content = new_content

# 2. Add Recent Activity entry if we have a session anchor and today isn't already there
if latest_daily_name and latest_session_title:
    if not re.search(rf'^- {today_date}:', content, re.MULTILINE):
        new_entry = f'- {today_date}: **Auto-refresh** — see `daily/{latest_daily_name}.md` (last session: {latest_session_title}).\n'
        new_content, n2 = re.subn(
            r'(## Recent Activity\n)',
            r'\1' + new_entry,
            content,
            count=1,
        )
        if n2 == 0:
            print(f'WARN: did not match Recent Activity section in {wc_path}', file=sys.stderr)
            sys.exit(3)
        content = new_content

# Atomic write via temp file + rename
tmp = wc_path + '.tmp.refresh'
with open(tmp, 'w') as f:
    f.write(content)
os.replace(tmp, wc_path)

print(f'wrote: {wc_path}')
PYEOF

log "✓ refreshed → $today_date $today_time (anchor: ${latest_daily_name:-<none>})"
exit 0