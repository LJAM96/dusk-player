#!/usr/bin/env bash
# Captures raw App Store screens of Dusk with demo content.
#
#   scripts/screenshots/capture.sh iphone|ipad|tv|all [--no-build] [--only <name-substring>]
#
# Builds the Debug app, starts the mock Plex server (mock_plex.py), boots a
# dedicated "Dusk Shots …" simulator, launches the app once per shot in the
# DEBUG-only screenshot mode and saves the simulator framebuffer to
# build/screenshots/raw/<platform>/<NN-name>.png. See docs/screenshots.md.
#
# Simulators only — this never touches a real device, signing or uploads.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DERIVED_DATA="$REPO_ROOT/.build/screenshots-derived-data"
CACHE_DIR="$REPO_ROOT/.build/screenshots-cache"
OUT_ROOT="$REPO_ROOT/build/screenshots/raw"
BUNDLE_ID="com.dusk-player.app"
PORT="${DUSK_SCREENSHOT_PORT:-47400}"
MOCK_LOG="$CACHE_DIR/mock.log"
KEYS_FILE="$CACHE_DIR/rating-keys.json"

PLATFORM="${1:-}"
shift || true
BUILD=1
ONLY=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build) BUILD=0 ;;
    --only) ONLY="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

case "$PLATFORM" in
  iphone|ipad|tv|all) ;;
  *) echo "usage: $0 iphone|ipad|tv|all [--no-build] [--only <name>]" >&2; exit 2 ;;
esac

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
# Shot lists: "NN-name|seconds to wait|key=value …"
#   screen=<ScreenshotMode.Screen>  item=<catalog ref>  type=<movie|show|season|episode>
#   offset=<seconds> | offset=end-<seconds>   search=<query>   hud=1 (keep player HUD)
#   orientation=landscape|portrait (iOS; rotates the simulated device via driver/)
#   tv=<remote input script, ';'-separated, e.g. wait:3000;tap;down>
#   pref:<UserDefaults key>=<value>   passes "-key value" (e.g. pref:playerEpisodeButtonsEnabled=YES)
# ---------------------------------------------------------------------------

IPHONE_SHOTS=(
  "01-home|10|screen=home"
  "02-series|8|screen=detail item=ted-lasso type=show"
  "03-season|8|screen=detail item=ted-lasso/1 type=season"
  "04-movie-detail|8|screen=detail item=the-wild-robot type=movie"
  "05-movies|10|screen=movies"
  "06-library-grid|9|screen=library type=movie"
  "07-player|11|screen=player item=planet-earth-iii/1/3 offset=1630 hud=1 orientation=landscape pref:playerEpisodeButtonsEnabled=YES pref:playerAspectFillLandscape=YES"
  "08-up-next|12|screen=player item=planet-earth-iii/1/3 offset=end-98 orientation=landscape pref:playerAspectFillLandscape=YES"
  "09-skip-intro|7|screen=player item=planet-earth-iii/1/1 offset=20 hud=1 pref:autoSkipIntroMode=off orientation=landscape pref:playerEpisodeButtonsEnabled=YES pref:playerAspectFillLandscape=YES"
  "10-server-priority|7|screen=serverPriority"
  "11-app-icons|7|screen=icons"
  "12-supporter|9|screen=supporter"
  "13-search|9|screen=search search=ted"
  "14-downloads|7|screen=downloads"
  "15-shows|10|screen=shows"
)

IPAD_SHOTS=(
  "01-home-landscape|11|screen=home orientation=landscape"
  "02-home-portrait|16|screen=home orientation=portrait"
  "03-movies-landscape|10|screen=movies orientation=landscape"
  "04-series-landscape|9|screen=detail item=ted-lasso type=show orientation=landscape"
  "05-season-landscape|9|screen=detail item=ted-lasso/1 type=season orientation=landscape"
  "06-movie-detail-landscape|9|screen=detail item=the-wild-robot type=movie orientation=landscape"
  "07-player-landscape|11|screen=player item=planet-earth-iii/1/3 offset=1630 hud=1 orientation=landscape pref:playerEpisodeButtonsEnabled=YES"
  "08-up-next-landscape|12|screen=player item=planet-earth-iii/1/3 offset=end-98 orientation=landscape"
  "08b-skip-intro-landscape|7|screen=player item=planet-earth-iii/1/1 offset=20 hud=1 pref:autoSkipIntroMode=off orientation=landscape pref:playerEpisodeButtonsEnabled=YES"
  "09-server-priority-landscape|7|screen=serverPriority orientation=landscape"
  "10-app-icons-landscape|7|screen=icons orientation=landscape"
  "11-supporter-landscape|9|screen=supporter orientation=landscape"
  "12-library-grid-landscape|9|screen=library type=movie orientation=landscape"
  "13-search-landscape|9|screen=search search=ted orientation=landscape"
)

