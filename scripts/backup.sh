#!/system/bin/sh
# ============================================================
# rime-sync-scheduler — unified sync script
# ============================================================
# Handles both local Rime sync (via broadcast to LSPosed hook)
# and cloud sync (two-step rclone sync to remote storage).
# Step A: upload this device's data; Step B: download other devices.
#
# Modes (flags):
#   --full-sync    Trigger local sync first, then cloud sync
#   --cloud-only   Cloud sync only (skip local trigger)
#   --local-only   Local sync only (skip cloud sync)
#   --dry-run      rclone dry-run (preview only, no changes)
#
# Usage:
#   sh backup.sh --full-sync          # full automated sync
#   sh backup.sh --cloud-only         # cloud only
#   sh backup.sh --local-only         # local only
#   sh backup.sh --full-sync --dry-run  # preview
# ============================================================

# ── Paths (app data) ────────────────────────────────────────
APP_DATA="/data/data/org.fcitx.rimesync"
PATHS_FILE="${APP_DATA}/files/rime_paths.txt"
RCLONE_CONFIG_APP="${APP_DATA}/files/rclone.conf"
RCLONE_CONFIG_EXT="/sdcard/rclone.conf"
RCLONE_BIN_APP="${APP_DATA}/files/rclone_bin/rclone"
PREFS_XML="${APP_DATA}/shared_prefs/rclone_prefs.xml"
RCLONE_CACHE="/data/local/tmp/rclone_cache"

# ── Logging ─────────────────────────────────────────────────
MODDIR="/data/adb/modules/rime-sync-scheduler"
LOG="${MODDIR}/sync.log"
[ ! -d "$MODDIR" ] && LOG="/data/local/tmp/rime_sync.log"

# ── Broadcast constants ─────────────────────────────────────
BROADCAST_ACTION="org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC"
BROADCAST_TARGET="org.fcitx.fcitx5.android"

# ═══════════════════════════════════════════════════════════════
#  Logging helper
# ═══════════════════════════════════════════════════════════════
log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

# ═══════════════════════════════════════════════════════════════
#  Flag parsing
# ═══════════════════════════════════════════════════════════════
MODE="cloud-only"
DRY_RUN=""

while [ $# -gt 0 ]; do
    case "$1" in
        --full-sync)   MODE="full" ;;
        --cloud-only)  MODE="cloud" ;;
        --local-only)  MODE="local" ;;
        --dry-run)     DRY_RUN="--dry-run" ;;
        *) echo "Unknown flag: $1"
           echo "Usage: sh backup.sh [--full-sync|--cloud-only|--local-only] [--dry-run]"
           exit 1 ;;
    esac
    shift
done

log "=== Starting (mode=$MODE) ==="

# ═══════════════════════════════════════════════════════════════
#  Phase 1: Local sync (broadcast to fcitx5-android)
# ═══════════════════════════════════════════════════════════════
if [ "$MODE" = "full" ] || [ "$MODE" = "local" ]; then
    log "[local] Sending Rime sync broadcast..."
    # IMPORTANT: Dynamic receivers (registered via registerReceiver) match by
    # ACTION + PACKAGE, NOT by component name. Use -p (not -n) to restrict
    # delivery to the fcitx5 package. --receiver-foreground adds
    # FLAG_RECEIVER_FOREGROUND so the broadcast reaches background receivers.
    if ! am broadcast \
        -a "$BROADCAST_ACTION" \
        -p "$BROADCAST_TARGET" \
        --receiver-foreground \
        >/dev/null 2>&1; then
        log "[local] WARNING: broadcast may have failed (fcitx5 not running?)"
    fi
    log "[local] Waiting 15s for sync to flush to disk..."
    sleep 15
    log "[local] Local sync phase done."
    [ "$MODE" = "local" ] && exit 0
fi

# ═══════════════════════════════════════════════════════════════
#  Phase 2: Find rclone binary
# ═══════════════════════════════════════════════════════════════
RCLONE=""
if [ -x "$RCLONE_BIN_APP" ]; then
    RCLONE="$RCLONE_BIN_APP"
elif command -v rclone >/dev/null 2>&1; then
    RCLONE="$(command -v rclone)"
else
    # last resort: check common module paths
    for p in /data/adb/modules/rclone-binary/system/bin/rclone \
             /data/adb/modules/rclone/system/bin/rclone; do
        [ -x "$p" ] && { RCLONE="$p"; break; }
    done
fi

