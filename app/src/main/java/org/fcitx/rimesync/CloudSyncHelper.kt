package org.fcitx.rimesync

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Paths and config utilities.
 *
 * All sync data lives under fcitx5's external files dir:
 *   /storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/rime_sync/
 *
 * Files are written directly by the LSPosed hook (runs in fcitx5 process)
 * and consumed by shell scripts via root access. No cross-process IPC needed.
 */
object CloudSyncHelper {

    private const val TAG = "CloudSyncHelper"

    const val PATH_FILE = "rime_paths.txt"
    const val CONFIG_FILE = "rime_sync.json"

    /** fcitx5's external files dir, resolved at runtime. */
    private const val FCITX5_FILES = "/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files"

    /** Directory where hook writes and shell scripts read sync data. */
    val SYNC_DATA_DIR = "$FCITX5_FILES/rime_sync"

    // ── Rime paths (written by hook) ────────────────────────────────────

    data class RimePaths(val rimeDir: String, val syncDir: String)

    fun getRimePaths(): RimePaths {
        val file = File(SYNC_DATA_DIR, PATH_FILE)
        if (file.exists()) {
            try {
                val lines = file.readLines()
                val rime = lines.getOrElse(0) { "" }
                val sync = lines.getOrElse(1) { "" }
                if (rime.isNotEmpty() || sync.isNotEmpty()) {
                    return RimePaths(rime, sync)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Read paths failed: ${e.message}")
            }
        }
        return RimePaths("", "")
    }

    // ── JSON config (read by shell scripts) ────────────────────────────

    data class SyncConfig(
        val remotePath: String,
        val rcloneConfig: String,
        val deviceName: String,
    )

    fun loadSyncConfig(): SyncConfig {
        val file = File(SYNC_DATA_DIR, CONFIG_FILE)
        return try {
            val json = JSONObject(file.readText())
            SyncConfig(
                remotePath = json.optString("remote_path", "rime/"),
                rcloneConfig = json.optString("rclone_config", "$SYNC_DATA_DIR/rclone.conf"),
                deviceName = json.optString("device_name", ""),
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse config: ${e.message}")
            SyncConfig("rime/", "$SYNC_DATA_DIR/rclone.conf", "")
        }
    }

    // ── rclone.conf helpers ────────────────────────────────────────────

    fun getRcloneConfigPath(): String = loadSyncConfig().rcloneConfig

    fun loadRcloneConfig(): String {
        val f = File(getRcloneConfigPath())
        return if (f.exists() && f.canRead()) f.readText() else ""
    }

    fun parseRemotes(): List<String> {
        val config = loadRcloneConfig()
        if (config.isBlank()) return emptyList()
        return Regex("""^\[(\w+)]""", RegexOption.MULTILINE)
            .findAll(config).map { it.groupValues[1] }.filter { it.isNotEmpty() }.toList()
    }
}