TV_SHOTS=(
  "01-home|12|screen=home"
  "02-series|10|screen=detail item=ted-lasso type=show"
  "03-movie-detail|10|screen=detail item=the-wild-robot type=movie"
  "04-movies|11|screen=movies"
  "05-library-grid|10|screen=library type=movie"
  "06-player-hud|12|screen=player item=planet-earth-iii/1/3 offset=1630 hud=1"
  "07-player-actions|13|screen=player item=planet-earth-iii/1/3 offset=1630 hud=1 tv=wait:3500;up;wait:600;up;wait:400;right;right;right"
  "08-player-panel|13|screen=player item=planet-earth-iii/1/3 offset=1630 hud=1 tv=wait:3500;panel:subtitles"
  "09-skip-intro|6|screen=player item=planet-earth-iii/1/1 offset=20 hud=1 pref:autoSkipIntroMode=off"
  "10-up-next|12|screen=player item=planet-earth-iii/1/3 offset=end-98"
  "11-search|10|screen=search search=ted"
  "12-settings|8|screen=settings"
  "13-supporter|9|screen=supporter"
  "14-server-priority|8|screen=serverPriority"
)

# Titles whose playable media the mock should build before the first launch.
PREBUILD_MEDIA="planet-earth-iii/1/3,planet-earth-iii/1/1,the-wild-robot,paddington-in-peru,inside-out-2,ted-lasso/1/2,planet-earth-iii/1/2"
# iOS Downloads tab content, queued on the first launch of a run.
IOS_DOWNLOADS="movie:the-wild-robot,movie:paddington-in-peru,episode:ted-lasso/1/2,movie:inside-out-2,episode:planet-earth-iii/1/2"

# ---------------------------------------------------------------------------

require() { command -v "$1" >/dev/null 2>&1 || { echo "Missing $1" >&2; exit 1; }; }
require xcrun
require xcodebuild
require ffmpeg
require python3

ref_key() {
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["keys"][sys.argv[2]])' "$KEYS_FILE" "$1"
}

ref_duration_seconds() {
  python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["durations"][d["keys"][sys.argv[2]]] / 1000)' "$KEYS_FILE" "$1"
}

start_mock() {
  mkdir -p "$CACHE_DIR"
  if curl -sf "http://127.0.0.1:$PORT/api/v2/user" >/dev/null 2>&1; then
    log "Mock Plex already running on :$PORT (restart it to pick up catalogue changes)"
    return
  fi
  log "Starting mock Plex on :$PORT (log: $MOCK_LOG)"
  python3 -I "$SCRIPT_DIR/mock_plex.py" --port "$PORT" --prebuild-media "$PREBUILD_MEDIA" >"$MOCK_LOG" 2>&1 &
  MOCK_PID=$!
  for _ in $(seq 1 300); do
    grep -q '^.* ready$' "$MOCK_LOG" 2>/dev/null && return
    kill -0 "$MOCK_PID" 2>/dev/null || { cat "$MOCK_LOG"; echo "mock server died" >&2; exit 1; }
    sleep 0.5
  done
  echo "mock server did not become ready" >&2
  exit 1
}

stop_mock() {
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
  fi
}
trap stop_mock EXIT

