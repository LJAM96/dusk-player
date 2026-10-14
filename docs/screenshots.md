# App Store Screenshots

## One command

```bash
scripts/screenshots/make.sh all        # or iphone | ipad | tv; options: --refresh, --no-build
```

`make.sh` runs the three stages below in order: fetch the demo catalogue
(cached), capture raw screens in the simulators, compose the marketing panels
(`--strict`, so a missing capture fails the run). The final panels land in
`screenshots/1.7/{iphone-6.9,ipad-13,appletv}/` (committed); everything else
(catalogue, posters, raw captures, 1080p TV set) stays in gitignored `build/`
and `.build/`. A full run takes ~35 minutes, mostly simulator capture. After
a UI change, this one command is all a later agent needs; then look at the
panels and commit `screenshots/1.7/`.

Needs: Xcode + simulators, `ffmpeg`, ImageMagick (`magick`), Google Chrome
(compositor), network access for the first fetch. No accounts or API keys.

## Demo content: titles, sources, legal

- **Title list**: `scripts/screenshots/titles.json` is the only committed
  content. Each entry has a `slug` (how `scenario.json`/`capture.sh` refer to
  it), a search `query` and an optional `year`; shows can cap `max_seasons`.
  Pick broadly popular, neutral titles across studios/streamers (no violent,
  political or polarising key art). To change titles, edit this file and
  `scenario.json` (libraries, Continue Watching, watched, recently added) and
  the `item=`/`IOS_DOWNLOADS`/`PREBUILD_MEDIA` refs in `capture.sh`.
- **Fetch** (`scripts/screenshots/fetch_catalog.py`, stdlib + `magick`) builds
  `.build/screenshots-cache/catalog/` (`catalog.json` + images) in the format
  `mock_plex.py` serves:
  - **Plex Discover** (`discover.provider.plex.tv/library/search` and
    `/library/metadata/<id>`, no token needed): title, year, summary,
    tagline, genres, studio, ratings, runtime, directors, and the cover art Plex
    itself shows: poster, background, clear logo.
  - **TVmaze** (`api.tvmaze.com`, no key): season/episode lists (titles,
    summaries, air dates, runtimes) and season posters, because Discover only
    serves children to signed-in clients. Episode thumbnails are crops of the
    show's background art, never episode stills.
  - Responses and downloads are cached in `.build/screenshots-cache/downloads/`;
    `--refresh` refetches metadata. A title without a confident match fails
    the fetch with a hint to fix `query`/`year`.
- **Legal line**: only metadata and cover art (posters, backgrounds, logos)
  of real titles appear, the same things any Plex client shows for a library.
  The **player never shows a real scene**: the mock's playable video is a
  neutral public-domain NASA frame from `scripts/screenshots/player-frames/`
  (credits in its `CREDITS.md`), while the HUD shows the real episode title.
  `scenario.json` → `player_frames` picks the frame per item. Fetched art is
  never committed; the composed screenshots are.

## Capturing raw screens

Raw, full-screen captures of the real app with demo content come from one
command per platform. It only uses simulators; it never signs, uploads, or
touches a device.

```bash
scripts/screenshots/capture.sh iphone   # iPhone 17 Pro Max, 1320×2868 (landscape player shots 2868×1320)
scripts/screenshots/capture.sh ipad     # iPad Pro 13" (M5), 2752×2064 landscape, 2064×2752 portrait
scripts/screenshots/capture.sh tv       # Apple TV 4K (3rd gen), 3840×2160
scripts/screenshots/capture.sh all
# options: --no-build (reuse the last build), --only <name-substring>
```

Output: `build/screenshots/raw/<iphone|ipad|tv>/<NN-name>.png` (gitignored).
The compositor picks from these.

### How it works

- **Mock Plex** (`scripts/screenshots/mock_plex.py`, Python stdlib only): one
  process plays plex.tv on `127.0.0.1:47400` (account, Home users, resources)
  and three Plex Media Servers on `:47401–47403` ("Living Room" is owned,
  "Studio" is shared by Jamie, "Cabin" is shared by Sam over a remote
  connection) so multi-server merging and Server Priority have something to
  show. It serves libraries, hubs,
  Continue Watching, metadata/children/allLeaves, filters, search, history,
  images and playable media; unknown endpoints answer an empty
  `MediaContainer` and are logged as `UNHANDLED` (listed at the end of a run;
  full log in `.build/screenshots-cache/mock.log`).
