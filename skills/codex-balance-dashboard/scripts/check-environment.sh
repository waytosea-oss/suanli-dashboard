#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CODEX_ROOT="${CODEX_HOME:-$HOME/.codex}"
SESSIONS_DIR="$CODEX_ROOT/sessions"

echo "Repository: $ROOT_DIR"

if command -v swift >/dev/null 2>&1; then
  swift --version | head -n 1
else
  echo "Swift: missing"
  exit 1
fi

echo "Codex home: $CODEX_ROOT"
if [[ -d "$SESSIONS_DIR" ]]; then
  COUNT="$(find "$SESSIONS_DIR" -type f -name '*.jsonl' | wc -l | tr -d ' ')"
  echo "Sessions: $SESSIONS_DIR ($COUNT jsonl files)"
else
  echo "Sessions: missing at $SESSIONS_DIR"
fi
