#!/bin/bash
# Wrapper for vault writes — runs preflight before any write/edit to a vault path
# Usage: vault-write.sh <vault-relative-path> <content>
#   or:  echo "content" | vault-write.sh <vault-relative-path>
#
# If path is absolute and outside vault, fails fast.
# If path is relative, resolves to ${VAULT_ROOT:-/path/to/your/vault}/<path>

set -e

VAULT_ROOT="${VAULT_ROOT:-/path/to/your/vault}"
PREFLIGHT="${WORKSPACE:-/path/to/your/workspace}/scripts/vault-preflight.sh"

target="${1:-}"
if [[ -z "$target" ]]; then
    echo "Usage: $0 <vault-path> [content]" >&2
    echo "   or: echo 'content' | $0 <vault-path>" >&2
    exit 1
fi

# If relative, prepend vault root
if [[ "$target" != /* ]]; then
    target="$VAULT_ROOT/$target"
fi

# Preflight
if ! bash "$PREFLIGHT" "$target"; then
    exit 1
fi

# Read content from arg or stdin
if [[ -n "${2:-}" ]]; then
    content="$2"
else
    content=$(cat)
fi

# Ensure parent dir exists
parent_dir=$(dirname "$target")
mkdir -p "$parent_dir"

# Write atomically
tmp="${target}.tmp.$$"
echo "$content" > "$tmp"
mv "$tmp" "$target"

echo "✓ wrote: $target"
exit 0