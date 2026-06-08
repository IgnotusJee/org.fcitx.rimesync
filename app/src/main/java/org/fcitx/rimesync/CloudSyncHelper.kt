package org.fcitx.rimesync

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.File

/**
 * Shared constants and path/config utilities.
 *
 * The LSPosed hook (RimeSyncHook) reads fcitx5's installation.yaml and broadcasts
 * rime/sync dirs to SyncPathReceiver, which writes them to [PATH_FILE].
 * Shell scripts then consume [PATH_FILE] and the JSON config to perform sync.
 */
object CloudSyncHelper {

    private const val TAG = "CloudSyncHelper"

    /** File that SyncPathReceiver writes rime + sync paths into. */
    const val PATH_FILE = "rime_paths.txt"

    /** JSON config file name (resolved from well-known locations). */
    const val CONFIG_FILE = "rime_sync.json"

    // ── Config file resolution ──────────────────────────────────────────

    /**
     * Returns the config file (app-private dir, editable via root).
     * Default config is auto-created if missing.
     */
    fun resolveConfigFile(context: Context): File {
        val local = File(context.filesDir, CONFIG_FILE)
        if (!local.exists()) {
            try {
                local.writeText(defaultConfig(context))
                Log.i(TAG, "Wrote default config to ${local.absolutePath}")
            } catch (e: Exception) {
                Log.w(TAG, "Cannot write default config: ${e.message}")
            }
        }
        return local
    }

    // ── JSON config model ───────────────────────────────────────────────

    data class SyncConfig(
        val remotePath: String,
        val rcloneConfig: String,
        val deviceName: String,
    )

    fun loadSyncConfig(context: Context): SyncConfig {
        val file = resolveConfigFile(context)
        return try {
            val json = JSONObject(file.readText())
            SyncConfig(
                remotePath = json.optString("remote_path", "rime/"),
                rcloneConfig = json.optString("rclone_config", context.filesDir.absolutePath + "/rclone.conf"),
                deviceName = json.optString("device_name", ""),
            )
        } catch (e: Exception) {
            Log.w(TAG, "Failed to parse config, using defaults: ${e.message}")
            SyncConfig(remotePath = "rime/", rcloneConfig = context.filesDir.absolutePath + "/rclone.conf", deviceName = "")
        }
    }

    // ── Rime paths (written by SyncPathReceiver) ────────────────────────

    data class RimePaths(val rimeDir: String, val syncDir: String)

    fun getRimePaths(context: Context): RimePaths {
        val file = File(context.filesDir, PATH_FILE)
        if (file.exists()) {
            try {
                val lines = file.readLines()
                val rime = lines.getOrElse(0) { "" }
                val sync = lines.getOrElse(1) { "" }
                if (rime.isNotEmpty() || sync.isNotEmpty()) {
                    Log.i(TAG, "Paths: rime=$rime sync=$sync")
                    return RimePaths(rime, sync)
                }
            } catch (e: Exception) {
                Log.w(TAG, "Read paths failed: ${e.message}")
            }
        }
        return RimePaths("", "")
    }

    // ── rclone.conf helpers (for shell scripts / external consumers) ────

    fun getRcloneConfigPath(context: Context): String =
        loadSyncConfig(context).rcloneConfig

    fun loadRcloneConfig(context: Context): String {
        val path = getRcloneConfigPath(context)
        val f = File(path)
        return if (f.exists() && f.canRead()) f.readText() else ""
    }

    fun parseRemotes(context: Context): List<String> {
        val config = loadRcloneConfig(context)
        if (config.isBlank()) return emptyList()
        return Regex("""^\[(\w+)]""", RegexOption.MULTILINE)
            .findAll(config).map { it.groupValues[1] }.filter { it.isNotEmpty() }.toList()
    }

    // ── Default config ──────────────────────────────────────────────────

    private fun defaultConfig(context: Context): String = """
{
  "remote_path": "rime/",
  "rclone_config": "${context.filesDir.absolutePath}/rclone.conf",
  "device_name": ""
}
    """.trimIndent() + "\n"
}
