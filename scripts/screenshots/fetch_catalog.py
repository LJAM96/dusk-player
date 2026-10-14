#!/usr/bin/env python3
"""Builds the screenshot demo catalogue from titles.json.

Stdlib + ImageMagick (`magick`). No accounts or API keys:
  - Plex Discover (discover.provider.plex.tv, the same metadata Plex shows):
    title-level metadata, poster, background and clear logo for movies and shows.
  - TVmaze (api.tvmaze.com): season and episode lists (titles, summaries,
    air dates, runtimes) and season posters, which Discover only serves to
    signed-in clients.

Only metadata and cover art are used. Episode thumbnails are crops of the
show's background art (never episode stills), and the player itself plays
neutral public-domain NASA frames
(player-frames/, see mock_plex.py). Output is the gitignored cache
.build/screenshots-cache/catalog/ (catalog.json + images) in the format
mock_plex.py reads. Downloads are cached; pass --refresh to refetch metadata.

  python3 -I scripts/screenshots/fetch_catalog.py [--refresh]
"""

import argparse
import html
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(REPO, ".build", "screenshots-cache", "catalog")
RAW = os.path.join(REPO, ".build", "screenshots-cache", "downloads")
UA = {"User-Agent": "dusk-screenshots/1.0 (+https://github.com/marvinvr/dusk-player)"}

REFRESH = False


def log(msg):
    print(f"[fetch] {msg}", flush=True)


def get_json(url, cache_name):
    path = os.path.join(RAW, "json", cache_name + ".json")
    if os.path.exists(path) and not REFRESH:
        with open(path) as f:
            return json.load(f)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as r:
                data = json.load(r)
            break
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < 3:
                time.sleep(3)
                continue
            raise
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f)
    time.sleep(0.6)  # TVmaze allows ~20 calls / 10 s
    return data


def download(url, name):
    path = os.path.join(RAW, "img", name)
    if os.path.exists(path) and os.path.getsize(path) > 0:
        return path
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
        data = r.read()
    with open(path, "wb") as f:
        f.write(data)
    return path


def magick(*args):
    subprocess.run(["magick", *args], check=True)


def poster_jpg(src, rel):
    dst = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    magick(src + "[0]", "-resize", "600x900^", "-gravity", "center", "-extent", "600x900",
           "-strip", "-quality", "86", dst)
    return rel


def art_jpg(src, rel):
    dst = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    magick(src + "[0]", "-resize", "1920x1080^", "-gravity", "center", "-extent", "1920x1080",
           "-strip", "-quality", "84", dst)
    return rel


ZOOMS = [(1.0, "center"), (1.35, "west"), (1.35, "east"), (1.6, "center"), (1.25, "north"), (1.5, "southwest")]


