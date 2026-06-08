#!/system/bin/sh
# ============================================================
# rime-sync-scheduler — rclone backup script
# ============================================================
# Runs AFTER rime local sync has been triggered via broadcast.
# This script syncs the rime data directory to a rclone remote.
#
# Usage: sh backup.sh [--dry-run]
# ============================================================

set -e

# ── Configuration ──────────────────────────────────────────
# Rime data root (change if your device uses different path)
RIME_DIR="/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/data/fcitx5/rime"

# Rclone remote and path (set your own)
RCLONE_REMOTE="myremote:rime-backup"

# Rclone config file (lives in rime data dir with rime's built-in rclone support)
RCLONE_CONFIG="${RIME_DIR}/rclone.conf"

# Log file
LOG="/data/adb/crond/rime_backup.log"

# ── Parse args ─────────────────────────────────────────────
DRY_RUN=""
if [ "$1" = "--dry-run" ]; then
    DRY_RUN="--dry-run"
    echo "[$(date)] DRY RUN MODE" | tee -a "$LOG"
fi

# ── Check rime data exists ─────────────────────────────────
if [ ! -d "$RIME_DIR" ]; then
    echo "[$(date)] ERROR: Rime directory not found: $RIME_DIR" | tee -a "$LOG"
    exit 1
fi

# ── Check rclone ───────────────────────────────────────────
if ! command -v rclone >/dev/null 2>&1; then
    echo "[$(date)] ERROR: rclone not found in PATH" | tee -a "$LOG"
    exit 1
fi

# ── Sync ───────────────────────────────────────────────────
echo "[$(date)] Starting rclone sync..." | tee -a "$LOG"
echo "  Source : $RIME_DIR" | tee -a "$LOG"
echo "  Dest   : $RCLONE_REMOTE" | tee -a "$LOG"

rclone sync "$RIME_DIR" "$RCLONE_REMOTE" \
    --config "$RCLONE_CONFIG" \
    --log-file "$LOG" \
    --log-level INFO \
    --exclude "rclone.conf" \
    $DRY_RUN

EXIT_CODE=$?

if [ $EXIT_CODE -eq 0 ]; then
    echo "[$(date)] Sync completed successfully" | tee -a "$LOG"
else
    echo "[$(date)] Sync failed with exit code $EXIT_CODE" | tee -a "$LOG"
fi

exit $EXIT_CODE
