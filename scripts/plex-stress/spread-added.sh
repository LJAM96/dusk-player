#!/usr/bin/env bash
# Spreads the stress libraries' "date added" over 2012..2026 (Plex ignores <dateadded> in NFOs and
# stamps every item with its scan time). Run once after create.sh's scan has finished (status.sh).
# Movies get a date between max(2012, their year) and Oct 2026; a show's episodes get the show's
# date plus a few days per episode. Items are edited in month batches, so this takes a minute.
set -euo pipefail
cd "$(dirname "$0")"; . ./common.sh
plex_remote "T=\$T B=\$B python3 -" <<'PY'
import collections, datetime, json, os, random, urllib.parse, urllib.request
T, B = os.environ["T"], os.environ["B"]
def call(path, method="GET"):
    sep = "&" if "?" in path else "?"
    req = urllib.request.Request(f"{B}{path}{sep}X-Plex-Token={T}", method=method, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)["MediaContainer"] if method == "GET" else r.status
def items(key, typ):
    out, start = [], 0
    while True:
        page = call(f"/library/sections/{key}/all?type={typ}&X-Plex-Container-Start={start}&X-Plex-Container-Size=5000").get("Metadata", [])
        out += page; start += len(page)
        if len(page) < 5000: return out
def date_for(seed, year):
    lo = datetime.date(max(2012, year or 2012), 1, 1); hi = datetime.date(2026, 10, 1)
    return lo + datetime.timedelta(days=random.Random(seed).randrange(max(1, (hi - lo).days)))
def apply(key, typ, dated):
    buckets = collections.defaultdict(list)                       # one edit per month and type
    for rk, day in dated:
        buckets[day.replace(day=15)].append(rk)
    for day, keys in sorted(buckets.items()):
        when = int(datetime.datetime(day.year, day.month, day.day, 12).timestamp())
        for i in range(0, len(keys), 500):
            ids = ",".join(keys[i:i + 500])
            call(f"/library/sections/{key}/all?type={typ}&id={ids}&addedAt.value={when}&addedAt.locked=1", "PUT")
    print(f"section {key} type {typ}: {len(dated)} items in {len(buckets)} months")
for d in call("/library/sections").get("Directory", []):
    if not d["title"].startswith("Stress"): continue
    if d["type"] == "movie":
        apply(d["key"], 1, [(m["ratingKey"], date_for(int(m["ratingKey"]), m.get("year"))) for m in items(d["key"], 1)])
    elif d["type"] == "show":
        shows = {s["ratingKey"]: date_for(int(s["ratingKey"]), s.get("year")) for s in items(d["key"], 2)}
        eps = items(d["key"], 4)
        apply(d["key"], 4, [(e["ratingKey"], min(datetime.date(2026, 10, 1), shows.get(e.get("grandparentRatingKey"), datetime.date(2020, 1, 1))
                            + datetime.timedelta(days=30 * e.get("parentIndex", 1) + 3 * e.get("index", 1)))) for e in eps])
        apply(d["key"], 2, list(shows.items()))
PY
