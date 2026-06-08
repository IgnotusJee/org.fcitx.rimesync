#!/system/bin/sh
# ============================================================
# rime-sync-scheduler — crond4android setup script
# !! DEPRECATED — use setup-suscheduler.sh instead !!
# ============================================================
# Sets up a cron job that:
#   1. Triggers rime local sync via broadcast
#   2. Waits for sync to complete
#   3. Runs rclone to backup to remote
#
# Prerequisites:
#   - KernelSU/Magisk with crond4android module installed
#   - This LSPosed module installed and enabled for fcitx5-android
#   - rclone binary available and configured
# ============================================================

CRON_FILE="/data/adb/crond/root"
BROADCAST_ACTION="org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC"
BROADCAST_PKG="org.fcitx.fcitx5.android"
BACKUP_SCRIPT="/data/adb/modules/rime-sync-scheduler/scripts/backup.sh"

# ── Cron schedule ──────────────────────────────────────────
# Every 6 hours at minute 0
CRON_SCHEDULE="0 */6 * * *"

# ── Build cron command ─────────────────────────────────────
CRON_CMD="${CRON_SCHEDULE} am broadcast -a ${BROADCAST_ACTION} -p ${BROADCAST_PKG} --receiver-foreground && sleep 15 && sh ${BACKUP_SCRIPT}"

echo "============================================"
echo " rime-sync-scheduler cron setup"
echo "============================================"
echo ""
echo "Schedule : Every 6 hours"
echo "Command  :"
echo "  1. am broadcast → trigger rime local sync"
echo "  2. sleep 10s → wait for sync to complete"
echo "  3. sh backup.sh → rclone to remote"
echo ""
echo "Cron file: $CRON_FILE"
echo ""

# ── Check prerequisites ────────────────────────────────────
if [ ! -d "/data/adb/crond" ]; then
    echo "ERROR: crond4android not installed."
    echo "Install from: https://github.com/powerAn2020/crond4android"
    exit 1
fi

# ── Add cron job ───────────────────────────────────────────
# Remove any existing entry first (idempotent)
if grep -q "TRIGGER_RIME_SYNC" "$CRON_FILE" 2>/dev/null; then
    echo "Removing existing rime sync cron entry..."
    sed -i '/TRIGGER_RIME_SYNC/d' "$CRON_FILE"
fi

echo "Adding cron entry..."
echo "$CRON_CMD" >> "$CRON_FILE"
chmod 644 "$CRON_FILE"

echo ""
echo "Done! Current cron entries:"
echo "───────────────────────────────────────────"
cat "$CRON_FILE"
echo "───────────────────────────────────────────"
echo ""
echo "To test manual trigger:"
echo "  am broadcast -a $BROADCAST_ACTION"
echo ""
echo "To check cron log:"
echo "  cat /data/adb/crond/run.log"
