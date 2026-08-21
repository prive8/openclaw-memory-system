#!/bin/bash
# Embedding version check — verifies the live ollama model matches the indexed version
# Run before any memory reindex or after ollama model updates
# Warns if mismatch; blocks reindex unless --force is passed

set -e

INDEX_FILE="${VAULT_ROOT:-/path/to/your/vault}/Agent-OpenClaw/embedding-index.json"
OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
FORCE="${1:-}"

if [[ ! -f "$INDEX_FILE" ]]; then
    echo "❌ embedding-index.json not found at $INDEX_FILE" >&2
    exit 1
fi

# Expected version_id from index
EXPECTED_VERSION=$(python3 -c "import json; d=json.load(open('$INDEX_FILE')); print(d['embedding_model']['version_id'])")
EXPECTED_DIM=$(python3 -c "import json; d=json.load(open('$INDEX_FILE')); print(d['embedding_model']['embedding_dim'])")

# Live model info from ollama
LIVE_INFO=$(curl -s "$OLLAMA_URL/api/show" -d '{"name":"nomic-embed-text"}' 2>/dev/null)
if [[ -z "$LIVE_INFO" ]]; then
    echo "❌ Could not reach ollama at $OLLAMA_URL" >&2
    exit 1
fi

LIVE_FAMILY=$(echo "$LIVE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('details',{}).get('family','unknown'))" 2>/dev/null || echo "unknown")
LIVE_PARAMS=$(echo "$LIVE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('details',{}).get('parameter_size','unknown'))" 2>/dev/null || echo "unknown")
LIVE_QUANT=$(echo "$LIVE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('details',{}).get('quantization_level','unknown'))" 2>/dev/null || echo "unknown")
LIVE_MODIFIED=$(echo "$LIVE_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('modified_at','unknown'))" 2>/dev/null || echo "unknown")

# Construct live version_id (same format as index)
LIVE_DATE=$(echo "$LIVE_MODIFIED" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
LIVE_VERSION="nomic-embed-text:${LIVE_FAMILY}:${LIVE_PARAMS}:${LIVE_QUANT}:${LIVE_DATE}"

echo "Expected: $EXPECTED_VERSION"
echo "Live:     $LIVE_VERSION"

if [[ "$EXPECTED_VERSION" == "$LIVE_VERSION" ]]; then
    echo "✓ Model version matches index"
    exit 0
else
    echo ""
    echo "⚠️  MODEL VERSION MISMATCH"
    echo ""
    echo "This means the live embedding model differs from what was used to build the index."
    echo "Queries will return incorrect results until the index is rebuilt with the new model."
    echo ""
    echo "Options:"
    echo "  1. Revert ollama model:  ollama pull nomic-embed-text:<expected-tag>"
    echo "  2. Rebuild index:        update embedding-index.json, then reindex corpus"
    echo ""
    if [[ "$FORCE" == "--force" ]]; then
        echo "⚠️  --force passed, continuing despite mismatch"
        exit 0
    else
        echo "Pass --force to proceed anyway."
        exit 1
    fi
fi
