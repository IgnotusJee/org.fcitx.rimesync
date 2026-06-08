package org.fcitx.rimesync

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.util.Log
import io.github.libxposed.api.XposedModule
import io.github.libxposed.api.XposedModuleInterface.ModuleLoadedParam
import io.github.libxposed.api.XposedModuleInterface.PackageReadyParam
import java.io.File
import java.lang.reflect.Method
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * LSPosed module: injects a BroadcastReceiver into fcitx5-android that
 * triggers rime local sync (api_->sync_user_data()) on demand via
 * setAddonSubConfig("rime", "sync") — works WITHOUT active input context.
 *
 * External trigger:
 *   am broadcast -a org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC
 */
class RimeSyncHook : XposedModule() {

    companion object {
        const val TAG = "RimeSyncScheduler"
        const val PACKAGE_NAME = "org.fcitx.fcitx5.android"
        const val ACTION_TRIGGER_SYNC = "org.fcitx.fcitx5.android.action.TRIGGER_RIME_SYNC"
        const val CONNECTION_NAME = "rime-sync-scheduler"

        /** Captured daemon singleton — set by hook on FcitxDaemon.connect */
        @Volatile
        var daemonInstance: Any? = null
    }

    override fun onModuleLoaded(param: ModuleLoadedParam) {
        Log.i(TAG, "Module loaded in process: ${param.processName}")
    }

