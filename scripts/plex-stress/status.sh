#!/usr/bin/env bash
# Shows item counts of the stress libraries and running Plex activities.
set -euo pipefail
cd "$(dirname "$0")"; . ./common.sh
plex_remote "T=\$T B=\$B python3 -" <<'PY'
import json, os, urllib.request
T, B = os.environ["T"], os.environ["B"]
def get(path):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(f"{B}{path}{sep}X-Plex-Token={T}", headers={"Accept": "application/json"})
    return json.load(urllib.request.urlopen(req))["MediaContainer"]
for d in get("/library/sections").get("Directory", []):
    if not d["title"].startswith("Stress"): continue
    counts = []
    for typ, label in ((1, "movies"), (2, "shows"), (3, "seasons"), (4, "episodes")):
        # Plex only reports totalSize when the container start is given too.
        n = get(f"/library/sections/{d['key']}/all?type={typ}&X-Plex-Container-Start=0&X-Plex-Container-Size=0").get("totalSize", 0)
        if n: counts.append(f"{n} {label}")
    state = "scanning" if d.get("refreshing") else "idle"
    print(f"{d['title']} (section {d['key']}, {d.get('agent')}, {state}): {', '.join(counts) or 'empty'}")
for a in get("/activities").get("Activity", []):
    print("activity:", a.get("title"), a.get("subtitle") or "", a.get("progress"))
PY
