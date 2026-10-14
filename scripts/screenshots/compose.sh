#!/usr/bin/env bash
# Composes marketing App Store screenshots from the raw captures.
#   scripts/screenshots/compose.sh [iphone|ipad|tv|all] [--only 01-home] [--preview] [--strict]
# Config: scripts/screenshots/compose/panels.json. See docs/screenshots.md#compositing.
set -euo pipefail
exec python3 "$(cd "$(dirname "$0")" && pwd)/compose/compose.py" "$@"
