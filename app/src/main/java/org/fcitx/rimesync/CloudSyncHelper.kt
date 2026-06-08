package org.fcitx.rimesync

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import android.util.Log
import java.io.*
import java.util.zip.ZipInputStream

/**
 * Self-contained rclone manager + rime path resolver.
 * Uses broadcast IPC to receive paths from the LSPosed hook.
 */
object CloudSyncHelper {

    private const val TAG = "CloudSyncHelper"
    private const val RCLONE_VERSION = "1.69.0"
    private const val RCLONE_ZIP =
        "https://downloads.rclone.org/v$RCLONE_VERSION/rclone-v$RCLONE_VERSION-linux-arm64.zip"

    private const val PREF_NAME = "rclone_prefs"
    private const val PREF_BINARY_READY = "binary_ready"
    private const val PREF_REMOTE_PATH = "remote_path"
    const val PATH_FILE = "rime_paths.txt"

    fun ensureRclone(context: Context, onProgress: ((String) -> Unit)? = null): File? {
        val binDir = File(context.filesDir, "rclone_bin"); binDir.mkdirs()
        val bin = File(binDir, "rclone")
        if (bin.exists() && bin.canExecute() && getPrefs(context).getBoolean(PREF_BINARY_READY, false)) return bin
        return try {
            onProgress?.invoke("Downloading rclone v$RCLONE_VERSION...")
            downloadAndExtract(context, bin, onProgress)
            bin.setExecutable(true)
            getPrefs(context).edit().putBoolean(PREF_BINARY_READY, true).apply()
            Log.i(TAG, "rclone installed: ${bin.absolutePath} (${bin.length()} bytes)")
            bin
        } catch (e: Exception) {
            Log.e(TAG, "Failed to install rclone", e)
            onProgress?.invoke("rclone install failed: ${e.message}")
            null
        }
    }

    private fun downloadAndExtract(context: Context, dest: File, onProgress: ((String) -> Unit)?) {
        val zipFile = File(context.cacheDir, "rclone.zip")
        downloadFile(RCLONE_ZIP, zipFile) { pct -> onProgress?.invoke("Downloading rclone... $pct%") }
        onProgress?.invoke("Extracting...")
        ZipInputStream(BufferedInputStream(FileInputStream(zipFile))).use { zis ->
            var e = zis.nextEntry
            while (e != null) {
                if (e.name.removePrefix("./").endsWith("/rclone") || e.name == "rclone") {
                    FileOutputStream(dest).use { zis.copyTo(it) }; break
                }
                e = zis.nextEntry
            }
        }
        zipFile.delete()
    }

    private fun downloadFile(urlStr: String, dest: File, onProgress: ((Int) -> Unit)?) {
        val conn = (java.net.URL(urlStr).openConnection() as java.net.HttpURLConnection).apply {
            connectTimeout = 30000; readTimeout = 180000
            instanceFollowRedirects = true; setRequestProperty("User-Agent", "RimeSync/1.0")
        }
        val total = conn.contentLengthLong; var d = 0L; var lp = -1
        conn.inputStream.use { input ->
            FileOutputStream(dest).use { output ->
                val buf = ByteArray(8192); var b = input.read(buf)
                while (b != -1) { output.write(buf, 0, b); d += b
                    if (total > 0) { val p = (d * 100 / total).toInt(); if (p != lp) { lp = p; onProgress?.invoke(p) } }
                    b = input.read(buf) }
            }
        }
        conn.disconnect()
    }

