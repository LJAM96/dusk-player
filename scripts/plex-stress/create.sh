#!/usr/bin/env bash
# Creates a huge dummy Plex library on the demo server to stress-test Dusk.
#   scripts/plex-stress/create.sh [movies=60000] [shows=1000] [episodes_per_show=20]
# One tiny clip is hardlinked for every item (almost no disk space). Libraries use the
# Personal Media agent, so Plex does no online lookups. Undo with delete.sh.
set -euo pipefail
cd "$(dirname "$0")"; . ./common.sh
MOVIES="${1:-60000}"; SHOWS="${2:-1000}"; EPS="${3:-20}"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
ffmpeg -loglevel error -y -f lavfi -i "color=c=0x202030:s=320x180:d=2:r=24" \
  -f lavfi -i "anullsrc=r=48000:cl=stereo" -t 2 -c:v libx264 -preset veryfast -c:a aac -b:a 32k "$tmp/clip.mkv"
ssh "$PLEX_SSH" "mkdir -p '$STRESS_HOST_DIR'"
scp -q "$tmp/clip.mkv" "$PLEX_SSH:$STRESS_HOST_DIR/.clip.mkv"

echo "creating $MOVIES movies and $SHOWS shows x $EPS episodes in $PLEX_SSH:$STRESS_HOST_DIR ..."
ssh "$PLEX_SSH" python3 - "$STRESS_HOST_DIR" "$MOVIES" "$SHOWS" "$EPS" <<'PY'
import os, random, sys
root, movies, shows, eps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
clip = os.path.join(root, ".clip.mkv")
rnd = random.Random(42)
words = ("Amber Black Broken Cold Crimson Dark Distant Echo Fallen Final Golden Hidden Iron Last Lost "
         "Midnight Northern Open Quiet Rising Secret Silent Silver Summer Twisted Under Velvet Wild Winter "
         "Yellow Zero Atlas Bridge City Dawn Empire Fire Garden Harbor Island Journey Kingdom Light Machine "
         "Night Ocean Path Queen River Signal Storm Tower Union Valley Water Xenon Youth Zone").split()
def title(): return " ".join(rnd.sample(words, rnd.choice((2, 3))))
import shutil
n = 0
def link(dst):
    # filesystems cap hardlinks per inode (~65k), so start a fresh copy of the clip every 50k links
    global n
    if os.path.exists(dst): return
    src = clip if n < 50000 else f"{clip}.{n // 50000}"
    if not os.path.exists(src): shutil.copy(clip, src)
    os.link(src, dst); n += 1
m = os.path.join(root, "Movies"); os.makedirs(m, exist_ok=True)
for i in range(movies):
    t = f"{title()} {i:05d} ({rnd.randint(1950, 2026)})"
    link(os.path.join(m, t + ".mkv"))
tv = os.path.join(root, "TV")
for s in range(shows):
    show = f"{title()} {s:04d} ({rnd.randint(1980, 2026)})"
    for e in range(eps):
        season = e // 10 + 1
        d = os.path.join(tv, show, f"Season {season:02d}"); os.makedirs(d, exist_ok=True)
        link(os.path.join(d, f"{show} - S{season:02d}E{e % 10 + 1:02d}.mkv"))
print("files done")
PY

plex_remote "
add() { curl -s -o /dev/null -w \"\$1: %{http_code}\n\" -X POST -G \"\$B/library/sections\" --data-urlencode \"name=\$1\" --data-urlencode \"type=\$2\" \
  --data-urlencode agent=tv.plex.agents.none --data-urlencode \"scanner=\$3\" --data-urlencode language=xn --data-urlencode \"location=\$4\" --data-urlencode \"X-Plex-Token=\$T\"; }
add 'Stress Movies' movie 'Plex Movie' '$STRESS_PLEX_DIR/Movies'
[ $SHOWS -gt 0 ] && add 'Stress TV' show 'Plex TV Series' '$STRESS_PLEX_DIR/TV'
true"
echo "Libraries added, Plex is scanning now (check with status.sh)."
