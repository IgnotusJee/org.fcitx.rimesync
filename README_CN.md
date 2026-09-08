# Rime Sync Scheduler

[English](README.md)

为 fcitx5-android 提供 Rime 本地 + 云端自动同步调度的 LSPosed 模块。

## 工作原理

```
fcitx5 启动
  └─ LSPosed hook 注入
       ├─ 读取 installation.yaml → 写入 rime_paths.txt + rime_sync.json
       └─ 注册 TRIGGER_RIME_SYNC 广播接收器

su-scheduler 定时触发（每天 08:00）
  └─ backup.sh
       ├─ 1. 停止 fcitx5，删除残留 .temp.userdb，再无界面启动
       ├─ 2. 本地同步（广播触发 Rime sync）
       ├─ 3. 上传本设备（rclone sync → 远程）
       ├─ 4. 下载其他设备（rclone sync ← 远程）
       ├─ 5. 再次清理临时库并进行最终本地同步
       └─ 6. 通知成功/失败、上传量、下载量和耗时
```

## 前提条件

- Android 8.0+ (arm64)
- Root (KernelSU / APatch / Magisk)
- [LSPosed](https://github.com/JingMatrix/LSPosed) 框架
- [fcitx5-android](https://github.com/fcitx5-android/fcitx5-android) 输入法
- [rclone](https://rclone.org/) arm64 二进制
- [Su Scheduler](https://github.com/rexackermann/su-scheduler) 模块

## 安装

### 1. 编译

```sh
./gradlew assembleDebug
# 输出: app/build/outputs/apk/debug/app-debug.apk
```

### 2. 启用模块

在 LSPosed 管理器中启用本模块，作用域选择 `fcitx5-android`。

### 3. 准备 rclone

推荐在 Termux 中安装 Android 版 rclone：

```sh
pkg install rclone
```

脚本优先直接调用 `/data/data/com.termux/files/usr/bin/rclone`，使用 Android
系统 DNS 解析器，避免依赖 Surfing 等代理模块的 DNS 转发。定时任务由 root
执行，无需打开 Termux 界面；请保留 Termux 及其安装环境，并通过 `pkg upgrade rclone`
更新。日志会记录实际使用的二进制路径和版本。

未安装 Termux 版时，脚本会依次查找 PATH、以下路径及支持的模块路径：

```
/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/rclone_bin/rclone
```

通用 Linux 静态版可能因 Android 缺少 `/etc/resolv.conf` 而查询本机 `:53`，
在代理关闭时解析失败；优先使用上述 Termux 版。

在 `rime_sync/rclone.conf` 创建远端配置文件（不是 `rclone_bin` 子目录）：
```ini
[myremote]
type = s3
provider = Other
endpoint = https://your-s3.example.com
access_key_id = ...
secret_access_key = ...
```

### 4. 配置

fcitx5 启动后，hook 会自动在以下目录生成配置文件：

```
/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/
├── rime_paths.txt    # Rime 及同步目录路径（自动生成）
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
| `device_name` | 设备名（留空则从 `installation.yaml` 自动提取 `installation_id`） |

### 5. 注册定时任务

```sh
# Push 脚本到设备
adb push scripts/backup.sh scripts/setup-suscheduler.sh /data/local/tmp/

# 安装 Su Scheduler 模块后，运行 setup（默认每天早上 08:00）
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh"

# 自定义时间
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh 06:00"
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh 2230"

# 跳过 dry-run 或 test
adb shell su -c "sh /data/local/tmp/setup-suscheduler.sh --no-dry-run --no-test"
```

## 手动同步

脚本会阻止多个同步任务重叠运行。每次 Rime 本地同步前，只有在确认 fcitx5
进程已经退出后，才会删除精确路径下的临时数据库 `.temp.userdb`（包括其中的
`LOCK`），不会删除正式用户词库。

```sh
# 完整同步（本地 → 上传 → 下载 → 本地加载）
su -c "sh /sdcard/Scripts/rime_backup.sh --full-sync"

# 仅云端同步
su -c "sh /sdcard/Scripts/rime_backup.sh --cloud-only"

# 仅本地同步
su -c "sh /sdcard/Scripts/rime_backup.sh --local-only"

# 预览模式（不实际修改文件）
su -c "sh /sdcard/Scripts/rime_backup.sh --full-sync --dry-run"
```

或通过广播直接触发本地同步：
```sh
am broadcast -a org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC -p org.fcitx.fcitx5.android --receiver-foreground
```

## fcitx5-android 已知问题

fcitx5-android 的 Rime 用户数据同步偶尔会遗留临时 LevelDB 数据库
`.temp.userdb`，其 `LOCK` 仍被旧进程持有或未被正确清理。再次同步时可能显示
一个错误，并在日志中出现类似信息：

```text
Error opening db '.temp': ... LOCK already held by process
```

这会导致部分用户词库快照合并失败。上游相关报告见
[fcitx5-android #825](https://github.com/fcitx5-android/fcitx5-android/issues/825)。

本项目采用以下规避方案：每次本地同步前强制停止 fcitx5，确认进程完全退出，
删除整个 `.temp.userdb`，随后无界面启动 fcitx5 并触发同步。完整同步在上传前和
下载后合并前都会执行这一流程。不要在 fcitx5 仍运行时单独删除 `LOCK`；这可能
破坏正在使用的 LevelDB 临时数据库。安排在不使用输入法的时段执行，可避免
停止进程造成的短暂输入中断。

脚本会在每次停止前保存当前用户的默认输入法。如果原来选择的是 fcitx5，
重启后会通过 `ime set` 恢复并核验；异常退出时也会尝试恢复。原来使用其他
输入法时不会主动切换到 fcitx5。恢复失败会记录错误并报告同步失败。

## 管理定时任务

```sh
su -c su-scheduler list          # 查看任务列表
su -c su-scheduler log           # 查看执行日志
su -c su-scheduler remove <id>   # 删除任务
```

## 项目结构

```
rime-sync-scheduler/
├── app/src/main/java/org/fcitx/rimesync/
│   ├── RimeSyncHook.kt        # LSPosed hook（注入 fcitx5 进程）
│   └── CloudSyncHelper.kt     # 路径/配置读取工具
├── scripts/
│   ├── backup.sh              # 同步脚本（本地 + 云端）
│   └── setup-suscheduler.sh   # Su Scheduler 安装脚本
├── rime_sync.json             # 配置模板
└── module.prop                # 模块描述文件
```

## 许可证

MIT