device_udid() {
  local name="$1" type="$2" runtime_prefix="$3" udid runtime
  udid="$(xcrun simctl list devices available | grep -F "    $name (" | grep -oE '[A-F0-9-]{36}' | head -n1 || true)"
  if [[ -z "$udid" ]]; then
    runtime="$(xcrun simctl list runtimes | awk -F ' - ' -v p="$runtime_prefix" '$1 ~ ("^" p " ") { r=$2 } END { print r }')"
    [[ -n "$runtime" ]] || { echo "No $runtime_prefix runtime installed" >&2; exit 1; }
    udid="$(xcrun simctl create "$name" "$type" "$runtime")"
  fi
  printf '%s\n' "$udid"
}

build_app() {
  local scheme="$1" sdk_dest="$2"
  [[ "$BUILD" == 1 ]] || return 0
  log "Building $scheme (Debug, simulator)"
  xcodebuild -project "$REPO_ROOT/Dusk.xcodeproj" -scheme "$scheme" -configuration Debug \
    -destination "$sdk_dest" -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build \
    >"$CACHE_DIR/build-$scheme.log" 2>&1 || { tail -40 "$CACHE_DIR/build-$scheme.log"; exit 1; }
}

prepare_device() {
  local udid="$1" app="$2" is_ios="$3"
  log "Preparing simulator $udid"
  xcrun simctl boot "$udid" >/dev/null 2>&1 || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  # en_US system-wide (12-hour "9:41", US dates in the status bar). SpringBoard
  # only reads it at boot, so reboot once when it changes.
  if [[ "$(xcrun simctl spawn "$udid" defaults read -g AppleLocale 2>/dev/null)" != en_US ]]; then
    xcrun simctl spawn "$udid" defaults write -g AppleLocale -string en_US
    xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array en-US
    xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
    xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
  fi
  xcrun simctl ui "$udid" appearance dark >/dev/null 2>&1 || true
  if [[ "$is_ios" == 1 ]]; then
    # An ISO date also fixes the iPad's status bar date (Tue Jun 9).
    local status_time
    # simctl only accepts UTC with milliseconds; 9:41 local on Tue Jun 9.
    status_time="$(date -u -r "$(date -j -f '%Y-%m-%d %H:%M:%S' '2026-06-09 09:41:00' +%s)" +%Y-%m-%dT%H:%M:%S.000Z)"
    xcrun simctl status_bar "$udid" override --time "$status_time" --dataNetwork wifi --wifiMode active \
      --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
  fi
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  # A fresh install every run: no stale servers, downloads, prompts or caches.
  xcrun simctl uninstall "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl install "$udid" "$app"
}

# Turns "key=value …" into launch arguments (one per line).
shot_args() {
  local spec="$1" token key value
  printf '%s\n' -DuskScreenshotMode YES -DuskScreenshotPlexTV "http://127.0.0.1:$PORT"
  printf '%s\n' -AppleLocale en_US -AppleLanguages "(en-US)"
  # tvOS has no simctl appearance switch; the app's own setting forces dark.
  if [[ "$CURRENT_PLATFORM" == tv ]]; then printf '%s\n' -appearanceMode dark; fi
  for token in $spec; do
    key="${token%%=*}"
    value="${token#*=}"
    case "$key" in
      screen) printf '%s\n' -DuskScreenshotScreen "$value" ;;
      item) printf '%s\n' -DuskScreenshotItem "$(ref_key "$value")"; SHOT_ITEM="$value" ;;
      type) printf '%s\n' -DuskScreenshotItemType "$value" ;;
      search) printf '%s\n' -DuskScreenshotSearch "$value" ;;
      hud) printf '%s\n' -DuskScreenshotKeepHUD YES ;;
      tv) printf '%s\n' -DuskScreenshotTVInputs "${value//;/,}" ;;
      downloads) printf '%s\n' -DuskScreenshotDownloads "$value" ;;
      offset)
        if [[ "$value" == end-* ]]; then
          python3 -I -c 'import sys; print("-DuskScreenshotPlayOffset"); print(float(sys.argv[1]) - float(sys.argv[2]))' \
            "$(ref_duration_seconds "$SHOT_ITEM")" "${value#end-}"
        else
          printf '%s\n' -DuskScreenshotPlayOffset "$value"
        fi
        ;;
      pref:*) printf '%s\n' "-${key#pref:}" "$value" ;;
    esac
  done
}

