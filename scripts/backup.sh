#!/system/bin/sh
# Stops fcitx and removes its transient database before every local Rime sync.
# Posts a final notification with result and cloud transfer sizes.

SYNC_DATA_DIR="/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync"
PATHS_FILE="${SYNC_DATA_DIR}/rime_paths.txt"
JSON_CONFIG="${SYNC_DATA_DIR}/rime_sync.json"
RCLONE_CACHE="/data/local/tmp/rime_sync_rclone_cache"
RUN_LOCK="/data/local/tmp/rime_sync_scheduler.lock"

MODDIR="/data/adb/modules/rime-sync-scheduler"
LOG="${MODDIR}/sync.log"
[ ! -d "$MODDIR" ] && LOG="/data/local/tmp/rime_sync.log"

FCITX_PACKAGE="org.fcitx.fcitx5.android"
FCITX_REMOTE_SERVICE="${FCITX_PACKAGE}/.FcitxRemoteService"
FCITX_IPC_ACTION="${FCITX_PACKAGE}.IPC"
BROADCAST_ACTION="${FCITX_PACKAGE}.action.TRIGGER_RIME_SYNC"

MODE="cloud"
DRY_RUN=""
FINAL_EXIT=0
ERROR_REASON=""
UPLOAD_AMOUNT="0 B"
DOWNLOAD_AMOUNT="0 B"
START_TIME=$(date +%s)
LOCK_HELD=false

json_get() {
    file="$1"
    key="$2"
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1
}

log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"
}

set_failure() {
    code="$1"
    reason="$2"
    [ "$FINAL_EXIT" -eq 0 ] && FINAL_EXIT="$code"
    [ -z "$ERROR_REASON" ] && ERROR_REASON="$reason"
}

parse_transfer_amount() {
    stats_file="$1"
    # Accept only byte quantities on both sides of the slash. This excludes
    # file counts and NOTICE errors containing URLs (e.g. "Failed to sync...").
    # Match both formats in one pass so the last valid byte statistic wins.
    amount=$(sed -nE 's/.*(Transferred:|NOTICE:)[[:space:]]*([0-9]+(\.[0-9]+)?[[:space:]]+(B|[kKMGTPEZY]i?B))[[:space:]]*\/[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]+(B|[kKMGTPEZY]i?B)([[:space:],]|$).*/\2/p' "$stats_file" 2>/dev/null | tail -1)
    amount=$(printf '%s\n' "$amount" | sed -E 's/[[:space:]]+/ /g')
    [ -z "$amount" ] && amount="0 B"
    echo "$amount"
}

notify_result() {
    exit_code="$1"
    elapsed=$(($(date +%s) - START_TIME))
    minutes=$((elapsed / 60))
    seconds=$((elapsed % 60))
    if [ "$exit_code" -eq 0 ]; then
        title="✅ Rime 同步"
    else
        title="❌ Rime 同步"
    fi
    [ -n "$DRY_RUN" ] && title="${title} · 演练"
    if [ "$minutes" -gt 0 ]; then
        duration="${minutes}m${seconds}s"
    else
        duration="${seconds}s"
    fi
    body="↑$UPLOAD_AMOUNT  ↓$DOWNLOAD_AMOUNT  ⏱$duration"
    # Notifications posted directly as uid 0 are discarded on this Android build.
    # Drop to the system shell uid, whose built-in notification channel is visible.
    safe_title=$(echo "$title" | tr -d "'")
    safe_body=$(echo "$body" | tr -d "'")
    su 2000 -c "cmd notification post -S bigtext -t '$safe_title' rime_sync_scheduler '$safe_body'" >/dev/null 2>&1 || true
}

on_exit() {
    exit_code=$?
    trap - EXIT
    [ "$FINAL_EXIT" -ne 0 ] && exit_code="$FINAL_EXIT"
    $LOCK_HELD && rmdir "$RUN_LOCK" 2>/dev/null
    notify_result "$exit_code"
    exit "$exit_code"
}
trap on_exit EXIT

