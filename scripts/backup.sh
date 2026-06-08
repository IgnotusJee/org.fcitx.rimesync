#!/system/bin/sh
# ============================================================
# rime-sync-scheduler — unified sync script
# ============================================================
# Reads config from fcitx5's external files dir (written by LSPosed hook).
# Config: /storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/
#
# Modes (flags):
#   --full-sync    Local sync first, then cloud sync
#   --cloud-only   Cloud sync only
#   --local-only   Local sync only
#   --dry-run      rclone dry-run (preview)
# ============================================================

# ── fcitx5 sync data dir (hook writes here) ─────────────────
SYNC_DATA_DIR="/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync"
PATHS_FILE="${SYNC_DATA_DIR}/rime_paths.txt"
JSON_CONFIG="${SYNC_DATA_DIR}/rime_sync.json"

RCLONE_CACHE="/data/local/tmp/rclone_cache"

# ── Logging ────────────────────────────────────────────────
MODDIR="/data/adb/modules/rime-sync-scheduler"
LOG="${MODDIR}/sync.log"
[ ! -d "$MODDIR" ] && LOG="/data/local/tmp/rime_sync.log"

# ── Broadcast constants ────────────────────────────────────
BROADCAST_ACTION="org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC"
BROADCAST_TARGET="org.fcitx.fcitx5.android"

# ═══════════════════════════════════════════════════════════════
#  JSON helpers (no jq — pure sed/grep)
# ═══════════════════════════════════════════════════════════════
json_get() {
    local file="$1" key="$2"
    sed -n 's/.*"'"$key"'"\s*:\s*"\([^"]*\)".*/\1/p' "$file" | head -1
}

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
if command -v rclone >/dev/null 2>&1; then
    RCLONE="$(command -v rclone)"
else
    for p in /data/adb/modules/rclone-binary/system/bin/rclone \
             /data/adb/modules/rclone/system/bin/rclone \
             /data/adb/modules/rime-sync-scheduler/rclone \
             /data/local/tmp/rime_sync_rclone; do
        [ -x "$p" ] && { RCLONE="$p"; break; }
    done
fi

if [ -z "$RCLONE" ]; then
    log "[cloud] ERROR: rclone binary not found."
    exit 1
fi
log "[cloud] rclone binary: $RCLONE"

# ═══════════════════════════════════════════════════════════════
#  Phase 3: Load JSON config
# ═══════════════════════════════════════════════════════════════
REMOTE_SUB_PATH="rime/"
RCLONE_CONFIG_PATH="${SYNC_DATA_DIR}/rclone.conf"

if [ -f "$JSON_CONFIG" ]; then
    REMOTE_SUB_PATH=$(json_get "$JSON_CONFIG" "remote_path")
    [ -z "$REMOTE_SUB_PATH" ] && REMOTE_SUB_PATH="rime/"
    RCLONE_CONFIG_PATH=$(json_get "$JSON_CONFIG" "rclone_config")
    [ -z "$RCLONE_CONFIG_PATH" ] && RCLONE_CONFIG_PATH="${SYNC_DATA_DIR}/rclone.conf"
fi
REMOTE_SUB_PATH="${REMOTE_SUB_PATH#/}"
log "[cloud] Remote sub-path: $REMOTE_SUB_PATH"
log "[cloud] rclone config: $RCLONE_CONFIG_PATH"

# ═══════════════════════════════════════════════════════════════
#  Phase 4: Read local sync directory
# ═══════════════════════════════════════════════════════════════
SYNC_DIR=""
RIME_DIR=""
if [ -f "$PATHS_FILE" ]; then
    RIME_DIR=$(sed -n '1p' "$PATHS_FILE" | tr -d '\r')
    SYNC_DIR=$(sed -n '2p' "$PATHS_FILE" | tr -d '\r')
    if [ -z "$SYNC_DIR" ] || [ ! -d "$SYNC_DIR" ]; then
        [ -n "$RIME_DIR" ] && [ -d "$RIME_DIR" ] && SYNC_DIR="$RIME_DIR"
    fi
fi

if [ -z "$SYNC_DIR" ] || [ ! -d "$SYNC_DIR" ]; then
    log "[cloud] ERROR: No valid sync directory."
    log "[cloud]   paths file: $([ -f "$PATHS_FILE" ] && cat "$PATHS_FILE" || echo 'NOT FOUND')"
    log "[cloud]   Hint: launch fcitx5 at least once after installing the LSPosed module."
    exit 1
fi
log "[cloud] Local source: $SYNC_DIR"

# ═══════════════════════════════════════════════════════════════
#  Phase 5: Detect device name
# ═══════════════════════════════════════════════════════════════
DEVICE_NAME=$(json_get "$JSON_CONFIG" "device_name")
# Fallback: installation.yaml
if [ -z "$DEVICE_NAME" ] && [ -n "$RIME_DIR" ] && [ -f "$RIME_DIR/installation.yaml" ]; then
    DEVICE_NAME=$(sed -n 's/.*installation_id:[[:space:]]*"\?\([^"#[:space:]]*\)"\?.*/\1/p' "$RIME_DIR/installation.yaml" | tr -d '\r')
