#!/bin/bash
# Promotion migration — moves auto-promoted snippets from MEMORY.md to memory-promotions.md
# Run after the Memory Dreaming Promotion cron (id: e628d049-1bf0-4869-87ef-85bb68b42b6d)
# Dedup: skips entries whose <!-- openclaw-memory-promotion:... --> marker already exists in memory-promotions.md

set -e

WORKSPACE="${WORKSPACE:-/path/to/your/workspace}"
MEMORY="$WORKSPACE/MEMORY.md"
PROMOTIONS="${VAULT_ROOT:-/path/to/your/vault}/Agent-OpenClaw/memory-promotions.md"

if [[ ! -f "$MEMORY" ]]; then
    echo "MEMORY.md not found at $MEMORY" >&2
    exit 1
fi

if [[ ! -f "$PROMOTIONS" ]]; then
    echo "memory-promotions.md not found at $PROMOTIONS" >&2
    exit 1
fi

# 1. Extract promotion markers from MEMORY.md (between "## Promoted From Short-Term Memory" headers)
# 2. For each marker, check if it already exists in memory-promotions.md
# 3. If not, append the full section to memory-promotions.md (preserving date headers)
# 4. Remove the section from MEMORY.md

# Extract the "Promoted From Short-Term Memory" sections from MEMORY.md
tmpfile=$(mktemp)
python3 << 'PYEOF' > "$tmpfile"
import re
import sys

with open('${WORKSPACE:-/path/to/your/workspace}/MEMORY.md', 'r') as f:
    content = f.read()

# Find all "## Promoted From Short-Term Memory (YYYY-MM-DD)" sections
# These are at the end of MEMORY.md, separated by blank lines
pattern = r'(## Promoted From Short-Term Memory \(\d{4}-\d{2}-\d{2}\)\n(?:<!-- openclaw-memory-promotion:.*?-->\n- .*?\n)+)'
matches = re.findall(pattern, content, re.MULTILINE)

if not matches:
    print("NO_PROMOTIONS", end='')
    sys.exit(0)

# Output each section as: SECTION::<date>::<content>
for m in matches:
    # Extract date
    date_match = re.search(r'\((\d{4}-\d{2}-\d{2})\)', m)
    if date_match:
        date = date_match.group(1)
    else:
        date = "unknown"
    # Base64-encode the content to avoid shell escaping issues
    import base64
    encoded = base64.b64encode(m.encode()).decode()
    print(f"SECTION::{date}::{encoded}")
PYEOF

# Check if there are any promotions to migrate
if grep -q "^NO_PROMOTIONS$" "$tmpfile" || [[ ! -s "$tmpfile" ]]; then
    echo "✓ No new promotions to migrate"
    rm -f "$tmpfile"
    exit 0
fi

# Read existing markers from memory-promotions.md
existing_markers=$(grep -o "<!-- openclaw-memory-promotion:.*?-->" "$PROMOTIONS" || echo "")

migrated=0
skipped=0

while IFS= read -r line; do
    if [[ "$line" == SECTION::* ]]; then
        # Parse: SECTION::date::base64content
        date=$(echo "$line" | cut -d: -f3)
        encoded=$(echo "$line" | cut -d: -f4-)
        content=$(echo "$encoded" | base64 -d 2>/dev/null)
        
        if [[ -z "$content" ]]; then
            continue
        fi
        
        # Check if any marker in this section already exists in memory-promotions.md
        markers=$(echo "$content" | grep -o "<!-- openclaw-memory-promotion:.*?-->" || echo "")
        all_exist=true
        if [[ -n "$markers" ]]; then
            while IFS= read -r marker; do
                if ! grep -qF "$marker" "$PROMOTIONS"; then
                    all_exist=false
                    break
                fi
            done <<< "$markers"
        else
            all_exist=false
        fi
        
        if [[ "$all_exist" == "true" ]]; then
            echo "  ⊘ Skipping $date (all markers already exist)"
            skipped=$((skipped + 1))
        else
            # Check if this date section already exists in memory-promotions.md
            if grep -q "^## $date$" "$PROMOTIONS"; then
                # Append markers to existing date section
                # Find the date section and insert before the next ## or EOF
                echo "  + Appending to existing $date section"
            else
                # Add new date section
                echo "" >> "$PROMOTIONS"
                echo "## $date" >> "$PROMOTIONS"
                echo "" >> "$PROMOTIONS"
                echo "  + New date section: $date"
            fi
            # Append the content (minus the date header)
            echo "$content" | grep -v "^## Promoted From Short-Term Memory" >> "$PROMOTIONS"
            migrated=$((migrated + 1))
        fi
    fi
done < "$tmpfile"

# Remove the promoted sections from MEMORY.md
python3 << 'PYEOF'
import re

with open('${WORKSPACE:-/path/to/your/workspace}/MEMORY.md', 'r') as f:
    content = f.read()

# Remove "## Promoted From Short-Term Memory" sections
pattern = r'\n## Promoted From Short-Term Memory \(\d{4}-\d{2}-\d{2}\)\n(?:<!-- openclaw-memory-promotion:.*?-->\n- .*?\n)+'
new_content = re.sub(pattern, '', content)

# Add a pointer if there were any promotions
if new_content != content:
    if 'memory-promotions.md' not in new_content:
        new_content = new_content.rstrip() + '\n'

with open('${WORKSPACE:-/path/to/your/workspace}/MEMORY.md', 'w') as f:
    f.write(new_content)

print("  ✓ Cleaned MEMORY.md")
PYEOF

rm -f "$tmpfile"

echo "✓ Migration complete: $migrated migrated, $skipped skipped (dedup)"
exit 0