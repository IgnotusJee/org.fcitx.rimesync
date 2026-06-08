# Rime Sync Scheduler

LSPosed module that triggers [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) rime plugin's local sync (`api_->sync_user_data()`) on demand via broadcast, then optionally runs rclone bisync for bidirectional cloud sync. Paired with KernelSU/APatch + [Su Scheduler](https://github.com/rexackermann/su-scheduler) for fully automated periodic sync.

## Architecture

```
[su-scheduler / manual trigger]
    │  am broadcast -a org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC
    ▼
┌─────────────────────────────────────────────────────┐
│  LSPosed hook (injected into fcitx5-android process) │
│                                                       │
│  BroadcastReceiver.onReceive()                        │
│    → background thread                                │
│      → FcitxDaemon.connect()     // ensures running   │
│      → runImmediately { fcitx dispatcher thread:       │
│          setFcitxAddonSubConfig("rime", "sync")        │
│            ↓ JNI                                       │
│          Fcitx::setAddonSubConfig(rime, sync)          │
│            ↓                                           │
│          RimeEngine::setSubConfig("sync")              │
│            ↓                                           │
│          sync(true) → api_->sync_user_data()           │
│        }                                               │
└─────────────────────────────────────────────────────┘
    │
    ▼ (optional)
  rclone sync <rime_dir>/sync/ remote:rime-backup
```

## Key design decision: `setAddonSubConfig` over `activateAction`

The rime plugin registers sync as a fcitx user interface action (`"fcitx-rime-sync"`). Calling `activateAction(id)` through the fcitx action system **requires an active InputContext** (a focused text field), because `native-lib.cpp:activateAction()` checks:

```cpp
void activateAction(int id) {
    auto *ic = p_frontend->call<IAndroidFrontend::activeInputContext>();
    if (!ic) return;  // ← blocks background execution
    ...
}
```

Instead, this module calls `setAddonSubConfig("rime", "sync", emptyConfig)`, which goes through fcitx's addon config dispatch system. The native path is:

```cpp
// native-lib.cpp:923-927
Java_..._setFcitxAddonSubConfig(JNIEnv *env, jclass, jstring addon, jstring path, jobject config) {
    RETURN_IF_NOT_RUNNING                                    // only checks fcitx is running
    Fcitx::Instance().setAddonSubConfig(addon, path, ...);   // no InputContext needed
}

// native-lib.cpp:251-257
void setAddonSubConfig(addonName, path, config) {
    auto addonInstance = getAddonInstance(addonName);        // need rime loaded
    addonInstance->setSubConfig(path, config);                // dispatches to rime
}

// rimeengine.cpp:336-343
bool RimeEngine::setSubConfig(path, config) {
    if (path == "sync") { sync(true); return true; }         // zero context requirements
}
```

**Only requirements:** fcitx running + rime addon loaded. No focused text field needed.

## Prerequisites

