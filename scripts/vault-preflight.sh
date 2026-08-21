#!/bin/bash
# Vault write preflight — fails fast if path isn't under canonical Windows vault
# Usage: vault-preflight.sh <target-path> && <actual-write-command>

VAULT_ROOT="${VAULT_ROOT:-/path/to/your/vault}"

target="${1:-}"
if [[ -z "$target" ]]; then
    echo "Usage: $0 <target-path>" >&2
    exit 1
fi

# Resolve to absolute path
real_target=$(realpath -m "$target" 2>/dev/null || echo "$target")
real_vault=$(realpath -m "$VAULT_ROOT" 2>/dev/null || echo "$VAULT_ROOT")

# Check prefix match
if [[ "$real_target" != "$real_vault"/* && "$real_target" != "$real_vault" ]]; then
    echo "❌ VAULT PREFLIGHT FAIL: $real_target is not under $real_vault" >&2
    echo "   Canonical vault root: $VAULT_ROOT" >&2
    exit 1
fi

# Success — path is valid
exit 0