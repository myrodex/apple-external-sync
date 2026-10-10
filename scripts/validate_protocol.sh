#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python_bin="${PYTHON_BIN:-python3}"

"$python_bin" "$root_dir/scripts/validate_protocol.py"

if command -v npx >/dev/null 2>&1; then
  npx --yes @redocly/cli@1.34.0 lint "$root_dir/openapi/reminders-sync.yaml"
else
  echo "npx is required for OpenAPI linting" >&2
  exit 2
fi