while [ $# -gt 0 ]; do
    case "$1" in
        --full-sync) MODE="full" ;;
        --cloud-only) MODE="cloud" ;;
        --local-only) MODE="local" ;;
        --dry-run) DRY_RUN="--dry-run" ;;
        *) ERROR_REASON="未知参数：$1"; echo "Usage: sh backup.sh [--full-sync|--cloud-only|--local-only] [--dry-run]"; exit 2 ;;
    esac
    shift
done

if mkdir "$RUN_LOCK" 2>/dev/null; then
    LOCK_HELD=true
else
    ERROR_REASON="已有同步任务正在运行"
    log "ERROR: another sync task is already running."
    exit 3
fi
log "=== Starting (mode=$MODE) ==="

# Load paths before local sync because cleanup needs the exact Rime directory.
SYNC_DIR=""
RIME_DIR=""
if [ -f "$PATHS_FILE" ]; then
    RIME_DIR=$(sed -n '1p' "$PATHS_FILE" | tr -d '\r')
    SYNC_DIR=$(sed -n '2p' "$PATHS_FILE" | tr -d '\r')
    if [ -z "$SYNC_DIR" ] || [ ! -d "$SYNC_DIR" ]; then
        [ -n "$RIME_DIR" ] && [ -d "$RIME_DIR" ] && SYNC_DIR="$RIME_DIR"
    fi
fi
if [ -z "$RIME_DIR" ] || [ ! -d "$RIME_DIR" ]; then
    ERROR_REASON="找不到 Rime 数据目录"
    log "ERROR: No valid Rime data directory; launch fcitx5 once after installing the module."
    exit 1
fi

prepare_fcitx_for_sync() {
    temp_userdb="${RIME_DIR}/.temp.userdb"
    # fcitx5-android/Rime may leave this transient LevelDB locked after sync
    # (upstream: https://github.com/fcitx5-android/fcitx5-android/issues/825).
    # Removing only LOCK while fcitx is alive is unsafe: stop the owning process
    # first, then discard the complete transient database so Rime can recreate it.
    log "[local] Stopping fcitx before sync..."
    am force-stop "$FCITX_PACKAGE" >/dev/null 2>&1
    retries=20
    while [ "$retries" -gt 0 ] && pidof "$FCITX_PACKAGE" >/dev/null 2>&1; do
        sleep 1
        retries=$((retries - 1))
    done
    if pidof "$FCITX_PACKAGE" >/dev/null 2>&1; then
        log "[local] ERROR: fcitx did not stop; refusing to remove temporary database."
        return 1
    fi

    # Delete only the exact transient DB, and only after the process has stopped.
    case "$temp_userdb" in
        */org.fcitx.fcitx5.android/files/data/rime/.temp.userdb)
            if [ -e "$temp_userdb" ]; then
                rm -rf "$temp_userdb" || return 1
                log "[local] Removed stale .temp.userdb (including LOCK)."
            else
                log "[local] No stale .temp.userdb found."
            fi ;;
        *) log "[local] ERROR: unexpected temp database path: $temp_userdb"; return 1 ;;
    esac

    log "[local] Starting fcitx service headlessly..."
    # Android blocks a normal background service start after force-stop.
    am start-foreground-service -n "$FCITX_REMOTE_SERVICE" -a "$FCITX_IPC_ACTION" >/dev/null 2>&1 || return 1
    retries=15
    while [ "$retries" -gt 0 ] && ! pidof "$FCITX_PACKAGE" >/dev/null 2>&1; do
        sleep 1
        retries=$((retries - 1))
    done
    pidof "$FCITX_PACKAGE" >/dev/null 2>&1 || return 1
    sleep 3
}

run_local_sync() {
    stage="$1"
    if ! prepare_fcitx_for_sync; then
        log "[local] ERROR: unable to prepare fcitx."
        set_failure 10 "${stage}前无法重启 fcitx"
        return 1
    fi
    log "[local] Sending Rime sync broadcast ($stage)..."
    if ! am broadcast -a "$BROADCAST_ACTION" -p "$FCITX_PACKAGE" --receiver-foreground >/dev/null 2>&1; then
        set_failure 11 "${stage}广播失败"
        return 1
    fi
    log "[local] Waiting 15s for Rime sync to flush..."
    sleep 15
    if [ -e "${RIME_DIR}/.temp.userdb/LOCK" ]; then
        log "[local] ERROR: Rime left a locked temporary database."
        set_failure 12 "${stage}仍残留 LOCK"
        return 1
    fi
    log "[local] Rime sync completed ($stage)."
}

