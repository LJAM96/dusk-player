#!/usr/bin/env bash
# Creates a huge dummy Plex library on the demo server to stress-test Dusk.
#   scripts/plex-stress/create.sh [movies=60000] [shows=1000] [episodes_per_show=20]
# 'Stress Movies' and 'Stress TV' are real movie/show libraries (Plex NFO agents, no online
# lookups): every title gets an NFO with year, genres, cast, rating and added date, plus a
# poster and background hardlinked from a small shared set. Every item gets its own copy of a tiny
# silent clip (~4 KB) with a unique id in its title tag: Plex hashes media files and treats identical
# files (or hardlinks) as renames of one another, so shared clips collapse into a single item.
# Plex ignores <dateadded>: run spread-added.sh after the scan. Undo with delete.sh, watch the scan
# with status.sh.
set -euo pipefail
cd "$(dirname "$0")"; . ./common.sh
MOVIES="${1:-60000}"; SHOWS="${2:-1000}"; EPS="${3:-20}"

if plex_remote "curl -s \"\$B/library/sections?X-Plex-Token=\$T\"" | grep -q 'title="Stress'; then
  echo "Stress libraries already exist on the server; run delete.sh first." >&2; exit 1
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ffmpeg -loglevel error -y -f lavfi -i "color=c=0x202030:s=320x180:d=2:r=24" \
  -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 2 -c:v libx264 -preset veryfast -c:a aac -b:a 32k \
  -metadata title=STRESSID00000000 -write_crc32 0 "$tmp/clip.mkv"
# Shared artwork: 12 gradient posters (2:3) and 6 backgrounds (16:9).
colors=(0x1d2b64:0xf8cdda 0x0f2027:0x2c5364 0x42275a:0x734b6d 0x141e30:0x243b55 0x3a1c71:0xffaf7b
        0x134e5e:0x71b280 0x2c3e50:0xfd746c 0x200122:0x6f0000 0x0b486b:0xf56217 0x1f1c2c:0x928dab
        0x16222a:0x3a6073 0x4b134f:0xc94b4b)
