package org.fcitx.rimesync.ui

import android.app.AlertDialog
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import org.fcitx.rimesync.CloudSyncHelper
import org.fcitx.rimesync.R
import org.fcitx.rimesync.RimeSyncHook
import java.io.BufferedReader
import java.io.InputStreamReader

class MainActivity : AppCompatActivity() {

    private lateinit var btnLocalSync: Button
    private lateinit var btnCloudSync: Button
    private lateinit var btnImportConfig: Button
    private lateinit var btnSaveConfig: Button
    private lateinit var btnBrowseRemote: Button
    private lateinit var tvStatus: TextView
    private lateinit var tvRemotes: TextView
    private lateinit var tvRimeDir: TextView
    private lateinit var tvSyncDir: TextView
    private lateinit var etRemotePath: EditText
    private lateinit var etConfig: EditText
    private val handler = Handler(Looper.getMainLooper())

    private val pickConfigFile = registerForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri -> uri?.let { readAndDisplayConfig(it) } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        btnLocalSync = findViewById(R.id.btnLocalSync)
        btnCloudSync = findViewById(R.id.btnCloudSync)
        btnImportConfig = findViewById(R.id.btnImportConfig)
        btnSaveConfig = findViewById(R.id.btnSaveConfig)
        btnBrowseRemote = findViewById(R.id.btnBrowseRemote)
        tvStatus = findViewById(R.id.tvStatus)
        tvRemotes = findViewById(R.id.tvRemotes)
        tvRimeDir = findViewById(R.id.tvRimeDir)
        tvSyncDir = findViewById(R.id.tvSyncDir)
        etRemotePath = findViewById(R.id.etRemotePath)
        etConfig = findViewById(R.id.etConfig)

        refreshRimePaths()
        etRemotePath.setText(CloudSyncHelper.getRemoteSyncPath(this))
        val config = CloudSyncHelper.loadConfig(this)
        if (config.isNotBlank()) etConfig.setText(config)
        updateRemotesDisplay()

        btnLocalSync.setOnClickListener { triggerLocalSync() }
        btnCloudSync.setOnClickListener { triggerCloudSync() }
        btnImportConfig.setOnClickListener { openFilePicker() }
        btnSaveConfig.setOnClickListener { saveConfig() }
        btnBrowseRemote.setOnClickListener { browseRemoteDir() }
    }

    override fun onResume() {
        super.onResume()
        refreshRimePaths()
    }

    private fun refreshRimePaths() {
        val paths = CloudSyncHelper.getRimePaths(this)
        tvRimeDir.text = paths.rimeDir
        tvSyncDir.text = paths.syncDir
    }

    private fun openFilePicker() {
        try { pickConfigFile.launch(arrayOf("*/*")) }
        catch (e: Exception) { setStatus("Error: ${e.message}", R.color.status_err) }
    }

    private fun readAndDisplayConfig(uri: Uri) {
        Thread {
            try {
                val content = contentResolver.openInputStream(uri)?.use { s ->
                    BufferedReader(InputStreamReader(s)).readText()
                } ?: ""
                handler.post {
                    if (content.isBlank()) setStatus("File is empty", R.color.status_pending)
                    else { etConfig.setText(content); saveConfig(); setStatus("Imported ✓", R.color.status_ok) }
                }
            } catch (e: Exception) {
                handler.post { setStatus("Import failed: ${e.message}", R.color.status_err) }
            }
        }.start()
    }

    private fun saveConfig() {
        val c = etConfig.text.toString()
        if (c.isBlank()) { setStatus("Config is empty", R.color.status_pending); return }
        CloudSyncHelper.saveConfig(this, c)
        updateRemotesDisplay()
        setStatus("Config saved ✓", R.color.status_ok)
    }

    private fun updateRemotesDisplay() {
        val remotes = CloudSyncHelper.parseRemotes(this)
        tvRemotes.text = if (remotes.isEmpty()) "No remotes" else "Remotes: ${remotes.joinToString(", ")}"
    }

    private fun browseRemoteDir() {
        val remotes = CloudSyncHelper.parseRemotes(this)
        if (remotes.isEmpty()) { setStatus("No remotes", R.color.status_err); return }
        setStatus("Browsing...", R.color.status_pending)
        setButtonsEnabled(false)
        Thread {
            val dirs = CloudSyncHelper.browseRemote(this, remotes.first(),
                etRemotePath.text.toString().trim().trimEnd('/')) { m ->
                handler.post { setStatus(m, R.color.status_pending) }
            }
            handler.post {
                setButtonsEnabled(true)
                if (dirs.isEmpty()) setStatus("No subdirs", R.color.status_pending)
                else showRemoteDirDialog(remotes.first(), etRemotePath.text.toString().trim().trimEnd('/'), dirs)
            }
        }.start()
    }

    private fun showRemoteDirDialog(remote: String, parent: String, dirs: List<String>) {
        AlertDialog.Builder(this)
            .setTitle("$remote:$parent")
            .setItems((listOf("[Current dir]") + dirs).toTypedArray()) { _, which ->
                if (which == 0) setStatus("Selected: $remote:$parent", R.color.status_ok)
                else {
                    val sel = dirs[which - 1]
                    val new = if (parent.isEmpty()) sel else "$parent/$sel"
                    etRemotePath.setText("$new/")
                    CloudSyncHelper.setRemoteSyncPath(this, "$new/")
                    setStatus("Selected: $remote:$new/", R.color.status_ok)
                }
            }.setNegativeButton("Cancel", null).show()
    }

    private fun triggerLocalSync() {
        setStatus("Local sync...", R.color.status_pending)
        setButtonsEnabled(false)
        sendBroadcast(Intent(RimeSyncHook.ACTION_TRIGGER_SYNC).apply {
            setPackage(RimeSyncHook.PACKAGE_NAME); addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
        })
        handler.postDelayed({ setStatus("Local sync triggered ✓", R.color.status_ok); setButtonsEnabled(true) }, 1000)
    }

    private fun triggerCloudSync() {
        CloudSyncHelper.setRemoteSyncPath(this, etRemotePath.text.toString().trim())
        val ctx = this
        setStatus("Cloud sync...", R.color.status_pending); setButtonsEnabled(false)
        Thread {
            var ok = false
            try { CloudSyncHelper.runSync(ctx) { m -> handler.post { setStatus(m,
                when { m.contains("✓") || m.contains("done") -> R.color.status_ok
                    m.contains("failed") || m.contains("Error") -> R.color.status_err
                    else -> R.color.status_pending }) } }.also { ok = it }
            } catch (e: Exception) { handler.post { setStatus("Error: ${e.message}", R.color.status_err) } }
            handler.post {
                if (!ok && !tvStatus.text.contains("✓") && !tvStatus.text.contains("failed"))
                    setStatus("Cloud sync failed ✗", R.color.status_err)
                setButtonsEnabled(true)
            }
        }.start()
    }

    private fun setStatus(text: String, cid: Int) { tvStatus.text = text; tvStatus.setTextColor(getColor(cid)) }
    private fun setButtonsEnabled(e: Boolean) {
        listOf(btnLocalSync, btnCloudSync, btnImportConfig, btnSaveConfig, btnBrowseRemote)
            .forEach { it.isEnabled = e; it.alpha = if (e) 1.0f else 0.5f }
    }
}