if [ "$MODE" = "full" ] || [ "$MODE" = "local" ]; then
    run_local_sync "上传前同步" || exit "$FINAL_EXIT"
    [ "$MODE" = "local" ] && exit 0
fi

RCLONE=""
# Termux's Android build uses the system DNS resolver. Generic static Linux
# builds can fall back to localhost:53 and depend on a proxy's DNS redirect.
# Run in place to preserve Termux's dynamic library/runtime paths.
TERMUX_RCLONE="/data/data/com.termux/files/usr/bin/rclone"
if [ -x "$TERMUX_RCLONE" ]; then
    RCLONE="$TERMUX_RCLONE"
elif command -v rclone >/dev/null 2>&1; then
    RCLONE=$(command -v rclone)
else
    for candidate in "${SYNC_DATA_DIR}/rclone_bin/rclone" /data/adb/modules/rclone-binary/system/bin/rclone /data/adb/modules/rclone/system/bin/rclone /data/adb/modules/rime-sync-scheduler/rclone; do
        [ -f "$candidate" ] || continue
        if [ -x "$candidate" ]; then
            RCLONE="$candidate"
        else
            RCLONE="/data/local/tmp/rime_sync_rclone"
            cp -f "$candidate" "$RCLONE" && chmod 755 "$RCLONE"
        fi
        break
    done
fi
if [ -z "$RCLONE" ]; then
    ERROR_REASON="找不到 rclone"; log "[cloud] ERROR: rclone binary not found."; exit 1
fi

REMOTE_SUB_PATH="rime/"
RCLONE_CONFIG_PATH="${SYNC_DATA_DIR}/rclone.conf"
if [ -f "$JSON_CONFIG" ]; then
    configured_remote=$(json_get "$JSON_CONFIG" "remote_path")
    configured_config=$(json_get "$JSON_CONFIG" "rclone_config")
    [ -n "$configured_remote" ] && REMOTE_SUB_PATH="$configured_remote"
    [ -n "$configured_config" ] && RCLONE_CONFIG_PATH="$configured_config"
fi
REMOTE_SUB_PATH="${REMOTE_SUB_PATH#/}"
REMOTE_SUB_PATH="${REMOTE_SUB_PATH%/}"
if [ -z "$SYNC_DIR" ] || [ ! -d "$SYNC_DIR" ]; then
    ERROR_REASON="找不到本地同步目录"; log "[cloud] ERROR: No valid sync directory."; exit 1
fi

DEVICE_NAME=$(json_get "$JSON_CONFIG" "device_name")
if [ -z "$DEVICE_NAME" ] && [ -f "$RIME_DIR/installation.yaml" ]; then
    DEVICE_NAME=$(sed -n 's/.*installation_id:[[:space:]]*"\?\([^"#[:space:]]*\)"\?.*/\1/p' "$RIME_DIR/installation.yaml" | tr -d '\r')
