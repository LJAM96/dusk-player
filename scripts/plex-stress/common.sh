# Shared settings for the Plex stress-test library scripts.
# Override via env: PLEX_SSH, STRESS_HOST_DIR, STRESS_PLEX_DIR, PLEX_PORT, PLEX_PREFS_DIR
PLEX_SSH="${PLEX_SSH:-root@storage}"                               # host running the plex-demo container
STRESS_HOST_DIR="${STRESS_HOST_DIR:-/mnt/Bulk/Media/Demo/Stress}"   # folder on that host
STRESS_PLEX_DIR="${STRESS_PLEX_DIR:-/data/Stress}"                  # same folder as Plex sees it
PLEX_PORT="${PLEX_PORT:-10012}"
PLEX_PREFS_DIR="${PLEX_PREFS_DIR:-/opt/apps/media/plex-demo}"

# Runs a remote shell snippet with $T (Plex token) and $B (Plex base URL) set.
plex_remote() {
  ssh "$PLEX_SSH" "P=\$(find '$PLEX_PREFS_DIR' -maxdepth 4 -name Preferences.xml | head -1); \
T=\$(grep -o 'PlexOnlineToken=\"[^\"]*\"' \"\$P\" | cut -d'\"' -f2); B=http://localhost:$PLEX_PORT; $1"
}