    override fun onPackageReady(param: PackageReadyParam) {
        if (param.packageName != PACKAGE_NAME) return
        if (!param.isFirstPackage) return

        Log.i(TAG, "Loading hooks into $PACKAGE_NAME")
        val classLoader = param.classLoader

        // ── Hook 1: Capture FcitxDaemon singleton via connect() ──
        try {
            val daemonClass = classLoader.loadClass(
                "org.fcitx.fcitx5.android.daemon.FcitxDaemon"
            )
            val connectMethod = daemonClass.getDeclaredMethod("connect", String::class.java)

            hook(connectMethod).intercept { chain ->
                // Only capture non-null thisObject (R8-staticized calls have null this)
                if (chain.thisObject != null) {
                    daemonInstance = chain.thisObject
                    Log.d(TAG, "Captured FcitxDaemon singleton from connect()")
                }
                chain.proceed()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to hook FcitxDaemon.connect", e)
        }

        // Also capture via getRealFcitx as secondary path
        try {
            val daemonClass = classLoader.loadClass(
                "org.fcitx.fcitx5.android.daemon.FcitxDaemon"
            )
            val getRealFcitxMethod = daemonClass.getDeclaredMethod("getRealFcitx")

            hook(getRealFcitxMethod).intercept { chain ->
                if (daemonInstance == null && chain.thisObject != null) {
                    daemonInstance = chain.thisObject
                    Log.d(TAG, "Captured FcitxDaemon singleton from getRealFcitx()")
                }
                chain.proceed()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to hook FcitxDaemon.getRealFcitx", e)
        }

        // ── Hook 2: Application.onCreate → register BroadcastReceiver ──
        try {
            val appClass = classLoader.loadClass(
                "org.fcitx.fcitx5.android.FcitxApplication"
            )
            val onCreateMethod = appClass.getDeclaredMethod("onCreate")

            hook(onCreateMethod).intercept { chain ->
                val result = chain.proceed()

                val app = chain.thisObject as? Context ?: return@intercept result
                Log.i(TAG, "Registering sync BroadcastReceiver")

                val receiver = RimeSyncReceiver(classLoader)
                app.registerReceiver(
                    receiver,
                    IntentFilter(ACTION_TRIGGER_SYNC),
                    Context.RECEIVER_EXPORTED
                )

                exportSyncDirFromRimeConfig(app)

                result
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to install Application.onCreate hook", e)
        }
    }

    /**
     * Writes rime_paths.txt and ensures default rime_sync.json exist
     * under fcitx5's own external files dir — no cross-process broadcast needed.
     * Shell scripts read these via root.
     */
    private fun exportSyncDirFromRimeConfig(appContext: Context) {
        try {
            // fcitx5's external files dir (readable by shell scripts via root)
            val syncDataDir = java.io.File(
                appContext.getExternalFilesDir(null)?.absolutePath ?: return,
                "rime_sync"
            )
            syncDataDir.mkdirs()

            // Locate rime installation.yaml
            val rimeDirs = listOf(
                "/data/data/org.fcitx.fcitx5.android/files/data/rime",
                "/sdcard/Android/data/org.fcitx.fcitx5.android/files/data/rime",
                "/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/data/rime",
            )
            for (dir in rimeDirs) {
                val yaml = java.io.File(dir, "installation.yaml")
                if (yaml.exists()) {
                    val content = yaml.readText()
                    val pattern = Regex("""sync_dir:\s*['"](.+?)['"]""")
                    val syncDir = pattern.find(content)?.groupValues?.get(1) ?: continue
                    val expanded = if (syncDir.startsWith("~/")) syncDir.replaceFirst("~", "/sdcard") else syncDir

                    // Write paths file
                    java.io.File(syncDataDir, CloudSyncHelper.PATH_FILE)
                        .writeText("$dir\n$expanded")
                    Log.i(TAG, "Wrote paths: rime=$dir sync=$expanded to $syncDataDir")

                    // Ensure default JSON config exists
                    val configFile = java.io.File(syncDataDir, CloudSyncHelper.CONFIG_FILE)
                    if (!configFile.exists()) {
                        val defaultJson = """
{
  "remote_path": "rime/",
  "rclone_config": "${syncDataDir.absolutePath}/rclone.conf",
  "device_name": ""
}
                        """.trimIndent() + "\n"
                        configFile.writeText(defaultJson)
                        Log.i(TAG, "Wrote default config to ${configFile.absolutePath}")
                    }
                    return
                }
            }
            Log.w(TAG, "installation.yaml not found")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to export sync dir", e)
        }
    }
}

/**
 * BroadcastReceiver that triggers rime sync via FcitxConnection.runImmediately.
 * This path does NOT require an active InputContext — works in background.
 */
class RimeSyncReceiver(private val classLoader: ClassLoader) : BroadcastReceiver() {

    companion object {
        private const val TAG = "RimeSyncReceiver"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (intent?.action != RimeSyncHook.ACTION_TRIGGER_SYNC) return

        Log.i(TAG, "Received sync trigger broadcast")

        Thread {
            try {
                triggerRimeSync()
            } catch (e: Exception) {
                Log.e(TAG, "Sync failed", e)
            }
        }.start()
    }

    // ── Core sync logic ──────────────────────────────────────────────

    private fun triggerRimeSync() {
        val daemonClass = classLoader.loadClass(
            "org.fcitx.fcitx5.android.daemon.FcitxDaemon"
        )

        // 1. Connect to fcitx
        val connection = connectToFcitx(daemonClass) ?: return
        Log.d(TAG, "Fcitx connection established")

        // 2. Try to get Fcitx instance (static → R8, or via captured singleton)
        val fcitx = getFcitxInstance(daemonClass)

        // 3. Trigger sync via runImmediately
        triggerSyncOnFcitxThread(connection, daemonClass, fcitx)

        // 4. Disconnect cleanly
        disconnectFromFcitx(daemonClass)
    }

    /** Get Fcitx instance: try R8-static call first, then hook-captured singleton */
    private fun getFcitxInstance(daemonClass: Class<*>): Any? {
        val method = daemonClass.getDeclaredMethod("getRealFcitx")
        method.isAccessible = true

        // Strategy A: static call (R8 optimization)
        try {
            val fcitx = method.invoke(null)
            if (fcitx != null) {
                Log.i(TAG, "getRealFcitx() works statically (R8-optimized)")
                return fcitx
            }
        } catch (_: NullPointerException) { }

        // Strategy B: via hook-captured singleton
        val daemon = RimeSyncHook.daemonInstance
        if (daemon != null) {
            return try { method.invoke(daemon) } catch (_: Exception) { null }
        }

        Log.w(TAG, "Cannot get Fcitx instance (static failed, daemon not captured)")
        return null
    }

    /**
     * Try to call FcitxDaemon.connect():
     *   A) Static call (R8 may have staticized object methods)
     *   B) Via hook-captured singleton reference
     */
    private fun connectToFcitx(daemonClass: Class<*>): Any? {
        val connectMethod = daemonClass.getDeclaredMethod("connect", String::class.java)
        connectMethod.isAccessible = true

        // Strategy A: call connect() with null instance (R8-staticized)
        try {
            val conn = connectMethod.invoke(null, RimeSyncHook.CONNECTION_NAME)
            Log.i(TAG, "connect() works statically (R8-optimized)")
            return conn
        } catch (_: NullPointerException) {
            // Not static — fall through to B
        } catch (e: Exception) {
            Log.e(TAG, "connect() static attempt failed", e); return null
        }

        // Strategy B: hook-captured singleton
        val daemon = RimeSyncHook.daemonInstance
            ?: run { Log.w(TAG, "FcitxDaemon not captured yet — activate keyboard once then retry"); return null }
        return try {
            connectMethod.invoke(daemon, RimeSyncHook.CONNECTION_NAME)
        } catch (e: Exception) {
            Log.e(TAG, "connect() via instance failed", e); null
        }
    }

    private fun disconnectFromFcitx(daemonClass: Class<*>) {
        try {
            val disconnectMethod = daemonClass.getDeclaredMethod("disconnect", String::class.java)
            disconnectMethod.isAccessible = true
            try {
                disconnectMethod.invoke(null, RimeSyncHook.CONNECTION_NAME)
            } catch (_: NullPointerException) {
                RimeSyncHook.daemonInstance?.let {
                    disconnectMethod.invoke(it, RimeSyncHook.CONNECTION_NAME)
                }
            }
        } catch (_: Exception) {}
    }

    /**
     * Call FcitxConnection.runImmediately() with a reflective lambda.
     * Inside the lambda, calls the JNI setFcitxAddonSubConfig("rime", "sync")
     * which does NOT require an active InputContext.
     */
    private fun triggerSyncOnFcitxThread(connection: Any, daemonClass: Class<*>, fcitxInstance: Any?) {
        val function2Class = classLoader.loadClass("kotlin.jvm.functions.Function2")
        val fcitxClass = classLoader.loadClass("org.fcitx.fcitx5.android.core.Fcitx")
        val rawConfigClass = classLoader.loadClass("org.fcitx.fcitx5.android.core.RawConfig")

        val daemon = RimeSyncHook.daemonInstance

        val latch = CountDownLatch(1)
        val results = mutableListOf<String>()

        val handler = java.lang.reflect.InvocationHandler { _, method, args ->
            if (method.name == "invoke" && args != null && args.size >= 2) {
                try {
                    // Get Fcitx instance: prefer passed-in, then static, then daemon
                    val fcitx = fcitxInstance
                        ?: try { daemonClass.getDeclaredMethod("getRealFcitx").invoke(null) } catch (_: Exception) { null }
                        ?: try { daemonClass.getDeclaredMethod("getRealFcitx").invoke(daemon) } catch (_: Exception) { null }

                    if (fcitx == null) {
                        results += "Cannot access Fcitx instance"
                        Log.e(TAG, results.last())
                    } else {
                        // Get JNI companion from Fcitx instance
                        val jniCompanion = getFieldValue(fcitxClass, fcitx, "JNI")
                            ?: run { results += "JNI companion not accessible"; return@InvocationHandler kotlin.Unit }

                        val emptyConfig = rawConfigClass.getDeclaredConstructor().newInstance()

                        val jniClass = jniCompanion.javaClass
                        val setSubConfigMethod = findDeclaredMethodRecursive(
                            jniClass, "setFcitxAddonSubConfig",
                            String::class.java, String::class.java, rawConfigClass
                        ) ?: run { results += "setFcitxAddonSubConfig not found"; return@InvocationHandler kotlin.Unit }

                        setSubConfigMethod.isAccessible = true
                        setSubConfigMethod.invoke(jniCompanion, "rime", "sync", emptyConfig)

                        results += "Sync triggered via JNI setFcitxAddonSubConfig(rime, sync)"
                        Log.i(TAG, results.last())
                    }
                } catch (e: Exception) {
                    results += "Error during sync: ${e.javaClass.simpleName}: ${e.message}"
                    Log.e(TAG, results.last(), e)
                }
                latch.countDown()
            }
            kotlin.Unit
        }

        val lambda = Proxy.newProxyInstance(classLoader, arrayOf(function2Class), handler)

        val runImmediatelyMethod = findDeclaredMethodRecursive(
            connection.javaClass, "runImmediately", function2Class
        ) ?: run { Log.w(TAG, "runImmediately not found"); return }
        runImmediatelyMethod.isAccessible = true

        try {
            runImmediatelyMethod.invoke(connection, lambda)
            if (!latch.await(15, TimeUnit.SECONDS)) {
                Log.w(TAG, "Sync timed out after 15s")
            }
            results.forEach { Log.i(TAG, it) }
        } catch (e: Exception) {
            Log.e(TAG, "runImmediately failed", e)
        }
    }

    // ── Reflection helpers ───────────────────────────────────────────

    private fun getFieldValue(clazz: Class<*>, instance: Any?, fieldName: String): Any? {
        var c: Class<*>? = clazz
        while (c != null) {
            try {
                val field = c.getDeclaredField(fieldName)
                field.isAccessible = true
                return field.get(instance)
            } catch (_: NoSuchFieldException) { c = c.superclass }
        }
        return null
    }

    private fun findDeclaredMethodRecursive(
        clazz: Class<*>, name: String, vararg paramTypes: Class<*>
    ): Method? {
        var c: Class<*>? = clazz
        while (c != null) {
            try { return c.getDeclaredMethod(name, *paramTypes) }
            catch (_: NoSuchMethodException) { c = c.superclass }
        }
        for (iface in clazz.interfaces) {
            findDeclaredMethodRecursive(iface, name, *paramTypes)?.let { return it }
        }
        return null
    }
}
