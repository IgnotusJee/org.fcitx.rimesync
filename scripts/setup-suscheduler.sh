#!/system/bin/sh
# ============================================================
# rime-sync-scheduler — Su Scheduler setup script
# ============================================================
# Registers scheduled jobs via Su Scheduler that:
#   1. Trigger Rime local sync (via broadcast to LSPosed hook)
#   2. Wait for sync to complete
#   3. Run rclone bisync to remote storage
#
# Prerequisites:
#   - KernelSU / APatch / Magisk (root)
#   - Su Scheduler module installed
#   - This LSPosed module installed and enabled for fcitx5-android
#   - rclone configured via the app's UI
#
# Usage: sh setup-suscheduler.sh [--dry-run]
# ============================================================

BACKUP_SCRIPT="${0%/*}/backup.sh"
MODDIR="/data/adb/modules/rime-sync-scheduler"

# ── Ensure the backup script is reachable at standard module path ──
if [ ! -f "$BACKUP_SCRIPT" ]; then
    BACKUP_SCRIPT="$MODDIR/scripts/backup.sh"
fi
if [ ! -f "$BACKUP_SCRIPT" ]; then
    echo "ERROR: backup.sh not found. Place this script in scripts/ alongside backup.sh"
    exit 1
fi

DRY_RUN_FLAG=""
if [ "$1" = "--dry-run" ]; then
    DRY_RUN_FLAG="--dry-run"
    echo ">>> DRY RUN MODE <<<"
fi

echo "============================================"
echo " rime-sync-scheduler — Su Scheduler setup"
echo "============================================"
echo ""

# ── Check root ──────────────────────────────────────────────
if [ "$KSU" != "true" ] && [ "$APATCH" != "true" ]; then
    # Not running in module context — check for su
    if ! command -v su >/dev/null 2>&1; then
        echo "ERROR: Root access required."
        echo "Run from KernelSU / APatch / Magisk context, or use 'su -c'."
        exit 1
    fi
fi

# ── Check su-scheduler ──────────────────────────────────────
SU_SCHED=""
for candidate in \
    "/data/adb/modules/su_scheduler/system/bin/su-scheduler" \
    "/data/adb/modules/su-scheduler/system/bin/su-scheduler" \
    "su-scheduler"; do
    if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
        SU_SCHED="$candidate"
        break
    fi
done

if [ -z "$SU_SCHED" ]; then
    echo "ERROR: su-scheduler not found."
    echo ""
    echo "Install Su Scheduler from:"
    echo "  https://github.com/rexackermann/su-scheduler"
    echo ""
    echo "Quick install via curl:"
    echo "  curl -L https://github.com/rexackermann/su-scheduler/releases/latest/download/su-scheduler.zip -o /sdcard/su-scheduler.zip"
    echo "  Then flash the zip in KernelSU / APatch Manager."
    exit 1
fi
echo "su-scheduler: $SU_SCHED"
echo "backup script: $BACKUP_SCRIPT"
echo ""

# ── Clean old rime-sync jobs ────────────────────────────────
echo "Cleaning old rime-sync jobs..."
"$SU_SCHED" list 2>/dev/null | while read -r line; do
    case "$line" in
        *backup.sh*|*rime*|*rimesync*|*rime-sync*)
            id=$(echo "$line" | awk '{print $1}')
            if [ -n "$id" ] && [ "$id" != "ID" ]; then
                "$SU_SCHED" remove "$id" 2>/dev/null && echo "  Removed job $id"
            fi
            ;;
    esac
done

# ── Determine sync flags ────────────────────────────────────
SYNC_FLAG="--full-sync"
[ -n "$DRY_RUN_FLAG" ] && SYNC_FLAG="$SYNC_FLAG $DRY_RUN_FLAG"

# ── Register boot job ───────────────────────────────────────
echo ""
echo "Registering jobs..."
BOOT_CMD="sh ${BACKUP_SCRIPT} ${SYNC_FLAG}"
if [ -z "$DRY_RUN_FLAG" ]; then
    "$SU_SCHED" add boot "$BOOT_CMD; : --notify"
    echo "  ✓ boot — run on device startup"
else
    echo "  [DRY RUN] would add: boot → $BOOT_CMD"
fi

# ── Register periodic jobs (4x daily ≈ every 6 hours) ──────
SCHEDULE_TIMES="0000 0600 1200 1800"
PERIODIC_CMD="sh ${BACKUP_SCRIPT} ${SYNC_FLAG}"
for t in $SCHEDULE_TIMES; do
    if [ -z "$DRY_RUN_FLAG" ]; then
        "$SU_SCHED" add "$t" "$PERIODIC_CMD; : --notify"
        echo "  ✓ $t — daily at $(echo $t | sed 's/\(..\)\(..\)/\1:\2/')"
    else
        echo "  [DRY RUN] would add: $t → $PERIODIC_CMD"
    fi
done

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
if [ -z "$DRY_RUN_FLAG" ]; then
    echo "Current jobs:"
    echo "───────────────────────────────────────────"
    "$SU_SCHED" list
    echo "───────────────────────────────────────────"
    echo ""
    echo "Management commands:"
    echo "  su-scheduler list              # list all jobs"
    echo "  su-scheduler run <id>          # run a job manually"
    echo "  su-scheduler remove <id>       # remove a job"
    echo "  su-scheduler log               # view execution log"
    echo ""
    echo "To trigger immediately (test):"
    echo "  sh $BACKUP_SCRIPT --full-sync"
else
    echo "Dry run complete. Remove --dry-run to apply."
fi