# Resolves "movie:sintel,episode:show/1/5" refs to "movie:<rk>,…".
resolve_downloads() {
  local out=() entry
  IFS=',' read -ra entries <<<"$1"
  for entry in "${entries[@]}"; do
    out+=("${entry%%:*}:$(ref_key "${entry#*:}")")
  done
  (IFS=','; echo "${out[*]}")
}

DRIVER_DD="$REPO_ROOT/.build/screenshots-driver-dd"
CURRENT_ORIENTATION=""

# simctl cannot rotate a simulator, so a one-line XCUITest (driver/) does it.
# The orientation outlives the test run.
build_driver() {
  [[ "$BUILD" == 1 || ! -d "$DRIVER_DD/Build/Products" ]] || return 0
  log "Building the rotation driver"
  (cd "$SCRIPT_DIR/driver" && xcodegen generate --quiet)
  xcodebuild -project "$SCRIPT_DIR/driver/ShotsDriver.xcodeproj" -scheme ShotsHost \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$DRIVER_DD" build-for-testing \
    >"$CACHE_DIR/build-driver.log" 2>&1 || { tail -30 "$CACHE_DIR/build-driver.log"; exit 1; }
}

set_orientation() {
  local udid="$1" orientation="$2" test
  [[ "$CURRENT_ORIENTATION" != "$orientation" ]] || return 0
  test=testPortrait
  [[ "$orientation" == landscape ]] && test=testLandscape
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcodebuild test-without-building -xctestrun "$(ls "$DRIVER_DD"/Build/Products/*.xctestrun | head -n1)" \
    -destination "id=$udid" -only-testing:"ShotsDriverUITests/RotateTests/$test" \
    >"$CACHE_DIR/driver-$orientation.log" 2>&1 || { tail -20 "$CACHE_DIR/driver-$orientation.log"; exit 1; }
  CURRENT_ORIENTATION="$orientation"
}

launch() {
  local udid="$1"; shift
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
  sleep 1
  xcrun simctl launch "$udid" "$BUNDLE_ID" "$@" >/dev/null
}

capture_platform() {
  local platform="$1" udid app is_ios scheme dest out
  CURRENT_PLATFORM="$platform"
  local -a shots
  case "$platform" in
    iphone)
      udid="$(device_udid "Dusk Shots iPhone" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max iOS)"
      scheme=Dusk; dest='generic/platform=iOS Simulator'; is_ios=1
      app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Dusk.app"; shots=("${IPHONE_SHOTS[@]}") ;;
    ipad)
      udid="$(device_udid "Dusk Shots iPad" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB iOS)"
      scheme=Dusk; dest='generic/platform=iOS Simulator'; is_ios=1
      app="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/Dusk.app"; shots=("${IPAD_SHOTS[@]}") ;;
    tv)
      udid="$(device_udid "Dusk Shots Apple TV" com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K-3rd-generation-4K tvOS)"
      scheme=Dusk-tvOS; dest='generic/platform=tvOS Simulator'; is_ios=0
      app="$DERIVED_DATA/Build/Products/Debug-appletvsimulator/Dusk.app"; shots=("${TV_SHOTS[@]}") ;;
  esac

  build_app "$scheme" "$dest"
  if [[ "$is_ios" == 1 ]]; then build_driver; fi
  CURRENT_ORIENTATION=""
  prepare_device "$udid" "$app" "$is_ios"
  out="$OUT_ROOT/$platform"
  mkdir -p "$out"

  # Warm-up launch: lets the app connect, fills the image cache and (iOS)
  # queues the demo downloads so every later shot has the Downloads tab.
  log "[$platform] warm-up launch"
  local warm=(-DuskScreenshotMode YES -DuskScreenshotPlexTV "http://127.0.0.1:$PORT" -DuskScreenshotScreen home -appearanceMode dark -AppleLocale en_US -AppleLanguages "(en-US)")
  if [[ "$is_ios" == 1 ]]; then
    warm+=(-DuskScreenshotDownloads "$(resolve_downloads "$IOS_DOWNLOADS")")
  fi
  launch "$udid" "${warm[@]}"
  sleep 25

  local shot name wait spec file args
  for shot in "${shots[@]}"; do
    IFS='|' read -r name wait spec <<<"$shot"
    if [[ -n "$ONLY" && "$name" != *"$ONLY"* ]]; then continue; fi
    SHOT_ITEM=""
    if [[ "$is_ios" == 1 ]]; then
      local wanted=portrait
      [[ "$spec" == *"orientation=landscape"* ]] && wanted=landscape
      set_orientation "$udid" "$wanted"
    fi
    args=()
    while IFS= read -r line; do args+=("$line"); done < <(shot_args "$spec")
    log "[$platform] $name"
    launch "$udid" "${args[@]}"
    sleep "$wait"
    file="$out/$name.png"
    xcrun simctl io "$udid" screenshot --type=png "$file" >/dev/null 2>&1
    echo "    $(sips -g pixelWidth -g pixelHeight "$file" | awk '/pixel/ {printf "%s ", $2}')→ ${file#$REPO_ROOT/}"
  done
  xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
}

start_mock

if [[ "$PLATFORM" == all ]]; then
  for p in iphone ipad tv; do capture_platform "$p"; done
else
  capture_platform "$PLATFORM"
fi

log "Raw captures in ${OUT_ROOT#$REPO_ROOT/}/"
grep -h 'UNHANDLED' "$MOCK_LOG" 2>/dev/null | sed 's/^[0-9:]* //' | sort -u | head -20 || true
