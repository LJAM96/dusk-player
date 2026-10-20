#!/usr/bin/env bash
# Removes the stress libraries from the demo Plex server and deletes the dummy files.
set -euo pipefail
cd "$(dirname "$0")"; . ./common.sh
plex_remote "
curl -s -H 'Accept: application/json' \"\$B/library/sections?X-Plex-Token=\$T\" | python3 -c '
import json,sys
for d in json.load(sys.stdin)[\"MediaContainer\"].get(\"Directory\",[]):
    if d[\"title\"].startswith(\"Stress\"): print(d[\"key\"])' | while read k; do
  curl -s -o /dev/null -w \"deleted section \$k: %{http_code}\n\" -X DELETE \"\$B/library/sections/\$k?X-Plex-Token=\$T\"
done"
ssh "$PLEX_SSH" "case '$STRESS_HOST_DIR' in */Stress) rm -rf '$STRESS_HOST_DIR' && echo 'files removed';; *) echo 'refusing to delete $STRESS_HOST_DIR'; exit 1;; esac"
