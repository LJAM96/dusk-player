#!/usr/bin/env bash
# One command for the App Store screenshots:
#   fetch demo catalogue (cached) -> capture raw screens in the simulators -> compose.
#
#   scripts/screenshots/make.sh [iphone|ipad|tv|all] [--refresh] [--no-build]
#
# --refresh   refetch title metadata (after editing titles.json the new titles
#             are fetched anyway; images stay cached)
# --no-build  reuse the last Debug build for the capture
# Output: screenshots/1.7/<platform>/ (see docs/screenshots.md).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM="${1:-all}"
shift || true
FETCH_ARGS=()
CAPTURE_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --refresh) FETCH_ARGS+=(--refresh) ;;
    --no-build) CAPTURE_ARGS+=(--no-build) ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

python3 -I "$SCRIPT_DIR/fetch_catalog.py" ${FETCH_ARGS[@]+"${FETCH_ARGS[@]}"}
"$SCRIPT_DIR/capture.sh" "$PLATFORM" ${CAPTURE_ARGS[@]+"${CAPTURE_ARGS[@]}"}
"$SCRIPT_DIR/compose.sh" "$PLATFORM" --strict
