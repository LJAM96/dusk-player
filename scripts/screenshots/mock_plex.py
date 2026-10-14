#!/usr/bin/env python3
"""Mock plex.tv + Plex Media Server(s) for Dusk's App Store screenshots.

Stdlib only. Serves the demo catalogue built by fetch_catalog.py
(.build/screenshots-cache/catalog/catalog.json, from titles.json), arranged by
scenario.json into a demo account with several servers:

  http://127.0.0.1:<port>          plex.tv  (account, Home users, resources)
  http://127.0.0.1:<port + n>      one Plex Media Server per scenario server

The app is pointed here by the DEBUG-only screenshot mode
(`-DuskScreenshotMode YES -DuskScreenshotPlexTV http://127.0.0.1:<port>`).
Every token is accepted. Unknown endpoints answer an empty MediaContainer and
are logged as UNHANDLED so new app calls are easy to spot.

Playable media is generated on demand with ffmpeg from a neutral public-domain
frame in player-frames/ (never a scene from the real title; scenario.json's
"player_frames" picks one per item): an H.264/AAC MP4 with the title's
runtime and real subtitle/audio tracks, served with HTTP Range support.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
CACHE = os.path.join(REPO, ".build", "screenshots-cache")
CONTENT = os.path.join(CACHE, "catalog")
FRAMES = os.path.join(HERE, "player-frames")
MEDIA_CACHE = os.path.join(CACHE, "media")
NOW = int(time.time())
TS = 1760000000  # stable "updatedAt" used in image URLs
PMS_VERSION = "1.42.1.10060-4e8b05daf"

LOG_LOCK = threading.Lock()
MEDIA_LOCK = threading.Lock()


def log(msg):
    with LOG_LOCK:
        sys.stdout.write(time.strftime("%H:%M:%S ") + msg + "\n")
        sys.stdout.flush()


def stable_int(text, modulo=900000):
    return int(hashlib.sha1(text.encode()).hexdigest()[:8], 16) % modulo + 1000


# --------------------------------------------------------------------------
# Catalogue model
# --------------------------------------------------------------------------

class Catalog:
    def __init__(self, catalog, scenario):
        self.scenario = scenario
        self.items = {}         # ratingKey -> dict(kind, data, ...)
        self.by_ref = {}        # "slug" / "show/s/e" / "show/s" -> ratingKey (first server holding it)
        self.server_refs = {}   # (server name, ref) -> ratingKey
        self.sections = []      # (server, section dict)
        self.servers = []
        self._build(catalog, scenario)

    # -- construction ------------------------------------------------------

    def _build(self, catalog, scenario):
        movies = {m["slug"]: m for m in catalog.get("movies", [])}
        shows = {s["slug"]: s for s in catalog.get("shows", [])}

        assigned = set()
        for server in scenario["servers"]:
            srv = dict(server)
            srv["sections"] = []
            for lib in server["libraries"]:
                section = dict(lib)
                section["server_id"] = server["id"]
                section["items"] = [s for s in lib["items"] if s in (movies if lib["type"] == "movie" else shows)]
                assigned.update(section["items"])
                srv["sections"].append(section)
            self.servers.append(srv)

        # Unassigned titles land in the first library of their type.
        for slugs, kind in ((movies, "movie"), (shows, "show")):
            for slug in slugs:
                if slug in assigned:
                    continue
                for srv in self.servers:
                    target = next((s for s in srv["sections"] if s["type"] == kind), None)
                    if target:
                        target["items"].append(slug)
                        break

        next_movie = 1001
        next_show = 2000
        for srv in self.servers:
            for section in srv["sections"]:
                section["rating_keys"] = []
                for slug in section["items"]:
                    if section["type"] == "movie":
                        rk = str(next_movie)
                        next_movie += 1
                        self.items[rk] = {"kind": "movie", "data": movies[slug], "rk": rk,
                                          "section": section, "server": srv}
                        self.by_ref.setdefault(slug, rk)
                        section["rating_keys"].append(rk)
                    else:
                        show_rk = next_show
                        next_show += 100
                        show = shows[slug]
                        self.items[str(show_rk)] = {"kind": "show", "data": show, "rk": str(show_rk),
                                                    "section": section, "server": srv}
                        self.by_ref.setdefault(slug, str(show_rk))
                        section["rating_keys"].append(str(show_rk))
                        for season in show.get("seasons", []):
                            s_rk = str(show_rk + 10 * season["index"])
                            self.items[s_rk] = {"kind": "season", "data": season, "rk": s_rk, "show": show,
                                                "show_rk": str(show_rk), "section": section, "server": srv}
                            self.by_ref.setdefault(f"{slug}/{season['index']}", s_rk)
                            for ep in season.get("episodes", []):
                                e_rk = str(show_rk + 10 * season["index"] + ep["index"])
                                self.items[e_rk] = {"kind": "episode", "data": ep, "rk": e_rk, "show": show,
                                                    "season": season, "show_rk": str(show_rk),
                                                    "season_rk": s_rk, "section": section, "server": srv}
                                self.by_ref.setdefault(f"{slug}/{season['index']}/{ep['index']}", e_rk)

        for rk, it in self.items.items():
            self.server_refs[(it["server"]["name"], self.ref_of(rk))] = rk

        # Watch state.
        self.view_offset = {}
        self.last_viewed = {}
        self.watched = set()
        for entry in scenario.get("continue_watching", []):
            rk = (self.server_refs.get((entry["server"], entry["ref"])) if "server" in entry
                  else self.by_ref.get(entry["ref"]))
            if not rk:
                log(f"scenario: unknown continue-watching ref {entry['ref']}")
                continue
            duration = self.duration_ms(rk)
            self.view_offset[rk] = int(duration * entry["progress"])
            self.last_viewed[rk] = NOW - 60 * entry["minutes_ago"]
        for ref in scenario.get("watched", []):
            rk = self.by_ref.get(ref)
            if rk:
                self.watched.add(rk)
                self.last_viewed.setdefault(rk, NOW - 86400 * (3 + len(self.watched)))

        # addedAt: scenario order first (newest), then everything else older.
        self.added_at = {}
        order = [self.by_ref[r] for r in scenario.get("recently_added", []) if r in self.by_ref]
        for i, rk in enumerate(order):
            self.added_at[rk] = NOW - 3600 * (5 + 20 * i)
        rest = [rk for rk, it in self.items.items() if it["kind"] in ("movie", "show") and rk not in self.added_at]
        for i, rk in enumerate(sorted(rest)):
            self.added_at[rk] = NOW - 86400 * (30 + 9 * i)
        for rk, it in self.items.items():
            if it["kind"] in ("season", "episode"):
                self.added_at[rk] = self.added_at.get(it["show_rk"], NOW)

    # -- helpers -----------------------------------------------------------

    def server_items(self, server_id):
        return {rk: it for rk, it in self.items.items() if it["server"]["id"] == server_id}

    def duration_ms(self, rk):
        it = self.items[rk]
        if it["kind"] == "movie" or it["kind"] == "episode":
            minutes = it["data"].get("duration_min") or 10
            # Give runtimes a few seconds of texture so they look real.
            return int(minutes * 60000 + (stable_int(rk, 50) - 1000) * 1000 % 47000)
        return 0

    def episodes_of(self, show_rk, season_rk=None):
        out = []
        for rk, it in self.items.items():
            if it["kind"] == "episode" and it["show_rk"] == show_rk and (season_rk is None or it["season_rk"] == season_rk):
                out.append(rk)
        return sorted(out, key=int)

    def seasons_of(self, show_rk):
        return sorted([rk for rk, it in self.items.items() if it["kind"] == "season" and it["show_rk"] == show_rk], key=int)

    def ref_of(self, rk):
        it = self.items[rk]
        if it["kind"] in ("movie", "show"):
            return it["data"]["slug"]
        if it["kind"] == "season":
            return f"{it['show']['slug']}/{it['data']['index']}"
        return f"{it['show']['slug']}/{it['season']['index']}/{it['data']['index']}"

    def content_id(self, rk):
        """Server-independent identity: the same title on two servers merges."""
        it = self.items[rk]
        if it["kind"] in ("movie", "show"):
            return it["data"]["slug"]
        if it["kind"] == "season":
            return f"{it['show']['slug']}-s{it['data']['index']}"
        return f"{it['show']['slug']}-s{it['season']['index']}e{it['data']['index']}"

    # -- JSON shapes -------------------------------------------------------

    def image_path(self, rk, kind):
        return f"/library/metadata/{rk}/{kind}/{TS}"

    def asset_for(self, rk, kind):
        """Relative catalogue path for an image kind of an item."""
        it = self.items.get(rk)
        if not it:
            return None
        d = it["data"]
        if it["kind"] in ("movie", "show"):
            return {"thumb": d.get("poster"), "art": d.get("art"), "clearLogo": d.get("logo")}.get(kind)
        if it["kind"] == "season":
            show = it["show"]
            return {"thumb": d.get("poster") or show.get("poster"), "art": show.get("art"),
                    "clearLogo": show.get("logo")}.get(kind)
        if it["kind"] == "episode":
            show = it["show"]
            return {"thumb": d.get("thumb"), "art": show.get("art"), "clearLogo": show.get("logo")}.get(kind)
        return None

    def images(self, rk, poster_rk=None, art_rk=None, logo_rk=None):
        poster_rk = poster_rk or rk
        art_rk = art_rk or rk
        logo_rk = logo_rk or rk
        out = [
            {"alt": "", "type": "coverPoster", "url": self.image_path(poster_rk, "thumb")},
            {"alt": "", "type": "background", "url": self.image_path(art_rk, "art")},
        ]
        if self.asset_for(logo_rk, "clearLogo"):
            out.append({"alt": "", "type": "clearLogo", "url": self.image_path(logo_rk, "clearLogo")})
        return out

    def section_fields(self, it):
        sec = it["section"]
        return {"librarySectionID": int(sec["key"]), "librarySectionTitle": sec["title"],
                "librarySectionKey": f"/library/sections/{sec['key']}"}

    def watch_fields(self, rk):
        out = {}
        if rk in self.view_offset:
            out["viewOffset"] = self.view_offset[rk]
            out["lastViewedAt"] = self.last_viewed[rk]
        if rk in self.watched:
            out["viewCount"] = 1
            out["lastViewedAt"] = self.last_viewed.get(rk, NOW - 86400 * 7)
        return out

    def media(self, rk):
        dur = self.duration_ms(rk)
        part_id = int(rk) * 10
        base = int(rk) * 100
        subs = [("English", "eng", "en", False), ("Français", "fra", "fr", False),
                ("Deutsch", "deu", "de", False), ("Español", "spa", "es", False), ("Italiano", "ita", "it", False)]
        streams = [
            {"id": base + 1, "streamType": 1, "default": True, "codec": "h264", "index": 0, "bitrate": 7800,
             "bitDepth": 8, "chromaLocation": "left", "chromaSubsampling": "4:2:0", "codedHeight": 1088,
             "codedWidth": 1920, "colorPrimaries": "bt709", "colorRange": "tv", "colorSpace": "bt709",
             "colorTrc": "bt709", "frameRate": 24.0, "height": 1080, "width": 1920, "level": 41,
             "profile": "high", "refFrames": 4, "scanType": "progressive",
             "displayTitle": "1080p (H.264)", "extendedDisplayTitle": "1080p (H.264)"},
            {"id": base + 2, "streamType": 2, "selected": True, "default": True, "codec": "aac", "index": 1,
             "channels": 6, "bitrate": 384, "language": "English", "languageTag": "en", "languageCode": "eng",
             "audioChannelLayout": "5.1", "samplingRate": 48000, "profile": "lc", "title": "Surround 5.1",
             "displayTitle": "English (AAC 5.1)", "extendedDisplayTitle": "Surround 5.1 (English AAC)"},
            {"id": base + 3, "streamType": 2, "codec": "aac", "index": 2, "channels": 2, "bitrate": 160,
             "language": "English", "languageTag": "en", "languageCode": "eng", "audioChannelLayout": "stereo",
             "samplingRate": 48000, "profile": "lc", "title": "Stereo",
             "displayTitle": "English (AAC Stereo)", "extendedDisplayTitle": "Stereo (English AAC)"},
        ]
        for i, (title, code3, tag, sdh) in enumerate(subs):
            stream = {"id": base + 10 + i, "streamType": 3, "codec": "mov_text", "index": 3 + i,
                      "language": title.split(" (")[0] if not title.startswith("English") else "English",
                      "languageTag": tag, "languageCode": code3,
                      "displayTitle": title + (" (MOV_TEXT)" if False else ""),
                      "extendedDisplayTitle": title}
            if sdh:
                stream["hearingImpaired"] = True
                stream["title"] = "SDH"
            streams.append(stream)
        it = self.items[rk]
        if it["kind"] == "movie":
            folder = f"/data/Movies/{it['data']['title']} ({it['data'].get('year', '')})"
        else:
            folder = f"/data/TV/{it['show']['title']}/Season {it['season']['index']:02d}"
        size = int(dur / 1000 * 8_200_000 / 8)
        generated = os.path.join(MEDIA_CACHE, f"{rk}.mp4")
        if os.path.exists(generated):
            # Downloads check the received bytes against this, so once the
            # file exists it has to be the truth.
            size = os.path.getsize(generated)
        return [{
            "id": part_id, "duration": dur, "bitrate": 8200, "width": 1920, "height": 1080,
            "aspectRatio": 1.78, "audioChannels": 6, "audioCodec": "aac", "videoCodec": "h264",
            "videoResolution": "1080", "container": "mp4", "videoFrameRate": "24p",
            "optimizedForStreaming": 1, "audioProfile": "lc", "has64bitOffsets": False, "videoProfile": "high",
            "Part": [{
                "id": part_id, "key": f"/library/parts/{part_id}/{TS}/file.mp4", "duration": dur,
                "file": f"{folder}/{it['data']['title']}.mp4", "size": size, "audioProfile": "lc",
                "container": "mp4", "has64bitOffsets": False, "optimizedForStreaming": True,
                "videoProfile": "high", "Stream": streams,
            }],
        }]

    def markers(self, rk):
        it = self.items[rk]
        dur = self.duration_ms(rk)
        out = []
        base = int(rk) * 100
        if it["kind"] == "episode" and dur > 10 * 60000:
            out.append({"id": base + 50, "type": "intro", "startTimeOffset": 12000, "endTimeOffset": 104000})
        if dur > 3 * 60000:
            credits = 60000 if dur < 30 * 60000 else 95000
            out.append({"id": base + 51, "type": "credits", "startTimeOffset": dur - credits,
                        "endTimeOffset": dur, "final": True})
        return out

    def tags(self, values, start=1):
        return [{"id": stable_int(v), "filter": f"genre={stable_int(v)}", "tag": v} for v in values or []]

    def people(self, values, kind):
        return [{"id": stable_int(kind + v), "filter": f"{kind}={stable_int(kind + v)}", "tag": v} for v in values or []]

    def metadata(self, rk, detail=False):
        it = self.items[rk]
        d = it["data"]
        kind = it["kind"]
        base = {"ratingKey": rk, "type": kind, "title": d["title"], "addedAt": self.added_at.get(rk, NOW),
                "updatedAt": TS, "guid": f"plex://{kind}/dusk-demo-{self.content_id(rk)}"}
        base.update(self.section_fields(it))
        base.update(self.watch_fields(rk))
        if kind == "movie":
            base.update({
                "key": f"/library/metadata/{rk}", "titleSort": d["title"], "studio": d.get("studio"),
                "summary": d.get("summary"), "tagline": d.get("tagline"), "year": d.get("year"),
                "originallyAvailableAt": d.get("originally_available_at"),
                "audienceRating": d.get("audience_rating"),
                "audienceRatingImage": "themoviedb://image.rating" if d.get("audience_rating") else None,
                "thumb": self.image_path(rk, "thumb"), "art": self.image_path(rk, "art"),
                "duration": self.duration_ms(rk), "Image": self.images(rk),
                "Genre": self.tags(d.get("genres")), "Director": self.people(d.get("directors"), "director"),
                "Country": [], "Media": self.media(rk),
            })
            if self.asset_for(rk, "clearLogo"):
                base["clearLogo"] = self.image_path(rk, "clearLogo")
        elif kind == "show":
            eps = self.episodes_of(rk)
            seasons = self.seasons_of(rk)
            base.update({
                "key": f"/library/metadata/{rk}/children", "titleSort": d["title"], "studio": d.get("studio"),
                "summary": d.get("summary"), "year": d.get("year"),
                "originallyAvailableAt": f"{d.get('year')}-01-01" if d.get("year") else None,
                "audienceRating": d.get("audience_rating"),
                "audienceRatingImage": "themoviedb://image.rating" if d.get("audience_rating") else None,
                "thumb": self.image_path(rk, "thumb"), "art": self.image_path(rk, "art"),
                "theme": None, "index": 1, "leafCount": len(eps),
                "viewedLeafCount": sum(1 for e in eps if e in self.watched), "childCount": len(seasons),
                "Image": self.images(rk), "Genre": self.tags(d.get("genres")),
                "duration": self.duration_ms(eps[0]) if eps else None,
            })
            if self.asset_for(rk, "clearLogo"):
                base["clearLogo"] = self.image_path(rk, "clearLogo")
        elif kind == "season":
            show = it["show"]
            eps = self.episodes_of(it["show_rk"], rk)
            base.update({
                "key": f"/library/metadata/{rk}/children", "parentRatingKey": it["show_rk"],
                "parentKey": f"/library/metadata/{it['show_rk']}", "parentTitle": show["title"],
                "parentThumb": self.image_path(it["show_rk"], "thumb"), "parentIndex": 1,
                "parentYear": show.get("year"),
                "index": d["index"], "summary": d.get("summary") or "", "year": d.get("year"),
                "thumb": self.image_path(rk, "thumb"), "art": self.image_path(it["show_rk"], "art"),
                "leafCount": len(eps), "viewedLeafCount": sum(1 for e in eps if e in self.watched),
                "Image": self.images(rk, art_rk=it["show_rk"], logo_rk=it["show_rk"]),
            })
        elif kind == "episode":
            show = it["show"]
            season = it["season"]
            base.update({
                "key": f"/library/metadata/{rk}", "parentRatingKey": it["season_rk"],
                "parentKey": f"/library/metadata/{it['season_rk']}", "parentTitle": season.get("title") or f"Season {season['index']}",
                "parentIndex": season["index"], "parentThumb": self.image_path(it["season_rk"], "thumb"),
                "grandparentRatingKey": it["show_rk"], "grandparentKey": f"/library/metadata/{it['show_rk']}",
                "grandparentTitle": show["title"], "grandparentThumb": self.image_path(it["show_rk"], "thumb"),
                "grandparentArt": self.image_path(it["show_rk"], "art"),
                "grandparentGuid": f"plex://show/dusk-demo-{self.content_id(it['show_rk'])}",
                "index": d["index"], "summary": d.get("summary"), "year": int((d.get("originally_available_at") or str(season.get("year") or show.get("year") or 2024))[:4]),
                "originallyAvailableAt": d.get("originally_available_at"),
                "thumb": self.image_path(rk, "thumb"), "art": self.image_path(it["show_rk"], "art"),
                "duration": self.duration_ms(rk), "audienceRating": None,
                "Image": [{"alt": "", "type": "background", "url": self.image_path(it["show_rk"], "art")}]
                + ([{"alt": "", "type": "clearLogo", "url": self.image_path(it["show_rk"], "clearLogo")}]
                   if self.asset_for(it["show_rk"], "clearLogo") else []),
                "Media": self.media(rk),
                "Director": self.people(d.get("directors"), "director"),
            })
        if detail:
            if kind in ("movie", "episode"):
                base["Marker"] = self.markers(rk)
            base["Guid"] = []
        return {k: v for k, v in base.items() if v is not None}

    # -- hubs ----------------------------------------------------------------

    def continue_watching(self, server_id):
        rks = [rk for rk in self.view_offset if self.items[rk]["server"]["id"] == server_id]
        rks.sort(key=lambda rk: -self.last_viewed[rk])
        return [self.metadata(rk) for rk in rks]

    def recently_added(self, section, limit=None):
        rks = [rk for rk in section["rating_keys"]]
        rks.sort(key=lambda rk: -self.added_at.get(rk, 0))
        if limit:
            rks = rks[:limit]
        return [self.metadata(rk) for rk in rks]


# --------------------------------------------------------------------------
# Media generation
# --------------------------------------------------------------------------

SUBTITLE_LINES = {
    "eng": "",
    "fra": "",
    "deu": "",
    "spa": "",
}


def player_frame(catalog, rk):
    """The neutral frame an item plays: scenario "player_frames" or a stable pick."""
    frames = sorted(f for f in os.listdir(FRAMES) if f.endswith(".jpg"))
    by_rk = {catalog.by_ref.get(ref): name for ref, name in catalog.scenario.get("player_frames", {}).items()}
    name = by_rk.get(rk) or frames[stable_int(rk, len(frames)) - 1000].removesuffix(".jpg")
    return os.path.join(FRAMES, name + ".jpg")


def ensure_media(catalog, rk):
    """Builds (once) an MP4 with the item's runtime from its neutral player frame."""
    os.makedirs(MEDIA_CACHE, exist_ok=True)
    still = player_frame(catalog, rk)
    seconds = max(catalog.duration_ms(rk) / 1000.0, 5)
    tag = hashlib.sha1(f"{catalog.items[rk]['data'].get('title')}|{still}|{seconds:.3f}".encode()).hexdigest()[:10]
    out = os.path.join(MEDIA_CACHE, f"{rk}-{tag}.mp4")
    if os.path.exists(out):
        return out
    with MEDIA_LOCK:
        if os.path.exists(out):
            return out
        # One empty cue per subtitle track keeps the tracks real but silent on screen.
        srt = os.path.join(MEDIA_CACHE, "empty.srt")
        with open(srt, "w") as f:
            f.write("1\n00:00:00,000 --> 00:00:00,500\n \n\n")
        tmp = out + ".tmp.mp4"
        video_in = (["-loop", "1", "-framerate", "2", "-i", still] if still
                    else ["-f", "lavfi", "-i", "color=c=0x101018:s=1920x1080:r=2"])
        cmd = ["ffmpeg", "-y", "-loglevel", "error", *video_in,
               "-f", "lavfi", "-i", "anullsrc=channel_layout=5.1:sample_rate=48000",
               "-f", "lavfi", "-i", "anullsrc=channel_layout=stereo:sample_rate=48000"]
        for _ in range(5):
            cmd += ["-i", srt]
        cmd += ["-map", "0:v", "-map", "1:a", "-map", "2:a"]
        for i in range(5):
            cmd += ["-map", f"{3 + i}:s"]
        cmd += ["-t", f"{seconds:.3f}",
                "-vf", "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,format=yuv420p",
                "-c:v", "libx264", "-preset", "veryfast", "-tune", "stillimage", "-r", "2", "-g", "60",
                "-profile:v", "high", "-level", "4.1",
                "-c:a", "aac", "-b:a:0", "96k", "-b:a:1", "64k", "-c:s", "mov_text",
                "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "title=Surround 5.1",
                "-metadata:s:a:1", "language=eng", "-metadata:s:a:1", "title=Stereo"]
        for i, lang in enumerate(["eng", "fra", "deu", "spa", "ita"]):
            cmd += [f"-metadata:s:s:{i}", f"language={lang}"]
        cmd += ["-disposition:s", "0", "-movflags", "+faststart", tmp]
        log(f"media: generating {rk} ({seconds/60:.1f} min)")
        started = time.time()
        subprocess.run(cmd, check=True)
        os.replace(tmp, out)
        log(f"media: {rk} ready in {time.time() - started:.1f}s ({os.path.getsize(out) // 1024} KB)")
        return out


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