if [ -z "$RCLONE" ]; then
    log "[cloud] ERROR: rclone binary not found."
    log "[cloud] Hint: open the Rime Sync Scheduler app once to auto-download rclone,"
    log "[cloud]   or install a rclone module for KernelSU/APatch."
    exit 1
fi
log "[cloud] rclone binary: $RCLONE"

# ═══════════════════════════════════════════════════════════════
#  Phase 3: Read local sync directory
# ═══════════════════════════════════════════════════════════════
SYNC_DIR=""
if [ -f "$PATHS_FILE" ]; then
    SYNC_DIR=$(sed -n '2p' "$PATHS_FILE" | tr -d '\r')
    RIME_DIR=$(sed -n '1p' "$PATHS_FILE" | tr -d '\r')

    # If sync_dir is empty or doesn't exist, fall back to rime_dir
    if [ -z "$SYNC_DIR" ] || [ ! -d "$SYNC_DIR" ]; then
        if [ -n "$RIME_DIR" ] && [ -d "$RIME_DIR" ]; then
            log "[cloud] sync_dir empty/invalid, falling back to rime_dir: $RIME_DIR"
            SYNC_DIR="$RIME_DIR"
        fi
    fi
fi

if [ -z "$SYNC_DIR" ] || [ ! -d "$SYNC_DIR" ]; then
    log "[cloud] ERROR: No valid sync directory."
    log "[cloud]   rime paths file: $([ -f "$PATHS_FILE" ] && cat "$PATHS_FILE" || echo 'NOT FOUND')"
    log "[cloud]   Hint: launch fcitx5 at least once after installing the LSPosed module,"
    log "[cloud]     so the hook can detect and export the rime/sync paths."
    exit 1
fi
log "[cloud] Local source: $SYNC_DIR"

# Auto-detect device name from Rime's installation.yaml
DEVICE_NAME="${RIME_DEVICE_NAME:-}"
if [ -z "$DEVICE_NAME" ] && [ -n "$RIME_DIR" ] && [ -f "$RIME_DIR/installation.yaml" ]; then
    DEVICE_NAME=$(sed -n 's/.*device_id:[[:space:]]*"\?\([^"#[:space:]]*\)"\?.*/\1/p' "$RIME_DIR/installation.yaml" | tr -d '\r')
fi
# Fallback: list local sync dirs, pick one that contains this device codename
if [ -z "$DEVICE_NAME" ] && [ -d "$SYNC_DIR" ]; then
    DEVICE_CODENAME=$(getprop ro.product.device)
    for d in "$SYNC_DIR"/*; do
        [ -d "$d" ] || continue
        dn=$(basename "$d")
        # case-insensitive prefix match via lowercasing both
        dn_lower=$(echo "$dn" | tr '[:upper:]' '[:lower:]')
        dc_lower=$(echo "$DEVICE_CODENAME" | tr '[:upper:]' '[:lower:]')
        case "$dn_lower" in "$dc_lower"*) DEVICE_NAME="$dn"; break ;; esac
    done
fi
[ -z "$DEVICE_NAME" ] && DEVICE_NAME="$(getprop ro.product.device)"
log "[cloud] Device name: $DEVICE_NAME"

LOCAL_DEVICE_DIR="$SYNC_DIR/$DEVICE_NAME"
if [ ! -d "$LOCAL_DEVICE_DIR" ]; then
    log "[cloud] WARNING: local device dir not found: $LOCAL_DEVICE_DIR"
fi

# ═══════════════════════════════════════════════════════════════
#  Phase 4: Read rclone config
# ═══════════════════════════════════════════════════════════════
RCLONE_CONFIG=""
if [ -f "$RCLONE_CONFIG_APP" ] && [ -s "$RCLONE_CONFIG_APP" ]; then
    RCLONE_CONFIG="$RCLONE_CONFIG_APP"
elif [ -f "$RCLONE_CONFIG_EXT" ] && [ -s "$RCLONE_CONFIG_EXT" ]; then
    RCLONE_CONFIG="$RCLONE_CONFIG_EXT"
else
    log "[cloud] ERROR: rclone.conf not found."
    log "[cloud]   App config: $RCLONE_CONFIG_APP ($([ -f "$RCLONE_CONFIG_APP" ] && echo 'exists' || echo 'missing'))"
    log "[cloud]   Ext config: $RCLONE_CONFIG_EXT ($([ -f "$RCLONE_CONFIG_EXT" ] && echo 'exists' || echo 'missing'))"
    log "[cloud]   Hint: use the app UI to import your rclone.conf."
    exit 1
fi
log "[cloud] Config: $RCLONE_CONFIG"

# ═══════════════════════════════════════════════════════════════
#  Phase 5: Determine remote path
# ═══════════════════════════════════════════════════════════════

# Extract first remote name from rclone.conf (strip DOS line endings \r)
REMOTE_NAME=$(sed -n 's/^\[\([^]]*\)\]/\1/p' "$RCLONE_CONFIG" | tr -d '\r' | head -1)
if [ -z "$REMOTE_NAME" ]; then
    log "[cloud] ERROR: No remote found in rclone.conf"
    exit 1
fi
log "[cloud] Remote: $REMOTE_NAME"

# Try reading remote_path from app's SharedPreferences
REMOTE_SUB_PATH=""
if [ -f "$PREFS_XML" ]; then
    REMOTE_SUB_PATH=$(sed -n 's/.*<string name="remote_path">\(.*\)<\/string>.*/\1/p' "$PREFS_XML" | tr -d '\r')