def episode_thumb(backgrounds, n, rel):
    """Episode thumbnail = a crop of the show's background art (no episode stills)."""
    dst = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    src = backgrounds[n % len(backgrounds)]
    zoom, gravity = ZOOMS[(n // len(backgrounds)) % len(ZOOMS)]
    w, h = int(1920 / zoom), int(1080 / zoom)
    magick(src + "[0]", "-resize", "1920x1080^", "-gravity", "center", "-extent", "1920x1080",
           "-gravity", gravity, "-crop", f"{w}x{h}+0+0", "+repage", "-resize", "960x540!",
           "-strip", "-quality", "84", dst)
    return rel


def clean(text):
    text = html.unescape(re.sub(r"<[^>]+>", "", text or "")).strip()
    return re.sub(r"\s+", " ", text)


def short(text, limit=420):
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(". ", 1)[0]
    return cut + "." if not cut.endswith(".") else cut


# ---------------------------------------------------------------------------

PLEX = "https://discover.provider.plex.tv"
PLEX_HEADERS = {"Accept": "application/json", "X-Plex-Product": "Dusk Screenshots",
                "X-Plex-Client-Identifier": "dusk-screenshots-cli"}


def get_plex(path, cache_name):
    path_cache = os.path.join(RAW, "json", cache_name + ".json")
    if os.path.exists(path_cache) and not REFRESH:
        with open(path_cache) as f:
            return json.load(f)
    req = urllib.request.Request(PLEX + path, headers={**UA, **PLEX_HEADERS})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.load(r)
    os.makedirs(os.path.dirname(path_cache), exist_ok=True)
    with open(path_cache, "w") as f:
        json.dump(data, f)
    return data


def plex_lookup(spec, kind):
    """Discover search -> full metadata of the best match ('movies' or 'tv')."""
    slug = spec["slug"]
    q = urllib.parse.quote(spec["query"])
    found = get_plex(f"/library/search?query={q}&searchTypes={kind}&searchProviders=discover&limit=10",
                     f"plex-search-{slug}")
    hits = [x["Metadata"] for r in found["MediaContainer"].get("SearchResults", [])
            for x in r.get("SearchResult", []) if x.get("Metadata")]
    want = re.sub(r"[^a-z0-9]", "", spec["query"].lower())

    def score(m):
        name = re.sub(r"[^a-z0-9]", "", (m.get("title") or "").lower())
        year_ok = not spec.get("year") or str(m.get("year")) == str(spec["year"])
        return year_ok * 2 + (name == want) * 2 + (want in name or name in want)

    hits.sort(key=score, reverse=True)
    if not hits or score(hits[0]) < 3:
        raise SystemExit(f"Plex Discover: no confident match for {spec['query']} {spec.get('year', '')}; "
                         f"adjust 'query'/'year' in titles.json")
    rk = hits[0]["ratingKey"]
    return get_plex(f"/library/metadata/{rk}", f"plex-meta-{slug}")["MediaContainer"]["Metadata"][0]


def plex_images(m):
    imgs = {i["type"]: i["url"] for i in m.get("Image", [])}
    return {
        "poster": imgs.get("coverPoster") or m.get("thumb"),
        "art": imgs.get("background") or m.get("art"),
        "logo": imgs.get("clearLogo"),
    }


def logo_png(url, slug):
    rel = f"logos/{slug}.png"
    dst = os.path.join(OUT, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    magick(download(url, f"{slug}-logo.png") + "[0]", "-resize", "1200x400>", "-strip", dst)
    return rel


def plex_common(m, slug):
    img = plex_images(m)
    if not img["poster"] or not img["art"]:
        raise SystemExit(f"Plex Discover: {m.get('title')} lacks poster or background art")
    poster_src = download(img["poster"], f"{slug}-poster.jpg")
    art_src = download(img["art"], f"{slug}-art.jpg")
    out = {
        "slug": slug,
        "title": re.sub(r"\s*\(\d{4}\)$", "", m["title"]),
        "year": m.get("year"),
        "summary": short(clean(m.get("summary"))),
        "tagline": m.get("tagline"),
        "genres": [g["tag"] for g in m.get("Genre", [])][:3],
        "studio": m.get("studio"),
        "audience_rating": m.get("audienceRating"),
        "content_rating": m.get("contentRating"),
        "poster": poster_jpg(poster_src, f"posters/{slug}.jpg"),
        "art": art_jpg(art_src, f"art/{slug}.jpg"),
    }
    if img["logo"]:
        out["logo"] = logo_png(img["logo"], slug)
    return out, art_src


def fetch_show(spec):
    slug = spec["slug"]
    q = urllib.parse.quote(spec["query"])
    results = get_json(f"https://api.tvmaze.com/search/shows?q={q}", f"tvmaze-search-{slug}")
    shows = [r["show"] for r in results]
    if spec.get("year"):
        shows = [s for s in shows if (s.get("premiered") or "")[:4] == str(spec["year"])] or shows
    if not shows:
        raise SystemExit(f"TVmaze: no match for {spec['query']}")
    show_id = shows[0]["id"]
    show = get_json(f"https://api.tvmaze.com/shows/{show_id}?embed[]=seasons&embed[]=episodes",
                    f"tvmaze-show-{slug}")
    images = get_json(f"https://api.tvmaze.com/shows/{show_id}/images", f"tvmaze-images-{slug}")

    def url_of(img):
        res = img["resolutions"]
        return (res.get("original") or res.get("medium"))["url"]

    common, plex_art = plex_lookup_show(spec)
    poster = common["poster"]
    bgs = sorted((i for i in images if i["type"] == "background"),
                 key=lambda i: (not i.get("main"), -(i["resolutions"]["original"].get("width") or 0)))
    # Episode thumbnails are cropped from the show's background art.
    bg_files = [plex_art] + [download(url_of(b), f"{slug}-bg{n}.jpg") for n, b in enumerate(bgs[:3])]
    runtime = show.get("averageRuntime") or show.get("runtime") or 30

    episodes = show["_embedded"]["episodes"]
    seasons_meta = {s["number"]: s for s in show["_embedded"]["seasons"]}
    seasons = []
    n = 0
    for number in sorted({e["season"] for e in episodes})[: spec.get("max_seasons", 3)]:
        eps = [e for e in episodes if e["season"] == number and e.get("number")]
        if not eps:
            continue
        meta = seasons_meta.get(number) or {}
        s_poster = poster
        if meta.get("image"):
            s_poster = poster_jpg(download(meta["image"]["original"], f"{slug}-s{number:02d}.jpg"),
                                  f"seasons/{slug}-s{number:02d}.jpg")
        out_eps = []
        for e in eps:
            out_eps.append({
                "index": e["number"],
                "title": e["name"],
                "summary": short(clean(e.get("summary"))) or f"Episode {e['number']} of season {number}.",
                "duration_min": e.get("runtime") or runtime,
                "originally_available_at": e.get("airdate") or None,
                "thumb": episode_thumb(bg_files, n, f"episodes/{slug}-s{number:02d}e{e['number']:02d}.jpg"),
            })
            n += 1
        seasons.append({
            "index": number,
            "title": f"Season {number}",
            "year": int((meta.get("premiereDate") or eps[0].get("airdate") or "0")[:4]) or None,
            "poster": s_poster,
            "summary": short(clean(meta.get("summary"))),
            "episodes": out_eps,
        })
    log(f"show  {common['title']} ({common['year']}): "
        f"{len(seasons)} seasons, {n} episodes, logo={'logo' in common}")
    return {**common, "seasons": seasons}


def plex_lookup_show(spec):
    return plex_common(plex_lookup(spec, "tv"), spec["slug"])


def fetch_movie(spec):
    m = plex_lookup(spec, "movies")
    common, _ = plex_common(m, spec["slug"])
    log(f"movie {common['title']} ({common['year']}) logo={'logo' in common}")
    return {
        **common,
        "originally_available_at": m.get("originallyAvailableAt"),
        "duration_min": round((m.get("duration") or 6_000_000) / 60000),
        "directors": [d["tag"] for d in m.get("Director", [])][:2],
    }


def main():
    global REFRESH
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--titles", default=os.path.join(HERE, "titles.json"))
    parser.add_argument("--refresh", action="store_true", help="refetch metadata (images stay cached)")
    args = parser.parse_args()
    REFRESH = args.refresh

    with open(args.titles) as f:
        titles = json.load(f)
    catalog = {
        "movies": [fetch_movie(m) for m in titles["movies"]],
        "shows": [fetch_show(s) for s in titles["shows"]],
    }
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "catalog.json"), "w") as f:
        json.dump(catalog, f, indent=1)
    log(f"wrote {os.path.relpath(OUT, REPO)}/catalog.json "
        f"({len(catalog['movies'])} movies, {len(catalog['shows'])} shows)")


if __name__ == "__main__":
    sys.exit(main())
