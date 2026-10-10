#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
spec="$root_dir/openapi/reminders-sync.yaml"
out_dir="${OPENAPI_OUTPUT_DIR:-$root_dir/openapi/dist}"
redocly_version="${REDOCLY_VERSION:-1.34.0}"
generator_version="${OPENAPI_GENERATOR_CLI_VERSION:-2.25.2}"

usage() {
  cat >&2 <<USAGE
Usage: $0 <lint|bundle|generate-swift> [output]

  lint           Validate the source OpenAPI 3.1 document.
  bundle [path]  Resolve local references into one generated YAML file.
  generate-swift [dir]
                 Bundle the contract and generate a Swift 6 client into dir.
USAGE
  exit 2
}

command="${1:-}"
case "$command" in
  lint)
    exec npx --yes "@redocly/cli@$redocly_version" lint "$spec"
    ;;
  bundle)
    output="${2:-$out_dir/reminders-sync.bundle.yaml}"
    mkdir -p "$(dirname "$output")"
    exec npx --yes "@redocly/cli@$redocly_version" bundle "$spec" --output "$output"
    ;;
  generate-swift)
    output="${2:-${OPENAPI_SWIFT_OUTPUT_DIR:-$root_dir/openapi/dist/swift-client}}"
    bundle="$out_dir/reminders-sync.bundle.yaml"
    generator_spec="${TMPDIR:-/tmp}/reminders-sync-openapi-generator.yaml"
    mkdir -p "$output" "$out_dir"
    npx --yes "@redocly/cli@$redocly_version" bundle "$spec" --output "$bundle"
    # OpenAPI Generator requires info.license.url to be absolute while Redocly
    # intentionally keeps the repository-local protocol link. Normalize only
    # the ephemeral generator input; never mutate the checked-in contract.
    BUNDLE_PATH="$bundle" GENERATOR_SPEC="$generator_spec" python3 - <<'PY'
from pathlib import Path
import os

bundle = Path(os.environ["BUNDLE_PATH"]).read_text(encoding="utf-8")
needle = "    url: ../docs/protocol.md"
replacement = "    url: https://www.apache.org/licenses/LICENSE-2.0"
index = bundle.find(needle)
if index < 0:
    raise SystemExit("OpenAPI bundle has no repository-local license URL")
bundle = bundle[:index] + bundle[index:].replace(needle, replacement, 1)
Path(os.environ["GENERATOR_SPEC"]).write_text(bundle, encoding="utf-8")
PY
    exec npx --yes "@openapitools/openapi-generator-cli@$generator_version" generate \
      -i "$generator_spec" \
      -g swift6 \
      -o "$output" \
      --additional-properties=projectName=RemindersSyncAPI,responseAs=AsyncAwait
    ;;
  *)
    usage
    ;;
esac
