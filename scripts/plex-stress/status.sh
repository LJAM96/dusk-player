#!/usr/bin/env bash
# Shows item counts of the stress libraries and running Plex activities.
set -euo pipefail
cd "$(dirname "$0")"; . ./common.sh
plex_remote "
curl -s -H 'Accept: application/json' \"\$B/library/sections?X-Plex-Token=\$T\" | python3 -c '
import json,sys,urllib.request
for d in json.load(sys.stdin)[\"MediaContainer\"].get(\"Directory\",[]):
    if d[\"title\"].startswith(\"Stress\"): print(d[\"key\"], d[\"title\"])' | while read k name; do
  for typ in 1 2 4; do n=\$(curl -s -H 'Accept: application/json' \"\$B/library/sections/\$k/all?type=\$typ&X-Plex-Container-Size=0&X-Plex-Token=\$T\" | python3 -c 'import json,sys;print(json.load(sys.stdin)[\"MediaContainer\"].get(\"totalSize\",0))'); [ \"\$n\" != 0 ] && echo \"\$name type=\$typ: \$n\"; done
done
curl -s -H 'Accept: application/json' \"\$B/activities?X-Plex-Token=\$T\" | python3 -c 'import json,sys;[print(\"activity:\",a.get(\"title\"),a.get(\"subtitle\"),a.get(\"progress\")) for a in json.load(sys.stdin)[\"MediaContainer\"].get(\"Activity\",[])]'"
