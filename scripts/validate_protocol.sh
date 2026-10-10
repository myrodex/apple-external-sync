#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -n "${PYTHON_BIN:-}" ]]; then
  python_bin="$PYTHON_BIN"
elif [[ -x "$root_dir/.venv/bin/python" ]]; then
  python_bin="$root_dir/.venv/bin/python"
else
  python_bin="python3"
fi

"$python_bin" "$root_dir/scripts/validate_protocol.py"

if command -v npx >/dev/null 2>&1; then
  npx --yes @redocly/cli@1.34.0 lint "$root_dir/openapi/reminders-sync.yaml"
else
  echo "npx is required for OpenAPI linting" >&2
  exit 2
fi