mkdir -p "$tmp/art"
for i in "${!colors[@]}"; do
  c0=${colors[$i]%%:*}; c1=${colors[$i]##*:}
  ffmpeg -loglevel error -y -f lavfi -i "gradients=s=600x900:c0=$c0:c1=$c1:x0=0:y0=0:x1=600:y1=900:d=1" -frames:v 1 "$tmp/art/poster$i.jpg"
  [ "$i" -lt 6 ] && ffmpeg -loglevel error -y -f lavfi -i "gradients=s=1280x720:c0=$c1:c1=$c0:x0=0:y0=0:x1=1280:y1=720:d=1" -frames:v 1 "$tmp/art/fanart$i.jpg"
done
ssh "$PLEX_SSH" "mkdir -p '$STRESS_HOST_DIR/.art'"
scp -q "$tmp/clip.mkv" "$PLEX_SSH:$STRESS_HOST_DIR/.clip.mkv"
scp -q "$tmp"/art/*.jpg "$PLEX_SSH:$STRESS_HOST_DIR/.art/"

echo "creating $MOVIES movies and $SHOWS shows x $EPS episodes in $PLEX_SSH:$STRESS_HOST_DIR ..."
ssh "$PLEX_SSH" python3 - "$STRESS_HOST_DIR" "$MOVIES" "$SHOWS" "$EPS" <<'PY'
import datetime, os, random, sys
from concurrent.futures import ThreadPoolExecutor
from xml.sax.saxutils import escape
root, movies, shows, eps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
words = ("Amber Black Broken Cold Crimson Dark Distant Echo Fallen Final Golden Hidden Iron Last Lost "
         "Midnight Northern Open Quiet Rising Secret Silent Silver Summer Twisted Under Velvet Wild Winter "
         "Yellow Zero Atlas Bridge City Dawn Empire Fire Garden Harbor Island Journey Kingdom Light Machine "
         "Night Ocean Path Queen River Signal Storm Tower Union Valley Water Xenon Youth Zone").split()
first = "Ada Ben Cara Dan Eva Finn Gia Hugo Iris Jon Kai Lena Max Nora Owen Pia Ravi Sara Tom Uma Vic Wes Yara Zoe".split()
last = "Adler Brooks Chen Diaz Evans Fox Garcia Hart Ito Jensen Khan Lee Moreau Novak Ortiz Park Quinn Rossi Silva Tanaka Ueda Varga Weber Young".split()
people = [f"{f} {l}" for f in first for l in last]                      # 576 names
directors, actors = people[:150], people[150:]
movie_genres = {"Drama": 28, "Comedy": 20, "Action": 15, "Thriller": 12, "Crime": 8, "Romance": 8, "Adventure": 7,
                "Horror": 6, "Science Fiction": 5, "Fantasy": 4, "Mystery": 4, "Family": 4, "Animation": 4,
                "Documentary": 4, "History": 2, "Music": 2, "War": 2, "Western": 1}
show_genres = {"Drama": 30, "Comedy": 25, "Crime": 12, "Reality": 8, "Documentary": 8, "Animation": 7,
               "Science Fiction": 6, "Mystery": 6, "Action": 6, "Family": 5, "Fantasy": 4, "Talk": 2}
studios = "Northlight Pictures|Harbor Films|Ironwood Studios|Velvet Media|Atlas Entertainment|Quiet River".split("|")
sets = [f"The {w} Collection" for w in words[:60]]

def pick_genres(rnd, table):
    out = []
    for _ in range(rnd.choice((1, 2, 2, 3))):
        g = rnd.choices(list(table), list(table.values()))[0]
        if g not in out: out.append(g)
    return out
def year(rnd):
    return min(2026, int(1950 + 76 * rnd.random() ** 0.6))              # skewed towards recent years
def title(rnd):
    return " ".join(rnd.sample(words, rnd.choice((2, 3))))
def tag(name, value):
    return f"  <{name}>{escape(str(value))}</{name}>\n"

art = os.path.join(root, ".art")
template = open(os.path.join(root, ".clip.mkv"), "rb").read(); marker = template.index(b"STRESSID00000000")
def new_clip(dst, uid):
    if not os.path.exists(dst):
        with open(dst, "wb") as f: f.write(template[:marker] + b"STRESS%010d" % uid + template[marker + 16:])
def link(src, dst):
    # 12 posters / 6 backgrounds shared by 61k folders stay far below the ~65k hardlinks per inode
    if not os.path.exists(dst): os.link(src, dst)
def write(path, text):
    with open(path, "w") as f: f.write(text)
def artwork(rnd, d):
    link(os.path.join(art, f"poster{rnd.randrange(12)}.jpg"), os.path.join(d, "poster.jpg"))
    link(os.path.join(art, f"fanart{rnd.randrange(6)}.jpg"), os.path.join(d, "fanart.jpg"))

def movie(i):
    rnd = random.Random(i)                                               # per item, so threads stay deterministic
    y = year(rnd); name = f"{title(rnd)} {i:05d}"; base = f"{name} ({y})"
    d = os.path.join(root, "Movies", base); os.makedirs(d, exist_ok=True)
    new_clip(os.path.join(d, base + ".mkv"), i)
    artwork(rnd, d)
    nfo = "<movie>\n" + tag("title", name) + tag("year", y) + tag("premiered", f"{y}-{rnd.randint(1, 12):02d}-{rnd.randint(1, 28):02d}")
    nfo += tag("plot", f"A {rnd.choice(words).lower()} story about {rnd.choice(words).lower()} and {rnd.choice(words).lower()}.")
    nfo += tag("rating", round(rnd.uniform(3.5, 9.3), 1)) + tag("runtime", rnd.randint(80, 160)) + tag("mpaa", rnd.choice(("G", "PG", "PG-13", "R")))
    nfo += tag("studio", rnd.choice(studios))
    nfo += "".join(tag("genre", g) for g in pick_genres(rnd, movie_genres)) + tag("director", rnd.choice(directors))
    nfo += "".join(f"  <actor><name>{a}</name></actor>\n" for a in rnd.sample(actors, 3))
    if rnd.random() < 0.02: nfo += f"  <set><name>{rnd.choice(sets)}</name></set>\n"
    write(os.path.join(d, base + ".nfo"), nfo + "</movie>\n")

def show(s):
    rnd = random.Random(1_000_000 + s)
    y = year(rnd); name = f"{title(rnd)} {s:04d}"; base = f"{name} ({y})"
    sd = os.path.join(root, "TV", base); os.makedirs(sd, exist_ok=True)
    artwork(rnd, sd)
    nfo = "<tvshow>\n" + tag("title", name) + tag("year", y) + tag("premiered", f"{y}-{rnd.randint(1, 12):02d}-01")
    nfo += tag("plot", f"A series about {rnd.choice(words).lower()} {rnd.choice(words).lower()}.") + tag("rating", round(rnd.uniform(5, 9.5), 1))
    nfo += tag("studio", rnd.choice(studios))
    nfo += "".join(tag("genre", g) for g in pick_genres(rnd, show_genres))
    nfo += "".join(f"  <actor><name>{a}</name></actor>\n" for a in rnd.sample(actors, 3))
    write(os.path.join(sd, "tvshow.nfo"), nfo + "</tvshow>\n")
    for e in range(eps):
        season, ep = e // 10 + 1, e % 10 + 1
        d = os.path.join(sd, f"Season {season:02d}"); os.makedirs(d, exist_ok=True)
        f = f"{name} - S{season:02d}E{ep:02d}"
        new_clip(os.path.join(d, f + ".mkv"), 1_000_000 + s * 1000 + e)
        aired = datetime.date(min(y + season - 1, 2026), 1, 1) + datetime.timedelta(days=7 * ep)
        write(os.path.join(d, f + ".nfo"), "<episodedetails>\n" + tag("title", f"{rnd.choice(words)} {rnd.choice(words)}")
              + tag("season", season) + tag("episode", ep) + tag("aired", aired) + tag("runtime", rnd.randint(20, 60))
              + tag("plot", "An episode.") + "</episodedetails>\n")

# The share is NFS: every small file costs a round trip, so write many items at once.
with ThreadPoolExecutor(48) as pool:
    for n, _ in enumerate(pool.map(movie, range(movies)), 1):
        if n % 5000 == 0: print(f"  {n} movies", flush=True)
    for n, _ in enumerate(pool.map(show, range(shows)), 1):
        if n % 250 == 0: print(f"  {n} shows", flush=True)
print("files done")
PY

plex_remote "
add() { curl -s -o /dev/null -w \"\$1: %{http_code}\n\" -X POST -G \"\$B/library/sections\" --data-urlencode \"name=\$1\" --data-urlencode \"type=\$2\" \
  --data-urlencode \"agent=\$3\" --data-urlencode \"scanner=\$4\" --data-urlencode language=en-US --data-urlencode \"location=\$5\" --data-urlencode \"X-Plex-Token=\$T\"; }
add 'Stress Movies' movie tv.plex.agents.nfo.movie 'Plex Movie' '$STRESS_PLEX_DIR/Movies'
[ $SHOWS -gt 0 ] && add 'Stress TV' show tv.plex.agents.nfo.series 'Plex TV Series' '$STRESS_PLEX_DIR/TV'
true"
# No per-item media analysis on the dummy clips (credits, previews, loudness...): it would keep Plex busy for days.
plex_remote "T=\$T B=\$B python3 -" <<'PY'
import json, os, urllib.request
T, B = os.environ["T"], os.environ["B"]
req = urllib.request.Request(f"{B}/library/sections?X-Plex-Token={T}", headers={"Accept": "application/json"})
for d in json.load(urllib.request.urlopen(req))["MediaContainer"].get("Directory", []):
    if not d["title"].startswith("Stress"): continue
    have = {p["id"] for p in json.load(urllib.request.urlopen(urllib.request.Request(
        f"{B}/library/sections/{d['key']}/prefs?X-Plex-Token={T}", headers={"Accept": "application/json"})))["MediaContainer"]["Setting"]}
    prefs = "&".join(f"{k}=0" for k in ("enableBIFGeneration", "enableCreditsMarkerGeneration", "enableIntroMarkerGeneration",
                                         "enableAdMarkerGeneration", "enableVoiceActivityGeneration", "enableLoudnessAnalysis",
                                         "enableCinemaTrailers") if k in have)
    r = urllib.request.urlopen(urllib.request.Request(f"{B}/library/sections/{d['key']}/prefs?{prefs}&X-Plex-Token={T}", method="PUT"))
    print(f"{d['title']}: analysis off ({r.status})")
PY
echo "Libraries added, Plex is scanning now (check with status.sh)."