    // ── Rime paths (read from broadcast-written file) ──────────────────

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
            } catch (e: Exception) { Log.w(TAG, "Read paths failed: ${e.message}") }
        }
        return RimePaths("(launch fcitx5 once)", "(launch fcitx5 once)")
    }

    // ── Config management ─────────────────────────────────────────────

    fun getConfigFile(context: Context): File = File(context.filesDir, "rclone.conf")

    fun loadConfig(context: Context): String {
        val ext = File("/sdcard/rclone.conf")
        if (ext.exists() && ext.canRead()) {
            val c = ext.readText(); getConfigFile(context).writeText(c)
            Log.i(TAG, "Loaded rclone.conf from /sdcard/")
            return c
        }
        val i = getConfigFile(context)
        return if (i.exists()) i.readText() else ""
    }

    fun saveConfig(context: Context, content: String) {
        getConfigFile(context).writeText(content)
        Log.i(TAG, "Saved rclone.conf")
    }

    fun parseRemotes(context: Context): List<String> {
        val config = loadConfig(context)
        if (config.isBlank()) return emptyList()
        return Regex("""^\[(\w+)]""", RegexOption.MULTILINE)
            .findAll(config).map { it.groupValues[1] }.filter { it.isNotEmpty() }.toList()
    }

    // ── Remote path ────────────────────────────────────────────────────

    fun getRemoteSyncPath(context: Context): String =
        getPrefs(context).getString(PREF_REMOTE_PATH, "rime/") ?: "rime/"

    fun setRemoteSyncPath(context: Context, path: String) {
        getPrefs(context).edit().putString(PREF_REMOTE_PATH, path).apply()
    }

    // ── Remote browse ──────────────────────────────────────────────────

    fun browseRemote(context: Context, remote: String, path: String = "",
                     onProgress: ((String) -> Unit)? = null): List<String> {
        val bin = ensureRclone(context, onProgress) ?: return emptyList()
        val remotePath = if (path.isEmpty()) "$remote:" else "$remote:$path"
        val cmd = arrayOf(bin.absolutePath, "lsd", remotePath,
            "--config", getConfigFile(context).absolutePath, "--max-depth", "1",
            "--no-check-certificate", "--timeout", "30s")
        return try {
            val p = ProcessBuilder(*cmd).redirectErrorStream(true).start()
            val out = p.inputStream.bufferedReader().readText()
            val ec = p.waitFor(); p.destroy()
            if (ec != 0) {
                onProgress?.invoke("Browse failed: ${out.takeLast(200)}")
                return emptyList()
            }
            out.lines().filter { it.isNotBlank() && !it.startsWith("Failed") }
                .mapNotNull { it.trim().split("\t").lastOrNull()?.trim()
                    ?: it.trim().split("\\s+".toRegex()).lastOrNull() }
                .filter { it.isNotEmpty() }
        } catch (e: Exception) {
            Log.e(TAG, "Browse failed", e)
            onProgress?.invoke("Browse error: ${e.message}")
            emptyList()
        }
    }

    // ── Sync execution ────────────────────────────────────────────────

    fun runSync(context: Context, onProgress: ((String) -> Unit)? = null): Boolean {
        val bin = ensureRclone(context, onProgress) ?: return false
        val paths = getRimePaths(context)
        val localDir = paths.syncDir.ifEmpty { paths.rimeDir }
        if (localDir.isEmpty() || localDir.startsWith("(launch")) {
            onProgress?.invoke("Launch fcitx5 once to detect paths"); return false
        }
        val configFile = getConfigFile(context)
        if (!configFile.exists() || configFile.readText().isBlank()) {
            onProgress?.invoke("Import rclone.conf first"); return false
        }
        val remotes = parseRemotes(context)
        if (remotes.isEmpty()) { onProgress?.invoke("No remotes in rclone.conf"); return false }
        val remote = remotes.first()
        val remoteFull = "$remote:${getRemoteSyncPath(context)}"
        val cacheDir = File(context.cacheDir, "rclone_cache").also { it.mkdirs() }
        val cmd = arrayOf(bin.absolutePath, "bisync", localDir, remoteFull,
            "--config", configFile.absolutePath, "--create-empty-src-dirs",
            "--compare", "size,modtime,checksum",
            "--cache-dir", cacheDir.absolutePath, "--resync",
            "--no-check-certificate", "--timeout", "30s",
            "--log-file", File(context.filesDir, "rclone.log").absolutePath, "--log-level", "INFO")

        val env = ProcessBuilder(*cmd).redirectErrorStream(true)
        env.environment()["HOME"] = context.filesDir.absolutePath
        env.environment()["TMPDIR"] = cacheDir.absolutePath
        onProgress?.invoke("$localDir ↔ $remoteFull")
        return try {
            val p = env.start()
            val out = p.inputStream.bufferedReader().readText()
            val ec = p.waitFor(); p.destroy()
            if (ec == 0 || ec == 2) {
                onProgress?.invoke("Cloud sync done ✓ ($remote)")
                true
            } else {
                onProgress?.invoke("Sync failed (exit $ec): ${out.takeLast(300)}")
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "rclone failed", e)
            onProgress?.invoke("Error: ${e.message}")
            false
        }
    }

    private fun getPrefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
}