def container(**fields):
    mc = {"size": 0}
    mc.update({k: v for k, v in fields.items() if v is not None})
    for key in ("Metadata", "Directory", "Hub"):
        if key in mc:
            mc["size"] = len(mc[key])
    return {"MediaContainer": mc}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    catalog = None
    role = None         # "plextv" or server dict
    base_port = None

    def log_message(self, fmt, *args):
        pass

    # -- plumbing ----------------------------------------------------------

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _send_file(self, path, content_type, slow=False):
        size = os.path.getsize(path)
        start, end = 0, size - 1
        status = 200
        rng = self.headers.get("Range")
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    if m.group(2):
                        end = min(int(m.group(2)), size - 1)
                elif m.group(2):
                    start = max(size - int(m.group(2)), 0)
                status = 206
        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Cache-Control", "max-age=86400")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(65536, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)
                if slow:
                    time.sleep(0.25)

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        self.do_GET()

    def do_PUT(self):
        self.do_GET()

    def do_DELETE(self):
        self.do_GET()

    def do_GET(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        url = urlparse(self.path)
        query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        try:
            if self.role == "plextv":
                handled = self.plextv(url.path, query)
            else:
                handled = self.pms(url.path, query)
        except Exception as exc:  # keep serving; log loudly
            log(f"ERROR {self.command} {url.path}: {exc!r}")
            import traceback
            traceback.print_exc()
            self._send_json(container(), 500)
            return
        tag = "plex.tv" if self.role == "plextv" else self.role["name"]
        if handled is False:
            log(f"UNHANDLED [{tag}] {self.command} {url.path}?{url.query}")
            self._send_json(container())
        elif not url.path.startswith(("/library/metadata/", "/photo")) or "/children" in url.path:
            log(f"[{tag}] {self.command} {url.path}")

    # -- plex.tv -----------------------------------------------------------

    def user_json(self):
        u = self.catalog.scenario["user"]
        return {"id": u["id"], "uuid": u["uuid"], "username": u["username"], "title": u["title"],
                "friendlyName": u["title"], "email": f"{u['username']}@example.com", "thumb": "",
                "authToken": "dusk-screenshot-demo-token", "homeSize": 1, "homeAdmin": True,
                "subscription": {"active": True, "status": "Active", "plan": "lifetime",
                                 "features": ["sync", "premium_music_metadata"]},
                "settings": []}

    def plextv(self, path, query):
        if path in ("/api/v2/user", "/user", "/users/account", "/api/v2/user/"):
            self._send_json(self.user_json())
        elif path == "/api/v2/user/settings":
            self._send_json([])
        elif path == "/api/v2/home/users":
            u = self.catalog.scenario["user"]
            self._send_json({"id": 1, "name": f"{u['title']}'s Home", "guestUserID": None,
                             "subscription": True, "users": [{
                                 "id": u["id"], "uuid": u["uuid"], "title": u["title"],
                                 "username": u["username"], "email": "", "friendlyName": u["title"],
                                 "thumb": "", "hasPassword": True, "restricted": False, "admin": True,
                                 "guest": False, "protected": False, "home": True}]})
        elif path == "/api/v2/resources":
            out = []
            for srv in self.catalog.servers:
                port = self.base_port + srv["port_offset"]
                out.append({
                    "name": srv["name"], "product": "Plex Media Server", "productVersion": PMS_VERSION,
                    "platform": "Linux", "platformVersion": "6.8", "device": "Docker", "clientIdentifier": srv["id"],
                    "createdAt": "2023-01-01T00:00:00Z", "lastSeenAt": "2026-10-14T09:00:00Z",
                    "provides": "server", "ownerId": None if not srv.get("shared_by") else 1000 + srv["port_offset"],
                    "sourceTitle": srv.get("shared_by"), "publicAddress": "127.0.0.1",
                    "accessToken": f"demo-server-token-{srv['port_offset']}", "owned": not srv.get("shared_by"),
                    "home": False,
                    "synced": False, "relay": True, "presence": True, "httpsRequired": False,
                    "publicAddressMatches": True, "dnsRebindingProtection": False, "natLoopbackSupported": True,
                    "connections": [{"protocol": "http", "address": "127.0.0.1", "port": port,
                                     "uri": f"http://127.0.0.1:{port}", "local": not srv.get("remote", False), "relay": False,
                                     "IPv6": False}],
                })
            self._send_json(out)
        elif path.startswith("/api/v2/pins"):
            self._send_json({"id": 1, "code": "DEMO", "authToken": "dusk-screenshot-demo-token"})
        else:
            return False
        return True

    # -- PMS -----------------------------------------------------------------

    def pms(self, path, query):
        cat = self.catalog
        srv = self.role
        mine = cat.server_items(srv["id"])

        if path == "/identity":
            self._send_json(container(claimed=True, machineIdentifier=srv["id"], version=PMS_VERSION))
        elif path == "/" or path == "":
            self._send_json(container(friendlyName=srv["name"], machineIdentifier=srv["id"], version=PMS_VERSION))
        elif path == "/library/sections":
            dirs = []
            for sec in srv["sections"]:
                agent = "tv.plex.agents.movie" if sec["type"] == "movie" else "tv.plex.agents.series"
                dirs.append({"allowSync": True, "art": f"/library/sections/{sec['key']}/composite/{TS}",
                             "composite": f"/library/sections/{sec['key']}/composite/{TS}",
                             "filters": True, "refreshing": False,
                             "thumb": f"/library/sections/{sec['key']}/composite/{TS}", "key": sec["key"],
                             "type": sec["type"], "title": sec["title"], "agent": agent,
                             "scanner": "Plex Movie" if sec["type"] == "movie" else "Plex TV Series",
                             "language": "en-US", "uuid": hashlib.md5((srv["id"] + sec["key"]).encode()).hexdigest(),
                             "updatedAt": TS, "createdAt": TS - 86400 * 400, "scannedAt": TS,
                             "content": True, "directory": True, "hidden": 0,
                             "Location": [{"id": int(sec["key"]), "path": f"/data/{sec['title']}"}]})
            self._send_json(container(Directory=dirs, title1="Plex Library", allowSync=False))
        elif m := re.fullmatch(r"/library/sections/(\w+)/composite/\d+", path):
            sec = self.section(m.group(1))
            rk = sec["rating_keys"][0] if sec and sec["rating_keys"] else None
            return self.image(rk, "art") if rk else False
        elif m := re.fullmatch(r"/library/sections/(\w+)/all", path):
            self.section_all(self.section(m.group(1)), query)
        elif m := re.fullmatch(r"/library/sections/(\w+)/filters", path):
            sec = self.section(m.group(1))
            self._send_json(container(Directory=[
                {"filter": "genre", "filterType": "string", "key": f"/library/sections/{sec['key']}/genre",
                 "title": "Genre", "type": "filter"},
                {"filter": "year", "filterType": "integer", "key": f"/library/sections/{sec['key']}/year",
                 "title": "Year", "type": "filter"},
                {"filter": "unwatched", "filterType": "boolean", "key": f"/library/sections/{sec['key']}/unwatched",
                 "title": "Unplayed", "type": "filter"}]))
        elif m := re.fullmatch(r"/library/sections/(\w+)/genre", path):
            sec = self.section(m.group(1))
            genres = []
            for rk in sec["rating_keys"]:
                for g in cat.items[rk]["data"].get("genres") or []:
                    if g not in genres:
                        genres.append(g)
            self._send_json(container(Directory=[
                {"fastKey": f"/library/sections/{sec['key']}/all?genre={stable_int(g)}", "key": str(stable_int(g)),
                 "title": g, "type": "genre"} for g in sorted(genres)]))
        elif re.fullmatch(r"/library/sections/(\w+)/(collection|collections)", path):
            self._send_json(container(Directory=[]))
        elif path == "/hubs":
            self.home_hubs(query)
        elif path == "/hubs/continueWatching":
            items = cat.continue_watching(srv["id"])
            self._send_json(container(Hub=[{
                "hubKey": "", "key": "/hubs/continueWatching/items", "title": "Continue Watching",
                "type": "mixed", "hubIdentifier": "home.continue", "context": "hub.home.continue",
                "size": len(items), "more": False, "style": "shelf", "promoted": True, "Metadata": items}]))
        elif path == "/hubs/continueWatching/items":
            self._send_json(container(Metadata=cat.continue_watching(srv["id"])))
        elif m := re.fullmatch(r"/hubs/home/(\w+)", path):
            sec = self.section(query.get("sectionID", ""))
            items = self.hub_items(m.group(1), sec) if sec else []
            self._send_json(container(Metadata=self.page(items, query)))
        elif m := re.fullmatch(r"/hubs/sections/(\w+)", path):
            self.section_hubs(self.section(m.group(1)), query)
        elif path == "/hubs/search":
            self.search(query.get("query", ""))
        elif m := re.fullmatch(r"/library/metadata/(\d+)", path):
            rk = m.group(1)
            if rk not in mine:
                # An empty answer, not a 404: the app re-probes a server on 404.
                self._send_json(container())
                return True
            self._send_json(container(Metadata=[cat.metadata(rk, detail=True)],
                                      librarySectionID=int(mine[rk]["section"]["key"]),
                                      librarySectionTitle=mine[rk]["section"]["title"]))
        elif m := re.fullmatch(r"/library/metadata/(\d+)/children", path):
            rk = m.group(1)
            it = mine.get(rk)
            if not it:
                return False
            if it["kind"] == "show":
                kids = [cat.metadata(s) for s in cat.seasons_of(rk)]
                extra = {"title1": it["data"]["title"], "parentTitle": it["data"]["title"]}
            else:
                kids = [cat.metadata(e, detail=True) for e in cat.episodes_of(it["show_rk"], rk)]
                extra = {"title1": it["show"]["title"], "title2": it["data"].get("title")}
            self._send_json(container(Metadata=kids, key=rk, **extra))
        elif m := re.fullmatch(r"/library/metadata/(\d+)/allLeaves", path):
            rk = m.group(1)
            self._send_json(container(Metadata=[cat.metadata(e, detail=True) for e in cat.episodes_of(rk)]))
        elif m := re.fullmatch(r"/library/metadata/(\d+)/(thumb|art|clearLogo|banner|theme)/\d+", path):
            return self.image(m.group(1), m.group(2))
        elif m := re.fullmatch(r"/library/metadata/(\d+)/(similar|related)", path):
            self._send_json(container(Metadata=[], Hub=[]))
        elif path == "/photo/:/transcode":
            target = unquote(query.get("url", ""))
            target = urlparse(target).path
            m = re.fullmatch(r"/library/metadata/(\d+)/(thumb|art|clearLogo|banner)/\d+", target)
            if m:
                return self.image(m.group(1), m.group(2))
            m = re.fullmatch(r"/library/sections/(\w+)/composite/\d+", target)
            if m:
                sec = self.section(m.group(1))
                return self.image(sec["rating_keys"][0], "art") if sec and sec["rating_keys"] else False
            return False
        elif m := re.fullmatch(r"/library/parts/(\d+)/\d+/file\.\w+", path):
            rk = str(int(m.group(1)) // 10)
            if rk not in mine:
                return False
            media = ensure_media(cat, rk)
            slow = rk in [cat.by_ref.get(r) for r in cat.scenario.get("slow_downloads", [])] and "download" in query
            self._send_file(media, "video/mp4", slow=slow)
            log(f"[{srv['name']}] media {self.command} {rk} range={self.headers.get('Range')}")
        elif re.fullmatch(r"/library/parts/(\d+)/indexes/\w+", path):
            self._send_json(container(), 404)
        elif path in ("/:/timeline", "/:/scrobble", "/:/unscrobble", "/:/progress", "/actions/removeFromContinueWatching"):
            self._send_json(container())
        elif path == "/status/sessions/history/all":
            self.history(query)
        elif path == "/media/providers":
            self._send_json(container(Feature=[], MediaProvider=[]))
        elif path.startswith("/livetv"):
            self._send_json(container())
        else:
            return False
        return True

    # -- PMS helpers ---------------------------------------------------------

    def section(self, key):
        return next((s for s in self.role["sections"] if s["key"] == str(key)), None)

    def page(self, items, query):
        start = int(query.get("X-Plex-Container-Start", 0) or 0)
        size = query.get("X-Plex-Container-Size")
        size = int(size) if size else len(items)
        return items[start:start + size]

    def image(self, rk, kind):
        rel = self.catalog.asset_for(rk, kind)
        path = os.path.join(CONTENT, rel) if rel else None
        if not path or not os.path.exists(path):
            self._send_json(container(), 404)
            log(f"[{self.role['name']}] missing image {rk}/{kind}")
            return True
        self._send_file(path, "image/png" if path.endswith(".png") else "image/jpeg")
        return True

    def section_all(self, sec, query):
        cat = self.catalog
        if not sec:
            self._send_json(container(), 404)
            return
        rks = list(sec["rating_keys"])
        if query.get("type") == "4" and sec["type"] == "show":
            rks = [e for s in sec["rating_keys"] for e in cat.episodes_of(s)]
        genre = query.get("genre")
        if genre:
            wanted = set(genre.split(","))
            rks = [rk for rk in rks if any(str(stable_int(g)) in wanted or g in wanted
                                             for g in cat.items[rk]["data"].get("genres") or [])]
        if query.get("unwatched") == "1":
            rks = [rk for rk in rks if rk not in cat.watched]
        if "year" in query:
            rks = [rk for rk in rks if str(cat.items[rk]["data"].get("year")) == query["year"]]
        sort = (query.get("sort") or "titleSort").split(",")[0]
        field, _, direction = sort.partition(":")
        keyfuncs = {
            "addedAt": lambda rk: cat.added_at.get(rk, 0),
            "year": lambda rk: cat.items[rk]["data"].get("year") or 0,
            "originallyAvailableAt": lambda rk: cat.items[rk]["data"].get("originally_available_at") or str(cat.items[rk]["data"].get("year") or ""),
            "rating": lambda rk: cat.items[rk]["data"].get("audience_rating") or 0,
            "audienceRating": lambda rk: cat.items[rk]["data"].get("audience_rating") or 0,
            "lastViewedAt": lambda rk: cat.last_viewed.get(rk, 0),
            "viewCount": lambda rk: 1 if rk in cat.watched else 0,
            "random": lambda rk: stable_int(rk + str(NOW // 86400)),
            "duration": lambda rk: cat.duration_ms(rk),
        }
        keyfunc = keyfuncs.get(field, lambda rk: cat.items[rk]["data"]["title"].lower().removeprefix("the "))
        rks.sort(key=keyfunc, reverse=direction == "desc")
        total = len(rks)
        items = [cat.metadata(rk) for rk in self.page(rks, query)]
        self._send_json(container(Metadata=items, totalSize=total, offset=int(query.get("X-Plex-Container-Start", 0) or 0),
                                  librarySectionID=int(sec["key"]), librarySectionTitle=sec["title"],
                                  title1=sec["title"], viewGroup=sec["type"]))

    def hub_items(self, name, sec):
        cat = self.catalog
        if name == "recentlyAdded":
            return cat.recently_added(sec)
        if name == "recentlyReleased":
            rks = sorted(sec["rating_keys"], key=lambda rk: -(cat.items[rk]["data"].get("year") or 0))
            return [cat.metadata(rk) for rk in rks]
        if name == "topRated":
            rks = sorted(sec["rating_keys"], key=lambda rk: -(cat.items[rk]["data"].get("audience_rating") or 0))
            return [cat.metadata(rk) for rk in rks]
        if name == "inProgress":
            rks = [rk for rk in cat.view_offset if cat.items[rk]["section"] is sec]
            return [cat.metadata(rk) for rk in rks]
        if name == "recentlyAired":
            eps = [e for s in sec["rating_keys"] for e in cat.episodes_of(s)]
            eps.sort(key=lambda rk: cat.items[rk]["data"].get("originally_available_at") or "", reverse=True)
            return [cat.metadata(rk) for rk in eps[:12]]
        return []

    def hub(self, sec, name, title, identifier, items, count):
        typ = "movie" if sec["type"] == "movie" else ("episode" if name == "recentlyAired" else "show")
        return {"hubKey": "", "key": f"/hubs/home/{name}?type={1 if sec['type'] == 'movie' else 2}&sectionID={sec['key']}",
                "title": title, "type": typ, "hubIdentifier": f"{identifier}.{sec['key']}",
                "context": f"hub.{identifier}", "size": min(len(items), count), "more": len(items) > count,
                "style": "shelf", "promoted": True, "librarySectionID": int(sec["key"]),
                "librarySectionTitle": sec["title"], "librarySectionUUID": "",
                "Metadata": items[:count]}

    def home_hubs(self, query):
        hubs = []
        count = int(query.get("count", 12) or 12)
        for sec in self.role["sections"]:
            if sec["type"] == "movie":
                items = self.hub_items("recentlyAdded", sec)
                hubs.append(self.hub(sec, "recentlyAdded", f"Recently Added in {sec['title']}",
                                     "movie.recentlyadded", items, count))
            else:
                items = self.hub_items("recentlyAdded", sec)
                hubs.append(self.hub(sec, "recentlyAdded", f"Recently Added in {sec['title']}",
                                     "tv.recentlyadded", items, count))
        self._send_json(container(Hub=hubs, allowSync=True, identifier="com.plexapp.plugins.library"))

    def section_hubs(self, sec, query):
        if not sec:
            self._send_json(container(Hub=[]))
            return
        count = int(query.get("count", 12) or 12)
        hubs = []
        if sec["type"] == "movie":
            for name, title, ident in (("inProgress", "Continue Watching", "movie.inprogress"),
                                       ("recentlyAdded", "Recently Added", "movie.recentlyadded"),
                                       ("recentlyReleased", "Recently Released", "movie.recentlyreleased"),
                                       ("topRated", "Top Rated", "movie.toprated")):
                items = self.hub_items(name, sec)
                if items:
                    hubs.append(self.hub(sec, name, title, ident, items, count))
        else:
            for name, title, ident in (("inProgress", "Continue Watching", "tv.inprogress"),
                                       ("recentlyAdded", "Recently Added", "tv.recentlyadded"),
                                       ("recentlyAired", "New Episodes", "tv.recentlyaired"),
                                       ("topRated", "Top Rated", "tv.toprated")):
                items = self.hub_items(name, sec)
                if items:
                    hubs.append(self.hub(sec, name, title, ident, items, count))
        self._send_json(container(Hub=hubs, librarySectionID=int(sec["key"]), librarySectionTitle=sec["title"]))

    def search(self, text):
        cat = self.catalog
        needle = text.strip().lower()
        movies, shows, episodes = [], [], []
        if needle:
            for rk, it in cat.server_items(self.role["id"]).items():
                d = it["data"]
                hay = [d["title"].lower()]
                if not any(h.startswith(needle) or f" {needle}" in h for h in hay):
                    continue
                if it["kind"] == "movie":
                    movies.append(cat.metadata(rk))
                elif it["kind"] == "show":
                    shows.append(cat.metadata(rk))
                elif it["kind"] == "episode":
                    episodes.append(cat.metadata(rk))
        hubs = []
        for title, typ, ident, items in (("Movies", "movie", "movie", movies), ("Shows", "show", "show", shows),
                                         ("Episodes", "episode", "episode", episodes)):
            hubs.append({"title": title, "type": typ, "hubIdentifier": ident, "context": "",
                         "size": len(items[:10]), "more": len(items) > 10, "style": "shelf",
                         "Metadata": items[:10]})
        self._send_json(container(Hub=hubs))

    def history(self, query):
        cat = self.catalog
        out = []
        for rk in sorted(cat.watched, key=lambda r: -cat.last_viewed.get(r, 0)):
            it = cat.items[rk]
            if it["server"]["id"] != self.role["id"]:
                continue
            sec_id = query.get("librarySectionID")
            if sec_id and it["section"]["key"] != sec_id:
                continue
            md = cat.metadata(rk)
            out.append({"historyKey": f"/status/sessions/history/{rk}", "key": md["key"], "ratingKey": rk,
                        "librarySectionID": md.get("librarySectionID"), "title": md["title"], "type": md["type"],
                        "thumb": md.get("thumb"), "viewedAt": cat.last_viewed.get(rk, NOW - 86400),
                        "accountID": 1, "deviceID": 1,
                        "grandparentTitle": md.get("grandparentTitle"),
                        "grandparentKey": md.get("grandparentKey"),
                        "parentIndex": md.get("parentIndex"), "index": md.get("index")})
        self._send_json(container(Metadata=out))


class FastServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        # HTTPServer.server_bind resolves the FQDN, which can take seconds on macOS.
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "127.0.0.1", self.server_address[1]


def serve(handler_cls, port):
    httpd = FastServer(("127.0.0.1", port), handler_cls)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def main():
    global CONTENT
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=47400, help="plex.tv port; servers use port+1…")
    parser.add_argument("--content", default=CONTENT, help="catalogue directory (catalog.json + images, built by fetch_catalog.py)")
    parser.add_argument("--scenario", default=os.path.join(HERE, "scenario.json"))
    parser.add_argument("--prebuild-media", default="", help="comma-separated rating keys to generate up front")
    args = parser.parse_args()

    CONTENT = os.path.abspath(args.content)
    with open(os.path.join(CONTENT, "catalog.json")) as f:
        catalog_json = json.load(f)
    with open(args.scenario) as f:
        scenario = json.load(f)
    catalog = Catalog(catalog_json, scenario)

    def make(role):
        return type("H", (Handler,), {"catalog": catalog, "role": role, "base_port": args.port})

    serve(make("plextv"), args.port)
    log(f"plex.tv mock on http://127.0.0.1:{args.port}")
    for srv in catalog.servers:
        port = args.port + srv["port_offset"]
        serve(make(srv), port)
        titles = ", ".join(f"{s['title']} ({len(s['rating_keys'])})" for s in srv["sections"])
        log(f"PMS '{srv['name']}' on http://127.0.0.1:{port}: {titles}")
    # Print the rating keys so the capture script (and humans) can address titles.
    keymap = os.path.join(CACHE, "rating-keys.json")
    os.makedirs(CACHE, exist_ok=True)
    with open(keymap, "w") as f:
        json.dump({"keys": catalog.by_ref,
                   "durations": {rk: catalog.duration_ms(rk) for rk in catalog.items
                                 if catalog.items[rk]["kind"] in ("movie", "episode")}},
                  f, indent=1, sort_keys=True)
    log(f"rating keys written to {keymap}")
    for rk in filter(None, args.prebuild_media.split(",")):
        rk = catalog.by_ref.get(rk, rk)
        if rk in catalog.items:
            ensure_media(catalog, rk)
    log("ready")
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
