# Rime Sync Scheduler

[中文版](README_CN.md)

LSPosed module for fcitx5-android: automated local + cloud Rime sync scheduling.

## How It Works

```
fcitx5 launch
  └─ LSPosed hook injected
       ├─ Reads installation.yaml → writes rime_paths.txt + rime_sync.json
       └─ Registers TRIGGER_RIME_SYNC broadcast receiver

su-scheduler fires daily (08:00)
  └─ backup.sh
       ├─ 1. Stop fcitx5, remove stale .temp.userdb, then start it headlessly
       ├─ 2. Local sync (broadcast triggers Rime sync)
       ├─ 3. Upload this device (rclone sync → remote)
       ├─ 4. Download other devices (rclone sync ← remote)
       ├─ 5. Clean again and run the final local sync
       └─ 6. Notify result, upload/download sizes, and elapsed time
```

## Prerequisites

- Android 8.0+ (arm64)
- Root (KernelSU / APatch / Magisk)
- [LSPosed](https://github.com/JingMatrix/LSPosed) framework
- [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) IME
- [rclone](https://rclone.org/) binary (arm64)
- [Su Scheduler](https://github.com/rexackermann/su-scheduler) module

## Install

### 1. Build

```sh
./gradlew assembleDebug
# output: app/build/outputs/apk/debug/app-debug.apk
```

### 2. Activate module

Enable in LSPosed Manager, scope: `fcitx5-android`.

### 3. Prepare rclone

Install the Android build of rclone in Termux (recommended):

```sh
pkg install rclone
```

The script first uses `/data/data/com.termux/files/usr/bin/rclone` in place, using
Android's system DNS resolver without relying on DNS redirection from proxy
modules such as Surfing. The scheduler runs as root; the Termux UI need not be
open. Keep Termux and its runtime installed, and update with `pkg upgrade rclone`.
The log records the selected binary path and version.

If the Termux binary is unavailable, the script checks PATH, then this location
and supported module paths:

```
/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/rclone_bin/rclone
```

Generic static Linux builds may query localhost port 53 when Android has no
`/etc/resolv.conf`, failing when the proxy is off. Prefer the Termux build above.

Create the remote config at `rime_sync/rclone.conf` (not inside `rclone_bin`):
```ini
[myremote]
type = s3
provider = Other
endpoint = https://your-s3.example.com
access_key_id = ...
secret_access_key = ...
```

### 4. Config

After fcitx5 starts, the hook auto-generates config files at:

```
/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/
├── rime_paths.txt    # Rime/sync directory paths (auto)
├── rime_sync.json    # Sync config (auto-generated with defaults)
└── rclone.conf       # rclone remote config (place manually)
```

`rime_sync.json` example:
```json
{
  "remote_path": "Rime/",
  "rclone_config": "/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/rclone.conf",
  "device_name": ""
}
```

| Field | Description |
|---|---|
| `remote_path` | Sub-path on remote storage |
| `rclone_config` | Path to rclone config file |
| `device_name` | Device name (leave empty to auto-detect from `installation.yaml`) |

### 5. Schedule

```sh
# Push scripts
adb push scripts/backup.sh scripts/setup-suscheduler.sh /data/local/tmp/

# Install Su Scheduler, then run setup (defaults to 08:00 daily)
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh"

# Custom time
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh 06:00"
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh 2230"

# Skip dry-run or test
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh --no-dry-run --no-test"
```

## Manual Sync

The script prevents overlapping runs. Before each local Rime sync it removes the
exact transient `.temp.userdb` (including `LOCK`) only after confirming that the
fcitx5 process has stopped; it does not remove the permanent user dictionaries.

```sh
# Full sync (local → upload → download → local load)
su -c "sh /sdcard/Scripts/rime_backup.sh --full-sync"

# Cloud only
su -c "sh /sdcard/Scripts/rime_backup.sh --cloud-only"

# Local only
su -c "sh /sdcard/Scripts/rime_backup.sh --local-only"

# Preview (no changes)
su -c "sh /sdcard/Scripts/rime_backup.sh --full-sync --dry-run"
```

Or trigger local sync via broadcast:
```sh
am broadcast -a org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC -p org.fcitx.fcitx5.android --receiver-foreground
```

## Known fcitx5-android Issue

Rime user-data sync in fcitx5-android can occasionally leave behind its temporary
LevelDB database, `.temp.userdb`, with a `LOCK` still held by an old process or not
cleaned up correctly. A later sync may show one error and log a message such as:

```text
Error opening db '.temp': ... LOCK already held by process
```

This can prevent some user-dictionary snapshots from being merged. See the related
upstream report, [fcitx5-android #825](https://github.com/fcitx5-android/fcitx5-android/issues/825).

This project works around the issue before every local sync: it force-stops fcitx5,
waits until the process has exited, removes the complete `.temp.userdb`, starts
fcitx5 headlessly, and then triggers Rime sync. A full run does this both before
upload and before merging downloaded snapshots. Do not delete only `LOCK` while
fcitx5 is running, as that can corrupt an active temporary LevelDB database. Schedule
the job for a time when the IME is not in use to avoid a brief input interruption.

Before each stop, the script saves the current user's selected input method. If
fcitx5 was selected, it restores that selection with `ime set` after restart and
verifies the result. Error exits also attempt restoration. Other selected keyboards
are left alone. Restoration failures are logged and make the run report failure.

## Manage Schedule

```sh
su -c su-scheduler list          # list jobs
su -c su-scheduler log           # view log
su -c su-scheduler remove <id>   # remove job
```

## Project Structure

```
rime-sync-scheduler/
├── app/src/main/java/org/fcitx/rimesync/
│   ├── RimeSyncHook.kt        # LSPosed hook (injects into fcitx5)
│   └── CloudSyncHelper.kt     # Path/config utilities
├── scripts/
│   ├── backup.sh              # Sync script (local + cloud)
│   └── setup-suscheduler.sh   # Su Scheduler setup script
├── rime_sync.json             # Config template
└── module.prop                # Module descriptor
```

## License

MIT