- **Demo content**: the fetched catalogue (see above). `scenario.json` arranges it into
  the account: which server/library holds what, Continue Watching with
  progress (an entry may name a `server`, e.g. F1 resumes on Cabin, so
  Continue Watching is visibly merged across servers), watched items,
  "recently added" order. A title on two servers gets the same `plex://` guid
  (from its slug), so the app merges the copies like real Plex content. Rating
  keys are globally unique and assigned at
  start-up and written to `.build/screenshots-cache/rating-keys.json`; shots
  address titles by catalogue ref (`the-wild-robot`, `planet-earth-iii/1/3`).
- **Playable media** is generated on demand by ffmpeg into
  `.build/screenshots-cache/media/<ratingKey>-<hash>.mp4`: a neutral
  `player-frames/` image as a 2 fps H.264 video with the title's real runtime, two
  silent AAC tracks and five empty `mov_text` subtitle tracks (no SDH track: the
  app maps an auto-selected English track onto it), so AVPlayer
  renders a real frame, the scrubber shows real times and the audio/subtitle
  menus are populated. Nothing large is downloaded or committed.
- **DEBUG-only screenshot mode** (`Dusk/Sources/App/ScreenshotMode.swift`,
  everything behind `#if DEBUG`), driven purely by launch arguments:

  | Argument | Effect |
  | --- | --- |
  | `-DuskScreenshotMode YES` | Signs in with a fake account token (Keychain untouched); hero rotation off |
  | `-DuskScreenshotPlexTV <url>` | Replaces `https://plex.tv` (`PlexService.plexTVBase`) |
  | `-DuskScreenshotScreen <name>` | `home`, `movies`, `shows`, `library`, `detail`, `search`, `player`, `downloads`, `settings`, `serverPriority`, `supporter`, `icons` |
  | `-DuskScreenshotItem <ratingKey>` / `-DuskScreenshotItemType <type>` | Item for `detail`/`player` (the server holding it is looked up); type also picks the `library` tab |
  | `-DuskScreenshotPlayOffset <seconds>` | Exact player start position (`PlaybackCoordinator.playForScreenshot`), ignoring the resume point |
  | `-DuskScreenshotKeepHUD YES` | Player controls never auto-hide |
  | `-DuskScreenshotSearch <query>` | Pre-filled search |
  | `-DuskScreenshotDownloads movie:<rk>,episode:<rk>` | Queues real downloads from the mock (the warm-up launch does this) |
  | `-DuskScreenshotTVInputs "wait:3500,up,panel:subtitles"` | tvOS player: synthetic Siri Remote input fed to `PlayerTVHUDController` |

  Ordinary preferences can be forced the same way, because launch arguments
  land in UserDefaults' argument domain: `-playerEpisodeButtonsEnabled YES`,
  `-appearanceMode dark` (tvOS has no `simctl ui appearance`),
  `-playerAspectFillLandscape YES`, `-autoSkipIntroMode off`.
  App touch points: `PlexService` (plex.tv base + token), `MainTabView`
  (routing task + sheet presenter), `AppNavigationRoute.screenshotServerPriority`,
  `SearchView` (query), `PlayerViewModel` (HUD auto-hide),
  `PlaybackCoordinator.playForScreenshot` (exact start), `PlayerView`
  (tvOS input replay), `HomeCinematicHero` (rotation). All compiled out of
  Release.
