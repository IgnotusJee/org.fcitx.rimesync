#!/system/bin/sh
# ============================================================
# rime-sync-scheduler — Su Scheduler setup
# ============================================================
# 1. Check root & su-scheduler
# 2. Copy backup.sh → /sdcard/Scripts/rime_backup.sh
# 3. Dry-run test
# 4. Register daily job (default 08:00, overridable)
# 5. su-scheduler test
#
# Usage:
#   sh setup-suscheduler.sh                 # default 08:00
#   sh setup-suscheduler.sh 08:00           # 8:00 AM
#   sh setup-suscheduler.sh 2230 --no-dry-run --no-test
#
# Flags:
#   --no-dry-run   Skip the dry-run test
#   --no-test      Skip su-scheduler self-test
# ============================================================

set -u

BACKUP_SRC="${0%/*}/backup.sh"
SCRIPT_DIR="/sdcard/Scripts"
BACKUP_DST="${SCRIPT_DIR}/rime_backup.sh"

# ── Parse args ─────────────────────────────────────────────────
TIME=""
DRY_RUN=true
RUN_TEST=true

for arg in "$@"; do
    case "$arg" in
        --no-dry-run) DRY_RUN=false ;;
        --no-test)    RUN_TEST=false ;;
        *)
            # Anything else is treated as the time
            if [ -z "$TIME" ]; then TIME="$arg"; fi
            ;;
    esac
done

[ -z "$TIME" ] && TIME="0800"  # default 08:00

# Normalize time: HH:MM → HHMM
TIME=$(echo "$TIME" | tr -d ':')
# Validate
case "$TIME" in
    [01][0-9][0-5][0-9]|2[0-3][0-5][0-9])
        # Valid 24h HHMM
        ;;
    *)
        echo "ERROR: Invalid time '$1'. Use HHMM or HH:MM (24h format)."
        echo "  Example: 0800  20:00  2230"
        exit 1
        ;;
esac

echo "============================================"
echo " rime-sync-scheduler · Su Scheduler setup"
echo " Schedule: ${TIME} daily"
echo "============================================"
echo ""

# ═══════════════════════════════════════════════════════════════
#  Step 1: Check root
# ═══════════════════════════════════════════════════════════════
echo "[1] Checking root..."
if [ "$(id -u)" != "0" ] && [ "$KSU" != "true" ] && [ "$APATCH" != "true" ]; then
    echo "  ERROR: Root required. Run as: su -c 'sh $0 $*'"
    exit 1
fi
echo "  ✓ root OK"

# ═══════════════════════════════════════════════════════════════
#  Step 2: Find su-scheduler
# ═══════════════════════════════════════════════════════════════
echo ""
echo "[2] Checking su-scheduler..."
SU_SCHED=""
for p in /data/adb/modules/su_scheduler/system/bin/su-scheduler \
         /data/adb/modules/su-scheduler/system/bin/su-scheduler; do
    if [ -x "$p" ]; then SU_SCHED="$p"; break; fi
done
if ! command -v su-scheduler >/dev/null 2>&1 && [ -z "$SU_SCHED" ]; then
    echo "  ERROR: su-scheduler not found."
    echo ""
    echo "  Install Su Scheduler:"
    echo "    https://github.com/rexackermann/su-scheduler"
    exit 1
fi
[ -z "$SU_SCHED" ] && SU_SCHED="su-scheduler"
echo "  ✓ $SU_SCHED"

# ═══════════════════════════════════════════════════════════════
#  Step 3: Copy backup script
# ═══════════════════════════════════════════════════════════════
echo ""
echo "[3] Installing backup script..."
mkdir -p "$SCRIPT_DIR"

if [ ! -f "$BACKUP_SRC" ]; then
    echo "  ERROR: backup.sh not found at $BACKUP_SRC"
    echo "  Run this script from the rime-sync-scheduler scripts/ directory."
    exit 1
fi

cp -f "$BACKUP_SRC" "$BACKUP_DST"
chmod 755 "$BACKUP_DST"
echo "  ✓ $BACKUP_DST"

# ═══════════════════════════════════════════════════════════════
#  Step 4: Dry-run test
# ═══════════════════════════════════════════════════════════════
if $DRY_RUN; then
    echo ""
    echo "[4] Dry-run test..."
    echo "─────────────────────────────────────────────"
    DRY_OUTPUT=$(sh "$BACKUP_DST" --full-sync --dry-run 2>&1)
    DRY_EXIT=$?
    echo "$DRY_OUTPUT" | while read -r line; do echo "  $line"; done
    echo "─────────────────────────────────────────────"
    if [ $DRY_EXIT -ne 0 ]; then
        echo "  WARNING: dry-run exit code = $DRY_EXIT"
        echo "  Check: rclone binary? rclone.conf? paths?"
        echo "  Continuing with registration anyway..."
    else
        echo "  ✓ dry-run passed"
    fi
    echo ""
else
    echo ""
    echo "[4] Dry-run test: SKIPPED"
fi

# ═══════════════════════════════════════════════════════════════
#  Step 5: Register with su-scheduler
# ═══════════════════════════════════════════════════════════════
echo "[5] Registering scheduled job..."

# Su Scheduler 1.6.x removes tasks by command substring. This also handles
# older entries whose trigger or notification modifiers differ.
"$SU_SCHED" remove "rime_backup" >/dev/null 2>&1 || true

# Register new job
SYNC_CMD="sh ${BACKUP_DST} --full-sync"
"$SU_SCHED" add "$TIME" "$SYNC_CMD"
echo "  ✓ Registered: ${TIME} daily → sh ${BACKUP_DST} --full-sync"

# ── su-scheduler test ────────────────────────────────────────
if $RUN_TEST; then
    echo ""
    echo "Running su-scheduler self-test..."
    "$SU_SCHED" test 2>&1 | while read -r line; do
        echo "  $line"
    done
else
    echo ""
    echo "su-scheduler test: SKIPPED"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo "  Script:   $BACKUP_DST"
echo "  Schedule: daily at $(echo "$TIME" | sed 's/\(..\)\(..\)/\1:\2/')"
echo ""
echo "  Management:"
echo "    su-scheduler list        # show jobs"
echo "    su-scheduler log         # view log"
echo "    su-scheduler remove <id> # remove job"
echo ""
echo "  Manual run:"
echo "    su -c 'sh $BACKUP_DST --full-sync'"
echo "    su -c 'sh $BACKUP_DST --cloud-only'"