fi
# Fallback: environment variable or default
[ -z "$REMOTE_SUB_PATH" ] && REMOTE_SUB_PATH="${RCLONE_REMOTE_PATH:-rime/}"
# Remove leading slash for rclone compatibility
REMOTE_SUB_PATH="${REMOTE_SUB_PATH#/}"
log "[cloud] Remote sub-path: $REMOTE_SUB_PATH"

RCLONE_REMOTE_FULL="${REMOTE_NAME}:${REMOTE_SUB_PATH}"
log "[cloud] Full remote: $RCLONE_REMOTE_FULL"

# ═══════════════════════════════════════════════════════════════
#  Phase 6: Two-step rclone sync (upload → download)
# ═══════════════════════════════════════════════════════════════
mkdir -p "$RCLONE_CACHE"

export HOME="$RCLONE_CACHE"
export TMPDIR="$RCLONE_CACHE"

DRY_FLAG=""
[ -n "$DRY_RUN" ] && DRY_FLAG="--dry-run"

FINAL_EXIT=0

# ── Step A: Upload this device's data ──────────────────────
if [ -d "$LOCAL_DEVICE_DIR" ]; then
    log "[cloud] Upload: $LOCAL_DEVICE_DIR → $RCLONE_REMOTE_FULL/$DEVICE_NAME"
    [ -n "$DRY_RUN" ] && log "[cloud] *** DRY RUN ***"

    "$RCLONE" sync "$LOCAL_DEVICE_DIR" "$RCLONE_REMOTE_FULL/$DEVICE_NAME" \
        --config "$RCLONE_CONFIG" \
        --create-empty-src-dirs \
        --no-check-certificate \
        --timeout 30s \
        --log-file "$LOG" \
        --log-level INFO \
        $DRY_FLAG \
        >> "$LOG" 2>&1
    EC=$?
    if [ $EC -eq 0 ]; then
        log "[cloud] Upload done ✓"
    else
        log "[cloud] Upload FAILED (exit $EC) ✗"
        FINAL_EXIT=$EC
    fi
else
    log "[cloud] Upload skipped (no local device dir)"
fi

# ── Step B: Download other devices' data ───────────────────
log "[cloud] Download: $RCLONE_REMOTE_FULL → $SYNC_DIR (excluding $DEVICE_NAME)"
[ -n "$DRY_RUN" ] && log "[cloud] *** DRY RUN ***"

"$RCLONE" sync "$RCLONE_REMOTE_FULL" "$SYNC_DIR" \
    --config "$RCLONE_CONFIG" \
    --create-empty-src-dirs \
    --no-check-certificate \
    --timeout 30s \
    --log-file "$LOG" \
    --log-level INFO \
    --exclude "$DEVICE_NAME/**" \
    $DRY_FLAG \
    >> "$LOG" 2>&1
EC=$?
if [ $EC -eq 0 ]; then
    log "[cloud] Download done ✓"
else
    log "[cloud] Download FAILED (exit $EC) ✗"
    [ $FINAL_EXIT -eq 0 ] && FINAL_EXIT=$EC
fi

# ── Report ─────────────────────────────────────────────────
if [ $FINAL_EXIT -eq 0 ]; then
    log "[cloud] Cloud sync completed successfully ✓"
else
    log "[cloud] Cloud sync finished with errors (exit=$FINAL_EXIT)"
    log "[cloud] Check log for details: $LOG"
fi

log "=== Finished (exit=$FINAL_EXIT) ==="
exit $FINAL_EXIT
