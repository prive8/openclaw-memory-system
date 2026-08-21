#!/bin/bash
# Events view — generate human-readable daily summaries from events.log JSONL
# Usage: events-view.sh [YYYY-MM-DD]  (default: today)
#        events-view.sh --list         (list all dates with events)
#        events-view.sh --week         (last 7 days)

set -e

EVENTS="${VAULT_ROOT:-/path/to/your/vault}/Agent-OpenClaw/events.log"

if [[ ! -f "$EVENTS" ]]; then
    echo "❌ events.log not found at $EVENTS" >&2
    exit 1
fi

MODE="${1:-}"
if [[ "$MODE" == "--list" ]]; then
    grep -oE '"ts":"[0-9]{4}-[0-9]{2}-[0-9]{2}' "$EVENTS" | sed 's/"ts":"//' | sort -u
    exit 0
elif [[ "$MODE" == "--week" ]]; then
    for i in 0 1 2 3 4 5 6; do
        date -d "$i days ago" '+%Y-%m-%d' 2>/dev/null || date -v-${i}d '+%Y-%m-%d'
    done | while read d; do
        "$0" "$d"
        echo ""
    done
    exit 0
fi

TARGET="${MODE:-$(date '+%Y-%m-%d')}"
TMPFILE=$(mktemp)
trap "rm -f $TMPFILE" EXIT

echo "=== Events for $TARGET ==="
echo ""

# Filter to tmpfile
grep "\"ts\":\"$TARGET" "$EVENTS" > "$TMPFILE" 2>/dev/null || true

if [[ ! -s "$TMPFILE" ]]; then
    echo "(no events)"
    exit 0
fi

# Inline python that reads the tmpfile
python3 -c "
import json
import sys

with open('$TMPFILE') as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue

        ts = e.get('ts', '?')
        time = ts.split('T')[1][:5] if 'T' in ts else '?'
        kind = e.get('kind', 'event')
        title = e.get('title', 'untitled')
        summary = e.get('summary', '')
        links = e.get('links', [])
        tags = e.get('tags', [])

        print(f'**{time}** [{kind}] {title}')
        if summary:
            suffix = '...' if len(summary) > 200 else ''
            print(f'  {summary[:200]}{suffix}')
        if links:
            print(f'  links: {', '.join(links)}')
        if tags:
            print(f'  tags: {', '.join(tags)}')
        print()
"
