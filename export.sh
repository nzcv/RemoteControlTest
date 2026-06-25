#!/usr/bin/env bash
set -euo pipefail

# Export the memory snapshot files harvested by the RemoteControlTest runner's
# measuring endpoints (/api/startMeasuring, /api/dtMeasuring, /api/stopMeasuring)
# out of an .xcresult bundle.
#
# XCTMemoryMetric attaches the app's memory graphs to the result bundle; this
# script pulls every attachment out and reports the .memgraph / .memgraphset
# snapshots so they can be opened in Xcode's memory graph debugger or `leaks`.
#
# Usage:
#   ./export.sh <path/to/Result.xcresult> [output-dir]
#
# Defaults the output directory to "<xcresult-name>-attachments" next to the
# bundle when omitted; override with the second argument or OUTPUT_DIR.

usage() {
  echo "Usage: $0 <path/to/Result.xcresult> [output-dir]" >&2
}

RESULT_BUNDLE_PATH="${1:-${RESULT_BUNDLE_PATH:-}}"
if [[ -z "$RESULT_BUNDLE_PATH" ]]; then
  echo "Missing .xcresult path." >&2
  usage
  exit 64
fi

if [[ ! -d "$RESULT_BUNDLE_PATH" ]]; then
  echo "No .xcresult bundle at: $RESULT_BUNDLE_PATH" >&2
  exit 66
fi

DEFAULT_OUTPUT_DIR="${RESULT_BUNDLE_PATH%.xcresult}-attachments"
OUTPUT_DIR="${2:-${OUTPUT_DIR:-$DEFAULT_OUTPUT_DIR}}"

rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"

xcrun xcresulttool export attachments \
  --path "$RESULT_BUNDLE_PATH" \
  --output-path "$OUTPUT_DIR"

MEMGRAPH_ATTACHMENTS=()
while IFS= read -r attachment; do
  MEMGRAPH_ATTACHMENTS+=("$attachment")
done < <(
  find "$OUTPUT_DIR" \( \
    -name "*.memgraphset" -o \
    -name "*.memgraph" -o \
    -name "*memgraph*.tar.gz" \
  \) -print | sort
)

if (( ${#MEMGRAPH_ATTACHMENTS[@]} > 0 )); then
  echo "Exported memory snapshot files to $OUTPUT_DIR:"
  printf '  %s\n' "${MEMGRAPH_ATTACHMENTS[@]}"
else
  echo "No .memgraph / .memgraphset snapshots found under $OUTPUT_DIR." >&2
  echo "All exported attachments still live in $OUTPUT_DIR." >&2
  exit 1
fi