fi
if [ -z "$DEVICE_NAME" ]; then
    device_codename=$(getprop ro.product.device)
    for device_dir in "$SYNC_DIR"/*; do
        [ -d "$device_dir" ] || continue
        candidate_name=$(basename "$device_dir")
        candidate_lower=$(echo "$candidate_name" | tr '[:upper:]' '[:lower:]')
        codename_lower=$(echo "$device_codename" | tr '[:upper:]' '[:lower:]')
        case "$candidate_lower" in "$codename_lower"*) DEVICE_NAME="$candidate_name"; break ;; esac
    done
fi
[ -z "$DEVICE_NAME" ] && DEVICE_NAME=$(getprop ro.product.device)
LOCAL_DEVICE_DIR="$SYNC_DIR/$DEVICE_NAME"

if [ ! -s "$RCLONE_CONFIG_PATH" ]; then
    ERROR_REASON="rclone 配置不存在"; log "[cloud] ERROR: rclone.conf not found at $RCLONE_CONFIG_PATH"; exit 1
fi
REMOTE_NAME=$(sed -n 's/^\[\([^]]*\)\]/\1/p' "$RCLONE_CONFIG_PATH" | tr -d '\r' | head -1)
if [ -z "$REMOTE_NAME" ]; then
    ERROR_REASON="rclone 配置中没有远端"; log "[cloud] ERROR: no remote found in rclone.conf."; exit 1
fi
RCLONE_REMOTE_FULL="${REMOTE_NAME}:${REMOTE_SUB_PATH}"
log "[cloud] rclone binary: $RCLONE"
if ! rclone_version=$("$RCLONE" version 2>&1); then
    ERROR_REASON="rclone 无法运行"
    log "[cloud] ERROR: rclone version check failed: $rclone_version"
    exit 1
fi
log "[cloud] rclone version: $(printf '%s\n' "$rclone_version" | head -1)"
log "[cloud] Local source: $SYNC_DIR"
log "[cloud] Remote: $RCLONE_REMOTE_FULL"
log "[cloud] Device name: $DEVICE_NAME"

mkdir -p "$RCLONE_CACHE"
UPLOAD_STATS="${RCLONE_CACHE}/upload.$$.log"
DOWNLOAD_STATS="${RCLONE_CACHE}/download.$$.log"
rm -f "$UPLOAD_STATS" "$DOWNLOAD_STATS"

if [ -d "$LOCAL_DEVICE_DIR" ]; then
    log "[cloud] Upload: $LOCAL_DEVICE_DIR -> $RCLONE_REMOTE_FULL/$DEVICE_NAME"
    "$RCLONE" sync "$LOCAL_DEVICE_DIR" "$RCLONE_REMOTE_FULL/$DEVICE_NAME" --config "$RCLONE_CONFIG_PATH" --cache-dir "$RCLONE_CACHE" --create-empty-src-dirs --no-check-certificate --timeout 30s --stats 5s --stats-one-line --stats-log-level NOTICE $DRY_RUN >"$UPLOAD_STATS" 2>&1
    upload_exit=$?
    cat "$UPLOAD_STATS" >> "$LOG"
    UPLOAD_AMOUNT=$(parse_transfer_amount "$UPLOAD_STATS")
    if [ "$upload_exit" -eq 0 ]; then log "[cloud] Upload done ($UPLOAD_AMOUNT)."; else log "[cloud] Upload FAILED (exit $upload_exit, transferred $UPLOAD_AMOUNT)."; set_failure "$upload_exit" "上传失败，退出码 $upload_exit"; fi
else
    log "[cloud] Upload skipped: local device directory not found."
fi

log "[cloud] Download: $RCLONE_REMOTE_FULL -> $SYNC_DIR"
"$RCLONE" sync "$RCLONE_REMOTE_FULL" "$SYNC_DIR" --config "$RCLONE_CONFIG_PATH" --cache-dir "$RCLONE_CACHE" --create-empty-src-dirs --no-check-certificate --timeout 30s --exclude "$DEVICE_NAME/**" --stats 5s --stats-one-line --stats-log-level NOTICE $DRY_RUN >"$DOWNLOAD_STATS" 2>&1
download_exit=$?
cat "$DOWNLOAD_STATS" >> "$LOG"
DOWNLOAD_AMOUNT=$(parse_transfer_amount "$DOWNLOAD_STATS")
if [ "$download_exit" -eq 0 ]; then log "[cloud] Download done ($DOWNLOAD_AMOUNT)."; else log "[cloud] Download FAILED (exit $download_exit, transferred $DOWNLOAD_AMOUNT)."; set_failure "$download_exit" "下载失败，退出码 $download_exit"; fi
rm -f "$UPLOAD_STATS" "$DOWNLOAD_STATS"

# Merge downloaded snapshots only after both cloud operations succeeded.
if [ "$FINAL_EXIT" -eq 0 ]; then run_local_sync "下载后合并" || true; fi
if [ "$FINAL_EXIT" -eq 0 ]; then
    log "=== Finished successfully (upload=$UPLOAD_AMOUNT, download=$DOWNLOAD_AMOUNT) ==="
else
    log "=== Finished with errors (exit=$FINAL_EXIT, upload=$UPLOAD_AMOUNT, download=$DOWNLOAD_AMOUNT) ==="
fi
exit "$FINAL_EXIT"