| Component | Purpose |
|---|---|
| [LSPosed](https://github.com/LSPosed/LSPosed) | Hook framework, injects code into fcitx5-android |
| fcitx5-android with rime plugin | Target app |
| (optional) [KernelSU](https://kernelsu.org/) / [APatch](https://apatch.dev/) | Root for scheduler + rclone access to app data |
| (optional) [Su Scheduler](https://github.com/rexackermann/su-scheduler) | Modern job scheduler for automated periodic sync |
| (optional) rclone binary | Remote backup (auto-downloaded by app) |

## Files

```
rime-sync-scheduler/
├── app/src/main/java/org/fcitx/rimesync/
│   └── RimeSyncHook.kt          # LSPosed hook: BroadcastReceiver + sync trigger
├── app/src/main/AndroidManifest.xml   # xposedmodule metadata
├── app/src/main/assets/xposed_init   # declares hook entry class
├── app/src/main/res/values/arrays.xml # scope: fcitx5-android only
├── module.prop                  # KernelSU/APatch module descriptor
├── scripts/
│   ├── backup.sh                # Unified sync script (local + cloud)
│   └── setup-suscheduler.sh     # Su Scheduler registration (replaces crond4android)
└── build files (Gradle)
```

## Build

```bash
cd rime-sync-scheduler
./gradlew assembleRelease
# output: app/build/outputs/apk/release/app-release-unsigned.apk
```

## Install

1. Install the APK on device
2. Open LSPosed Manager → Modules → enable "Rime Sync Scheduler"
3. Set scope to `org.fcitx.fcitx5.android` (fcitx5-android)
4. Reboot or force-stop fcitx5-android

## Usage

### Manual trigger

```bash
# From adb shell, Termux, or any root shell:
am broadcast -a org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC
```

Check logcat for results:
```bash
logcat -s RimeSyncReceiver:I RimeSyncScheduler:I
```

### Automated: KernelSU / APatch + Su Scheduler

1. Install [Su Scheduler](https://github.com/rexackermann/su-scheduler) module in KernelSU/APatch Manager
2. Copy scripts to module directory:
   ```bash
   mkdir -p /data/adb/modules/rime-sync-scheduler/scripts
   cp scripts/backup.sh scripts/setup-suscheduler.sh /data/adb/modules/rime-sync-scheduler/scripts/
   ```
3. Configure rclone via the app UI (import rclone.conf, set remote path)
4. Run setup:
   ```bash
   # As root (in KernelSU/APatch context):
   sh /data/adb/modules/rime-sync-scheduler/scripts/setup-suscheduler.sh
   
   # Or dry-run to preview:
   sh /data/adb/modules/rime-sync-scheduler/scripts/setup-suscheduler.sh --dry-run
   ```
5. This registers jobs that:
   - Run on **device boot**
   - Run **4x daily** (00:00, 06:00, 12:00, 18:00 — approx every 6 hours)
   - Each job: broadcast local sync → wait 15s → rclone bisync
   - Jobs have `--notify` flag for Android notifications

Management:
```bash
su-scheduler list              # list all jobs
su-scheduler run <id>          # trigger a job manually
su-scheduler remove <id>       # delete a job
su-scheduler log               # view execution log
```

### Manual sync (without scheduler)

```bash
# Full sync (local + cloud):
sh scripts/backup.sh --full-sync

# Local sync only:
sh scripts/backup.sh --local-only

# Cloud sync only:
sh scripts/backup.sh --cloud-only

# Dry run (preview cloud sync changes):
sh scripts/backup.sh --full-sync --dry-run
```

## Data paths

Paths are dynamically detected by the LSPosed hook (from fcitx5's `installation.yaml`) and written to:
```
/data/data/org.fcitx.rimesync/files/rime_paths.txt
```
The `backup.sh` script reads this file to determine the sync source directory.

| Path | Description |
|---|---|
| `<rime_dir>/` | Rime user data directory (from `installation.yaml`) |
| `<rime_dir>/sync/` | Local sync output (after `sync_user_data()`) |
| `/data/data/org.fcitx.rimesync/files/rclone.conf` | rclone config (managed by app UI) |
| `/data/data/org.fcitx.rimesync/files/rclone_bin/rclone` | Bundled rclone binary (auto-downloaded) |

On most devices the rime data lives under:
```
/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/data/fcitx5/rime/
```

## Technical notes

### Why reflection-heavy

The LSPosed module compiles against Xposed API only, not against fcitx5-android internals. All interactions use Java reflection through the target app's classloader, including:

- `FcitxDaemon.INSTANCE` singleton access
- `FcitxDaemon.connect()` / `disconnect()`
- `FcitxConnection.runImmediately()` — takes a Kotlin suspend lambda; we create one via `java.lang.reflect.Proxy` implementing `kotlin.jvm.functions.Function2`
- `Fcitx$JNI.setFcitxAddonSubConfig(String, String, RawConfig)` — private companion method, accessed via `setAccessible(true)`

### Thread safety

The module calls `runImmediately()` which internally does `runBlocking(realFcitx.lifeCycleScope.coroutineContext)`. This dispatches to the fcitx event loop thread, ensuring thread-safe access to `Fcitx::Instance()`.

### Limitations

- Rime addon must be loaded (fcitx must have been started at least once since boot)
- On first broadcast after app cold start, `FcitxDaemon.connect()` will start fcitx — the StatusAreaEvent with action list arrives asynchronously, but `setAddonSubConfig` doesn't need it
- If you uninstall/reinstall fcitx5-android, re-enable the LSPosed module scope
