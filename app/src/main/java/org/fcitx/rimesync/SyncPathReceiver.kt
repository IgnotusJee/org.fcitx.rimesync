package org.fcitx.rimesync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.io.File

/**
 * Receives sync path data from the hook (inside fcitx5 process).
 * Writes paths for shell scripts, ensures default config on first run.
 */
class SyncPathReceiver : BroadcastReceiver() {

    companion object {
        const val ACTION = "org.fcitx.rimesync.STORE_PATHS"
        const val EXTRA_RIME_DIR = "rime_dir"
        const val EXTRA_SYNC_DIR = "sync_dir"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION) return

        // Ensure default JSON config exists on first launch
        CloudSyncHelper.resolveConfigFile(context)

        val rimeDir = intent.getStringExtra(EXTRA_RIME_DIR) ?: ""
        val syncDir = intent.getStringExtra(EXTRA_SYNC_DIR) ?: ""
        if (rimeDir.isNotEmpty() || syncDir.isNotEmpty()) {
            File(context.filesDir, CloudSyncHelper.PATH_FILE).writeText("$rimeDir\n$syncDir")
        }
    }
}