- **The script** builds Debug with `CODE_SIGNING_ALLOWED=NO` into
  `.build/screenshots-derived-data`, uses dedicated simulators ("Dusk Shots
  iPhone/iPad/Apple TV", created if missing), switches the simulator to
  en_US (written to the global defaults, then one reboot so SpringBoard picks
  it up; the app also gets `-AppleLocale en_US`), sets dark appearance and a
  9:41 / Tue Jun 9 status bar (`simctl status_bar --time` only accepts an
  ISO date as UTC with milliseconds, `…T07:41:00.000Z`), reinstalls the app (clean state), does one warm-up launch
  (connects, fills the image cache, queues the demo downloads), then launches
  once per shot, waits a fixed time and runs `simctl io screenshot`.
- **Rotation**: `simctl` cannot rotate a simulator, so
  `scripts/screenshots/driver/` is a tiny xcodegen project whose only UI test
  sets `XCUIDevice.shared.orientation`; the orientation outlives the test run.
  An in-app `requestGeometryUpdate` does not rotate a windowed iPadOS 26 app.
  Its generated `ShotsDriver.xcodeproj` is gitignored.

### Editing shots

Shot lists are the `IPHONE_SHOTS` / `IPAD_SHOTS` / `TV_SHOTS` arrays at the
top of `capture.sh` (`NN-name|wait seconds|key=value …`, documented there).
Add a title by adding it to `catalog.json` (+ images) and, if needed,
`scenario.json`. Restart the mock after catalogue/scenario edits (the script
reuses a mock already listening on the port).

### Traps

- If a capture shows the sign-in screen or "Couldn't load Plex", the mock is
  not running or not reachable on `127.0.0.1:47400`.
- The mock answers unknown items with an empty `MediaContainer`, never a 404:
  the app re-probes a server after a 404.
- The first player launch of a long title waits for ffmpeg (~10 s for 50 min);
  `capture.sh` pre-builds the media its shots use (`PREBUILD_MEDIA`). Once a
  file exists the mock reports its real size as `Part.size`, because a
  download is rejected when the received bytes differ — so downloaded titles
  must be in `PREBUILD_MEDIA` (they are, via `IOS_DOWNLOADS`).
- Skip Intro shots use the first episode (exempt from the default "skip
  intros except the first episode" rule), an intro marker running 0:12–1:44,
  `-autoSkipIntroMode off` and the HUD kept up (the iOS button and the tvOS
  chip only show with the HUD after a few seconds).
- Up Next appears when playback *crosses* the credits marker, hence
  `offset=end-98` (credits start 95 s before the end of long episodes).
- tvOS remote input in the player goes through `-DuskScreenshotTVInputs`;
  other tvOS screens use the default focus (no XCUIRemote driver).
- StoreKit prices on the Supporter page come from the App Store sandbox, so
  that shot needs a network connection.
- iPadOS 26 draws its window-resize grip in the bottom-right corner of every
  iPad capture.

## Compositing

Marketing screenshots (device frame, headline, background) are built from the
raw captures by one command. Dependencies: Google Chrome and ImageMagick 7
(`magick`); Python stdlib only, nothing to install.

```bash
scripts/screenshots/compose.sh all                 # or iphone | ipad | tv
scripts/screenshots/compose.sh iphone --only 01-home --preview
scripts/screenshots/compose.sh all --strict        # final run: no placeholders
```

Output: exact App Store sizes, opaque RGB (no alpha), sRGB. Only the sets we
upload are written to the repo; derived sizes go to the gitignored
`build/screenshots/out/<version>/` (`derived_output` in the config):

| Folder | Size | Notes |
|---|---|---|
| `screenshots/<v>/iphone-6.9` | 1320×2868 | The only iPhone size needed; ASC scales it down. |
| `screenshots/<v>/ipad-13` | 2752×2064 | Landscape. |
| `screenshots/<v>/appletv` | 3840×2160 | |
| `build/…/out/<v>/appletv-1080p` | 1920×1080 | Derived from the same render; ASC accepts either TV size. |
| `build/…/out/<v>/iphone-6.5` | 1284×2778 | Derived (crop + resample); off by default (`"enabled": false`). |

A full run of a platform (no `--only`) deletes PNGs in its output folders
whose panel id is no longer in the config, so renamed or dropped panels don't
linger.

`--preview` writes contact sheets to `build/screenshots/compose/preview/`
(`--preview-dir` to change). Judge the set there, side by side.

### Config: `scripts/screenshots/compose/panels.json`

- `design`: background colours, shadow, per-platform type sizes, logo.
- `platforms.<p>.layouts`: named compositions. Keys: `center` (device centre,
  canvas px), `screen_w` or `fit: [w, h]` (screen size; `fit` works for either
  orientation), `rotate: [x, y, z]` degrees, `perspective`, `second` (a second
  device: `center`, `screen_w`/`fit`/`scale`, `rotate`, `z`, `dim`),
  `copy: "left"|"right"` with `copy_x` for side copy, `type` overrides,
  `icons` (icon grid instead of a device), `floats` (icon tiles over a device),
  `glow_at`. Devices may bleed off the canvas; the canvas clips.
- Current layouts: `hero` (big device, bottom ~8–11% bleeds off; the
  default), `hero-player` (iPad/TV: only ~3% bleed so player scrubbers and
  bottom rows stay visible), `tilt-left`/`tilt-right` (full, uncropped,
  slightly turned; for rhythm), iPhone `landscape-pair` (big player phone bleeding right, a smaller
  Skip Intro phone fully visible below), `landscape-single`, `duo-hero` (two portrait phones, front one casts a shade
  on the back one), `icons-device` (icon-picker capture; iPhone adds
  floating icon tiles in the picker's empty footer, iPad uses none), `icons` (pure grid, fallback); TV `side` (copy
  left, tilted screen; max one per set).
- `platforms.<p>.panels`: `id` (= output file name, order), `input` (raw
  capture), `placeholder` (dev fallback), `input2`/`placeholder2` for two-device
  layouts, `layout` (a name, or `{"landscape": …, "portrait": …}` picked by the
  capture's orientation), `fallback_layout` (used when a capture is missing,
  e.g. icon grid without the picker capture), `headline` (`\n` forces a break),
  `subline`, `brand` (logo lockup above the headline, panel 1 only), `icons`,
  `tone` (background tone index), `tweak` (per-panel layout overrides), `enabled`.
- `design.background.tones`: top tones cycled per panel (all neutral
  graphite/slate) so the strip has rhythm; `glow` is the soft cool light behind
  the device.
- `island: "auto"` (default) draws the Dynamic Island only when the capture
  doesn't already show one. `grip_mask` (iPad) removes the iPadOS 26
  window-resize grip: the arc's fixed shape (`assets/ipad-grip-mask.png`, made
  from a dark capture) is masked and filled from surrounding pixels before
  framing; cleaned copies are cached in `build/screenshots/compose/clean/`.

Missing raw → the placeholder is used (logged `[placeholder]`); no placeholder
either → the panel is skipped. `--strict` turns both into errors.

### How it works

`compose.py` writes one HTML page per panel (devices are CSS: titanium band,
black bezel, screen, island, side buttons, and a stack of slabs that gives a
tilted device its thickness) and renders it with headless Chrome in two passes:

1. background only at 1×. ImageMagick blurs it in 16-bit (it has nothing
   sharp; this turns Chrome's 8-bit gradient steps back into ramps) and
   re-quantises with a 4×4 ordered dither (`design.background.smooth` = blur
   radius as a fraction of the long side). No visible banding even at 8×
   contrast, and about a third of the bytes random noise cost;
2. devices + copy on transparent at 2× (supersampled), downsampled in linear
   light with Lanczos, then composited over the background.

Intermediate HTML and raw renders live in `build/screenshots/compose/` (open
the `.html` in Chrome to tweak a layout live).

### Design rules (STYLE.md applies)

- Neutral graphite background, white bold headline, grey subline. Coral only
  in the logo mark; no glows, lines or tinted washes.
- Headline top is fixed per platform so the set reads as one strip; 2–5 words,
  `\n` to control the break.
- The app UI is the product: hero devices fill ~85% of the canvas width and
  bleed off the bottom; full tilted devices only for rhythm. Subtle
  perspective only (≤ 16° yaw, ≤ 6° pitch).

### Picking shots

- Check what a bleed hides before choosing `hero`: tvOS/iPad player shots keep
  the scrubber in the bottom ~6% (use `hero-player`); iPhone landscape player
  shots have Skip Intro on the right, so that phone may only bleed left.
- Floating icons must sit over empty UI (the picker's footer on iPhone, the
  dimmed settings beside the sheet on iPad); move `floats` if the capture
  changes.
- Alternate warm / colourful / dark frames across a set; never two dark player
  frames side by side.

### Traps

- `-apple-system` doesn't resolve in headless Chrome; the CSS uses
  `system-ui` (SF Pro, with Display optical size at headline sizes).
- Headless Chrome's viewport is never narrower than ~500px; everything is laid
  out on a fixed-size `#canvas`, not the viewport.
- Many 3D layers at 2× exceed Chrome's default tile memory and layers silently
  vanish ("tile memory limits exceeded"); the script passes
  `--force-gpu-mem-available-mb` and fails if Chrome still reports it.
- App Store Connect rejects PNGs with alpha; the script always writes
  `color-type=2` (RGB) and checks the exact size of every file.