fi
# Fallback: match local sync dirs
if [ -z "$DEVICE_NAME" ] && [ -d "$SYNC_DIR" ]; then
    DEVICE_CODENAME=$(getprop ro.product.device)
    for d in "$SYNC_DIR"/*; do
        [ -d "$d" ] || continue
        dn=$(basename "$d")
        dn_lower=$(echo "$dn" | tr '[:upper:]' '[:lower:]')
        dc_lower=$(echo "$DEVICE_CODENAME" | tr '[:upper:]' '[:lower:]')
        case "$dn_lower" in "$dc_lower"*) DEVICE_NAME="$dn"; break ;; esac
    done
fi
[ -z "$DEVICE_NAME" ] && DEVICE_NAME="$(getprop ro.product.device)"
log "[cloud] Device name: $DEVICE_NAME"

LOCAL_DEVICE_DIR="$SYNC_DIR/$DEVICE_NAME"
[ ! -d "$LOCAL_DEVICE_DIR" ] && log "[cloud] WARNING: local device dir not found: $LOCAL_DEVICE_DIR"

# ═══════════════════════════════════════════════════════════════
#  Phase 6: Validate rclone config
# ═══════════════════════════════════════════════════════════════
if [ ! -f "$RCLONE_CONFIG_PATH" ] || [ ! -s "$RCLONE_CONFIG_PATH" ]; then
    log "[cloud] ERROR: rclone.conf not found at $RCLONE_CONFIG_PATH"
    log "[cloud]   Hint: copy your rclone.conf to ${SYNC_DATA_DIR}/rclone.conf"
    exit 1
fi

REMOTE_NAME=$(sed -n 's/^\[\([^]]*\)\]/\1/p' "$RCLONE_CONFIG_PATH" | tr -d '\r' | head -1)
if [ -z "$REMOTE_NAME" ]; then
    log "[cloud] ERROR: No remote found in rclone.conf"
    exit 1
fi
log "[cloud] Remote: $REMOTE_NAME"

RCLONE_REMOTE_FULL="${REMOTE_NAME}:${REMOTE_SUB_PATH}"
log "[cloud] Full remote: $RCLONE_REMOTE_FULL"

# ═══════════════════════════════════════════════════════════════
#  Phase 7: Two-step rclone sync (upload → download)
# ═══════════════════════════════════════════════════════════════
mkdir -p "$RCLONE_CACHE"
export HOME="$RCLONE_CACHE"
export TMPDIR="$RCLONE_CACHE"

DRY_FLAG=""
[ -n "$DRY_RUN" ] && DRY_FLAG="--dry-run"
FINAL_EXIT=0

# ── Step A: Upload ────────────────────────────────────────
if [ -d "$LOCAL_DEVICE_DIR" ]; then
    log "[cloud] Upload: $LOCAL_DEVICE_DIR → $RCLONE_REMOTE_FULL/$DEVICE_NAME"
    [ -n "$DRY_RUN" ] && log "[cloud] *** DRY RUN ***"
    "$RCLONE" sync "$LOCAL_DEVICE_DIR" "$RCLONE_REMOTE_FULL/$DEVICE_NAME" \
        --config "$RCLONE_CONFIG_PATH" \
        --create-empty-src-dirs \
        --no-check-certificate --timeout 30s \
        --log-file "$LOG" --log-level INFO \
        $DRY_FLAG >> "$LOG" 2>&1
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

# ── Step B: Download ──────────────────────────────────────
log "[cloud] Download: $RCLONE_REMOTE_FULL → $SYNC_DIR (excluding $DEVICE_NAME)"
[ -n "$DRY_RUN" ] && log "[cloud] *** DRY RUN ***"
"$RCLONE" sync "$RCLONE_REMOTE_FULL" "$SYNC_DIR" \
    --config "$RCLONE_CONFIG_PATH" \
    --create-empty-src-dirs \
    --no-check-certificate --timeout 30s \
    --log-file "$LOG" --log-level INFO \
    --exclude "$DEVICE_NAME/**" \
    $DRY_FLAG >> "$LOG" 2>&1
EC=$?
if [ $EC -eq 0 ]; then
    log "[cloud] Download done ✓"
else
    log "[cloud] Download FAILED (exit $EC) ✗"
    [ $FINAL_EXIT -eq 0 ] && FINAL_EXIT=$EC
fi

# ── Report ────────────────────────────────────────────────
if [ $FINAL_EXIT -eq 0 ]; then
    log "[cloud] Cloud sync completed successfully ✓"
else
    log "[cloud] Cloud sync finished with errors (exit=$FINAL_EXIT)"
fi

log "=== Finished (exit=$FINAL_EXIT) ==="
exit $FINAL_EXIT
