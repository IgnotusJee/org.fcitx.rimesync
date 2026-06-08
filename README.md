# Rime Sync Scheduler

LSPosed 模块，为 fcitx5-android 提供 Rime 本地 + 云端定时同步。

## 工作原理

```
fcitx5 启动
  └─ LSPosed hook 注入
       ├─ 读取 installation.yaml → 写入 rime_paths.txt + rime_sync.json
       └─ 注册 TRIGGER_RIME_SYNC 广播接收器

su-scheduler 定时触发 (每天 20:00)
  └─ backup.sh
       ├─ 1. 本地同步 (广播触发 Rime sync)
       ├─ 2. 上传本设备数据 (rclone sync → 远程)
       ├─ 3. 下载其他设备数据 (rclone sync ← 远程)
       └─ 4. 最终本地同步 (让 fcitx5 加载新数据)
```

## 前提条件

- Android 8.0+ (arm64)
- Root (KernelSU / APatch / Magisk)
- [LSPosed](https://github.com/JingMatrix/LSPosed) 框架
- [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) 输入法
- [rclone](https://rclone.org/) 二进制文件
- [Su Scheduler](https://github.com/rexackermann/su-scheduler) 模块（定时任务）

## 安装

### 1. 编译

```sh
./gradlew assembleDebug
# 输出: app/build/outputs/apk/debug/app-debug.apk
```

### 2. 安装模块

在 LSPosed 管理器中启用本模块，作用域选择 `fcitx5-android`。

### 3. 准备 rclone

将 arm64 版 rclone 二进制放入：

```
/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/rclone_bin/rclone
```

并创建 rclone 配置（同目录 `rclone.conf`）：
```ini
[myremote]
type = s3
provider = Other
endpoint = https://your-s3.example.com
access_key_id = ...
secret_access_key = ...
```

### 4. 配置

fcitx5 启动后，hook 自动在以下目录生成配置文件：
```
/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/
├── rime_paths.txt    # Rime/sync 目录路径（自动）
├── rime_sync.json    # 同步配置（首次自动生成默认值）
└── rclone.conf       # rclone 远端配置（需手动放入）
```

`rime_sync.json` 示例：
```json
{
  "remote_path": "Rime/",
  "rclone_config": "/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/rclone.conf",
  "device_name": ""
}
```

| 字段 | 说明 |
|---|---|
| `remote_path` | 远程存储上的子路径 |
| `rclone_config` | rclone 配置文件路径 |
| `device_name` | 设备名（留空则从 `installation.yaml` 自动提取） |

### 5. 注册定时任务

```sh
# Push 脚本
adb push scripts/backup.sh scripts/setup-suscheduler.sh /data/local/tmp/

# 安装 Su Scheduler 后，运行 setup（默认每晚 20:00）
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh"

# 自定义时间
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh 06:00"
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh 2230"

# 跳过 dry-run 或 test
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh --no-dry-run --no-test"
```

## 手动同步

```sh
# 完整同步 (本地 → 云端上传 → 云端下载 → 本地加载)
su -c "sh /sdcard/Scripts/rime_backup.sh --full-sync"

# 仅云端同步
su -c "sh /sdcard/Scripts/rime_backup.sh --cloud-only"

# 仅本地同步
su -c "sh /sdcard/Scripts/rime_backup.sh --local-only"

# 预览模式 (不实际修改)
su -c "sh /sdcard/Scripts/rime_backup.sh --full-sync --dry-run"
```

或通过广播触发本地同步：
```sh
am broadcast -a org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC -p org.fcitx.fcitx5.android --receiver-foreground
```

## 管理定时任务

```sh
su -c su-scheduler list          # 查看任务
su -c su-scheduler log           # 执行日志
su -c su-scheduler remove <id>   # 删除任务
```

## 项目结构

```
rime-sync-scheduler/
├── app/src/main/java/org/fcitx/rimesync/
│   ├── RimeSyncHook.kt        # LSPosed hook (注入 fcitx5 进程)
│   └── CloudSyncHelper.kt     # 路径/配置读取工具
├── scripts/
│   ├── backup.sh              # 同步脚本 (本地 + 云端)
│   └── setup-suscheduler.sh   # Su Scheduler 安装脚本
├── rime_sync.json             # 配置模板
└── module.prop                # 模块描述
```

## License

MIT
