package com.retroemupouch.app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.zip.CRC32

/**
 * Flutter entry activity. Hosts the two platform channels:
 *   gs/storage   - filesDir lookup + SAF ROM/package import + package export
 *   gs/emulator  - launch the native EmulatorActivity
 */
class MainActivity : FlutterActivity() {

    companion object {
        const val TAG = "GS-Main"
        const val REQ_IMPORT = 0x4753 // "GS"  (single ROM)
        const val REQ_IMPORT_PKG = 0x4754 // "GT"  (game resource package / zip)
        const val REQ_EXPORT = 0x4755 // "GU"  (export package to SAF)
        const val REQ_IMPORT_BIOS = 0x4756 // "GV"  (BIOS / system blob into system/)
        const val REQ_IMPORT_MOVES = 0x4757 // "GW"  (moves.json profile import via SAF)
        const val REQ_EXPORT_MOVES = 0x4758 // "GX"  (moves.json profile export via SAF)
        const val REQ_IMPORT_BIOS_MULTI = 0x4759 // "GY"  (multi-pick BIOS into system/)
        const val REQ_EXPORT_BIOS = 0x475A // "GZ"  (export all BIOS as a single zip)
        const val REQ_IMPORT_PAD = 0x475B // "HA"  (虚拟手柄布局 JSON 导入 via SAF)
        const val REQ_EXPORT_PAD = 0x475C // "HB"  (虚拟手柄布局 JSON 导出 via SAF)

        /// FlutterEngineCache key of this activity's engine. EmulatorActivity
        /// uses it to call back into Dart (gs/netplay "playEnded") when a
        /// netplay session ends, so the Dart PlaySession reaches a terminal
        /// state even though the emulator runs in a separate Activity.
        const val ENGINE_MAIN = "gs_main"
    }

    private var pendingResult: MethodChannel.Result? = null
    private var pendingMode: String? = null // "import_rom" | "import_pkg" | "export" | "import_bios" | "import_bios_multi" | "export_bios" | "delete_bios" | "import_pad" | "export_pad"
    private var pendingExportSrc: String? = null
    private var multicastLock: android.net.wifi.WifiManager.MulticastLock? = null

    @Deprecated("required for SAF on the minimal embedding classpath")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_IMPORT && requestCode != REQ_IMPORT_PKG &&
            requestCode != REQ_EXPORT && requestCode != REQ_IMPORT_BIOS &&
            requestCode != REQ_IMPORT_MOVES && requestCode != REQ_EXPORT_MOVES &&
            requestCode != REQ_IMPORT_BIOS_MULTI && requestCode != REQ_EXPORT_BIOS &&
            requestCode != REQ_IMPORT_PAD && requestCode != REQ_EXPORT_PAD) return
        val result = pendingResult
        val mode = pendingMode
        pendingResult = null
        pendingMode = null
        val exportSrc = pendingExportSrc
        pendingExportSrc = null
        if (result == null || mode == null) return
        if (resultCode != Activity.RESULT_OK) {
            // User cancelled — return null/empty so Dart can short-circuit.
            try {
                when (mode) {
                    "import_bios_multi" -> result.success(emptyList<String>())
                    else -> result.success(null)
                }
            } catch (_: Throwable) {}
            return
        }
        try {
            when (mode) {
                "import_rom" -> result.success(importRom(data?.data!!))
                "import_pkg" -> result.success(importZipPackage(data?.data!!))
                "export" -> result.success(exportToFile(data?.data!!, exportSrc!!))
                "import_bios" -> result.success(importBios(data?.data!!))
                "import_moves" -> result.success(importMovesConfig(data?.data!!))
                "export_moves" -> result.success(exportToFile(data?.data!!, exportSrc!!))
                "import_pad" -> result.success(importPadConfig(data?.data!!))
                "export_pad" -> result.success(exportToFile(data?.data!!, exportSrc!!))
                // Multi-select BIOS picker: `clipData` carries the per-item
                // URIs when the picker ran with EXTRA_ALLOW_MULTIPLE; some
                // OEM pickers (older Files / EMUI) fall back to a single
                // `data` even when multi is requested, so we accept both.
                "import_bios_multi" -> {
                    val uris = collectSafUris(data)
                    result.success(importBiosBatch(uris))
                }
                // Build a zip of every BIOS currently in <filesDir>/system/ and
                // stream it into the user-created SAF document. Returns true
                // on success, false when the user cancelled (handled above).
                "export_bios" -> result.success(exportBiosZipTo(data?.data!!))
                else -> result.success(null)
            }
        } catch (t: Throwable) {
            Log.e(TAG, "operation failed", t)
            result.error("OP_FAILED", t.message ?: "operation failed", null)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Expose the engine so EmulatorActivity can notify Dart when a
        // netplay session ends (clean exit, drop or start failure).
        FlutterEngineCache.getInstance().put(ENGINE_MAIN, flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gs/storage").setMethodCallHandler { call, result ->
            when (call.method) {
                "getFilesDir" -> result.success(filesDir.absolutePath)
                // Human-friendly default name for 「发现伙伴」 (e.g. "HONOR OXF-AN10").
                "getDeviceModel" -> result.success(
                    listOf(Build.MANUFACTURER, Build.MODEL)
                        .filter { !it.isNullOrBlank() }
                        .joinToString(" ")
                        .ifBlank { "Android" }
                )
                // Free bytes on the partition hosting filesDir, used by the
                // 「发现伙伴」 import engine's space precheck.
                "getAvailableBytes" -> try {
                    val stat = android.os.StatFs(filesDir.absolutePath)
                    result.success(stat.availableBytes)
                } catch (t: Throwable) {
                    result.error("STATFS_FAILED", t.message, null)
                }
                // Wi-Fi multicast lock: Android filters broadcast/multicast
                // UDP by default for battery saving; the peers page holds
                // this lock while discovering partners and releases it on
                // dispose (service runs foreground-only).
                "acquireMulticastLock" -> try {
                    val wifi = applicationContext
                        .getSystemService(android.content.Context.WIFI_SERVICE)
                        as android.net.wifi.WifiManager
                    val lock = multicastLock ?: wifi.createMulticastLock(
                        "gamepouch-peer-discovery").also { multicastLock = it }
                    if (!lock.isHeld) lock.acquire()
                    result.success(true)
                } catch (t: Throwable) {
                    result.success(false)
                }
                "releaseMulticastLock" -> try {
                    multicastLock?.let { if (it.isHeld) it.release() }
                    result.success(true)
                } catch (t: Throwable) {
                    result.success(false)
                }
                // CRC key of the game currently running in EmulatorActivity
                // (null when idle); saves for this CRC are import-locked.
                "getRunningSaveKey" ->
                    result.success(EmulatorActivity.runningSaveKey)
                "importRomViaSaf" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "import_rom"
                    val mime = call.argument<String>("mime") ?: "*/*"
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType(mime)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_IMPORT)
                }
                // Picks any file; the ZIP magic is verified and the bytes are
                // copied into filesDir/import_cache so Dart can parse the
                // gamepouch package (auto-detecting rom vs resource package).
                "importPackageViaSaf" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "import_pkg"
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("*/*")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_IMPORT_PKG)
                }
                // Picks a single BIOS / system blob (e.g. `neogeo.zip`) and copies
                // it verbatim into filesDir/system where libretro cores look it up.
                // The original file name is preserved because cores match BIOS by
                // exact (case-insensitive) name. Returns the stored name, or null
                // if the user cancels. Unlike importRomViaSaf this does NOT index
                // the file as a playable game.
                "importBiosViaSaf" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "import_bios"
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("*/*")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_IMPORT_BIOS)
                }
                // Multi-pick variant of importBiosViaSaf: opens the SAF picker
                // with EXTRA_ALLOW_MULTIPLE so the user can drop in every BIOS
                // (neogeo.zip + qsound.zip + …) in a single round-trip. The
                // result is the list of stored names (`<filesDir>/system/<n>`)
                // so Dart can refresh its "missing BIOS" state without a
                // second system() call. Returns an empty list on cancel.
                "importBiosBatchViaSaf" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "import_bios_multi"
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("*/*")
                        // Extra so the picker surfaces checkboxes; some OEM
                        // pickers (EMUI Files) silently fall back to single
                        // pick — onActivityResult handles both shapes.
                        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_IMPORT_BIOS_MULTI)
                }
                // Builds a single zip of every file under
                // `<filesDir>/system/` (BIOS blobs the user supplied) and
                // streams it into a user-created SAF document. The exported
                // bundle is round-trip safe: the same names land at the top
                // level of the zip, so the user can re-import via
                // importBiosBatchViaSaf on a fresh phone. Returns true on
                // success, false / null on cancel.
                "exportBiosZipViaSaf" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "export_bios"
                    val stamp = java.text.SimpleDateFormat("yyyyMMdd_HHmmss",
                        java.util.Locale.US).format(java.util.Date())
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("application/zip")
                        putExtra(Intent.EXTRA_TITLE, "gamepouch-bios-$stamp.zip")
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_EXPORT_BIOS)
                }
                // Removes a user-installed BIOS from `<filesDir>/system/`.
                // The on-launch `LockedRom` mirror step will re-stage it from
                // the next `importBios` call. Used by the settings page's
                // "delete one" row. Returns true iff the file existed and
                // was removed (or didn't exist — both are success for the
                // caller; the UI only needs to re-render the list).
                "deleteBios" -> {
                    val name = call.argument<String>("name")
                    if (name.isNullOrBlank()) {
                        result.error("BAD_ARGS", "name is required", null)
                        return@setMethodCallHandler
                    }
                    result.success(deleteBios(name))
                }
                // Copies [sourcePath] (a zip Dart just built under filesDir)
                // into a user-created SAF document so it lands somewhere the
                // user can copy offline (Downloads / USB / 蓝牙 / 微信文件).
                "exportPackageViaSaf" -> {
                    val src = call.argument<String>("sourcePath")
                    if (src.isNullOrBlank()) {
                        result.error("BAD_ARGS", "sourcePath is required", null)
                        return@setMethodCallHandler
                    }
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "export"
                    pendingExportSrc = src
                    val name = call.argument<String>("suggestedName")
                        ?: "gamepouch-package.zip"
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("application/zip")
                        putExtra(Intent.EXTRA_TITLE, name)
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_EXPORT)
                }
                // Picks a JSON file via SAF and copies it into
                // `filesDir/library/imports/moves-<ts>.json` for the settings
                // editor to validate + adopt (or discard). The native side
                // pre-checks that the file parses as a JSON object so the
                // editor never has to deal with broken input.
                "importMovesConfigViaSaf" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "import_moves"
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        // Restrict to JSON so the picker doesn't open on the
                        // gallery or every file under Downloads.
                        setType("application/json")
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf(
                            "application/json", "text/plain", "*/*"))
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_IMPORT_MOVES)
                }
                // Streams the live `filesDir/library/moves.json` (or any
                // other path Dart hands us) into a user-created SAF document
                // so the user can share their current profile between phones
                // (e.g. via 蓝牙 / 微信文件 / USB).
                "exportMovesConfigViaSaf" -> {
                    val src = call.argument<String>("sourcePath")
                    if (src.isNullOrBlank()) {
                        result.error("BAD_ARGS", "sourcePath is required", null)
                        return@setMethodCallHandler
                    }
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "export_moves"
                    pendingExportSrc = src
                    val name = call.argument<String>("suggestedName")
                        ?: "moves.json"
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("application/json")
                        putExtra(Intent.EXTRA_TITLE, name)
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_EXPORT_MOVES)
                }
                // Picks a JSON file via SAF and copies it into
                // `filesDir/library/imports/pad-<ts>.json` for the settings
                // sheet to validate + adopt (scale / offsetX / offsetY).
                "importPadConfigViaSaf" -> {
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "import_pad"
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("application/json")
                        putExtra(Intent.EXTRA_MIME_TYPES,
                            arrayOf("application/json", "text/plain", "*/*"))
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_IMPORT_PAD)
                }
                // Streams a Dart-written pad-layout JSON into a user-created SAF
                // document so the layout can be shared between phones.
                "exportPadConfigViaSaf" -> {
                    val src = call.argument<String>("sourcePath")
                    if (src.isNullOrBlank()) {
                        result.error("BAD_ARGS", "sourcePath is required", null)
                        return@setMethodCallHandler
                    }
                    if (pendingResult != null) {
                        result.error("BUSY", "another operation is in progress", null)
                        return@setMethodCallHandler
                    }
                    pendingResult = result
                    pendingMode = "export_pad"
                    pendingExportSrc = src
                    val name = call.argument<String>("suggestedName") ?: "gamepouch_pad_layout.json"
                    val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        setType("application/json")
                        putExtra(Intent.EXTRA_TITLE, name)
                        addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                    }
                    @Suppress("DEPRECATION")
                    startActivityForResult(intent, REQ_EXPORT_PAD)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gs/emulator").setMethodCallHandler { call, result ->
            when (call.method) {
                "launch" -> {
                    val rom = call.argument<String>("rom")
                    if (rom.isNullOrBlank()) {
                        result.error("BAD_ARGS", "rom is required", null)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(this, EmulatorActivity::class.java)
                        .putExtra("rom", rom)
                        .putExtra("core", call.argument<String>("core") ?: "fceumm")
                        // Platform id (PlatformKind.name, e.g. "neogeo" /
                        // "mame") lets the virtual pad pick the per-hardware
                        // button layout — arcade cores share one core id.
                        .putExtra("platform", call.argument<String>("platform") ?: "")
                    call.argument<Map<String, Any?>>("bench")?.let { bench ->
                        (bench["rom"] as? String)?.let { intent.putExtra("bench_rom", it) }
                        (bench["id"] as? String)?.let { intent.putExtra("bench_id", it) }
                        (bench["seconds"] as? Int)?.let { intent.putExtra("bench_seconds", it) }
                    }
                    // Netplay session extras — forwarded verbatim; the
                    // EmulatorActivity netplay branch is added in Task 6.
                    call.argument<Map<String, Any?>>("netplay")?.let { np ->
                        // Dart ints outside the 32-bit range (roomId32 is a
                        // random u32) arrive as java.lang.Long over the
                        // StandardMethodCodec; a plain `as? Int` silently
                        // drops them and the session falls back to solo play.
                        fun npInt(key: String): Int? =
                            (np[key] as? Number)?.toInt()
                        npInt("role")?.let { intent.putExtra("np_role", it) }
                        (np["peerIp"] as? String)?.let { intent.putExtra("np_peer_ip", it) }
                        npInt("peerPort")?.let { intent.putExtra("np_peer_port", it) }
                        npInt("localPort")?.let { intent.putExtra("np_local_port", it) }
                        (np["sessionKey"] as? String)?.let { intent.putExtra("np_session_key", it) }
                        npInt("roomId")?.let { intent.putExtra("np_room_id", it) }
                        npInt("initialD")?.let { intent.putExtra("np_initial_d", it) }
                        (np["adaptive"] as? Boolean)?.let { intent.putExtra("np_adaptive", it) }
                        npInt("bootstrapPort")?.let { intent.putExtra("np_bootstrap_port", it) }
                        (np["saveKey"] as? String)?.let { intent.putExtra("np_save_key", it) }
                    }
                    startActivity(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gs/updater").setMethodCallHandler { call, result ->
            when (call.method) {
                "getVersion" -> {
                    val pi = packageManager.getPackageInfo(packageName, 0)
                    val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        pi.longVersionCode
                    } else {
                        @Suppress("DEPRECATION") pi.versionCode.toLong()
                    }
                    result.success(mapOf(
                        "versionCode" to code,
                        "versionName" to pi.versionName
                    ))
                }
                "installApk" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("BAD_ARGS", "path is required", null)
                        return@setMethodCallHandler
                    }
                    try {
                        installApk(File(path))
                        result.success(true)
                    } catch (t: Throwable) {
                        Log.e(TAG, "install failed", t)
                        result.error("INSTALL_FAILED", t.message ?: "install failed", null)
                    }
                }
                "openStore" -> {
                    try {
                        val intent = Intent(
                            Intent.ACTION_VIEW,
                            Uri.parse("market://details?id=$packageName")
                        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try {
                            startActivity(intent)
                        } catch (_: android.content.ActivityNotFoundException) {
                            startActivity(
                                Intent(
                                    Intent.ACTION_VIEW,
                                    Uri.parse("https://appgallery.huawei.com/app/$packageName")
                                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                        }
                        result.success(true)
                    } catch (t: Throwable) {
                        Log.e(TAG, "openStore failed", t)
                        result.error("OPEN_STORE_FAILED", t.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Launches the system installer for an APK already downloaded into
     * filesDir/updates (served through [GsApkProvider]). On API 26+ the first
     * attempt bounces the user into the "install unknown apps" settings;
     * returning to the app and tapping install again proceeds.
     */
    private fun installApk(apk: File) {
        // P0-4: store builds must never install an APK in-app (self-update).
        if (BuildConfig.FLAVOR == "store") {
            throw IllegalStateException("商店版禁止自更新 / 安装 APK")
        }
        if (!apk.exists()) throw IllegalStateException("APK 不存在：${apk.absolutePath}")
        val uri = Uri.Builder()
            .scheme("content")
            .authority("$packageName.apkprovider")
            .appendPath("apk")
            .appendQueryParameter("path", apk.absolutePath)
            .build()
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
    }

    /**
     * Copies a user-picked BIOS / system blob verbatim into [filesDir]/system
     * (where libretro cores look it up, e.g. `neogeo.zip` for NeoGeo on
     * mame/FBA). The original file name is preserved because cores match the
     * blob by exact (case-insensitive) name. Returns the stored file name, or
     * throws if the copy fails. No game indexing is performed.
     */
    private fun importBios(uri: Uri): String {
        val sysDir = File(filesDir, "system").apply { mkdirs() }
        val displayName = queryDisplayName(uri) ?: "bios_${System.currentTimeMillis()}.bin"
        val dest = File(sysDir, sanitize(displayName))
        if (dest.exists()) dest.delete()
        contentResolver.openInputStream(uri)!!.use { input ->
            dest.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var n: Int
                while (input.read(buf).also { n = it } > 0) out.write(buf, 0, n)
            }
        }
        return dest.name
    }

    /**
     * Drops every URI in [uris] into `<filesDir>/system/` using [importBios]
     * semantics. Used by the multi-select SAF picker. Failures on individual
     * URIs are logged and skipped — one bad pick shouldn't sink the whole
     * batch. Returns the list of stored file names actually written; the
     * Dart side uses this to refresh the "missing BIOS" state and only
     * re-prompt for the ones that didn't make it.
     */
    private fun importBiosBatch(uris: List<Uri>): List<String> {
        if (uris.isEmpty()) return emptyList()
        val written = ArrayList<String>(uris.size)
        for (u in uris) {
            try { written.add(importBios(u)) } catch (e: Throwable) {
                Log.w(TAG, "importBios skip ${u}: ${e.message}")
            }
        }
        return written
    }

    /**
     * Normalises a SAF `onActivityResult` intent into a list of picked URIs.
     * Modern pickers honour `EXTRA_ALLOW_MULTIPLE` and populate `clipData`;
     * the older `data.data` single-URI shape is also supported so callers
     * don't have to branch.
     */
    private fun collectSafUris(data: Intent?): List<Uri> {
        if (data == null) return emptyList()
        val clip = data.clipData
        if (clip != null) {
            val out = ArrayList<Uri>(clip.itemCount)
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i)?.uri?.let { out.add(it) }
            }
            return out
        }
        return listOfNotNull(data.data)
    }

    /**
     * Zips every file directly under `<filesDir>/system/` into a single
     * archive and streams it into the user-created SAF document at [uri].
     * Files only at the root are included (subdirs are skipped — they're
     * staging copies the next launch re-creates and aren't worth
     * round-tripping). The on-launch `LockedRom` mirror step will re-stage
     * the imported bundle into the per-core subdirs after
     * `SystemFiles.syncAll` runs.
     */
    private fun exportBiosZipTo(uri: Uri): Boolean {
        val sysDir = File(filesDir, "system")
        if (!sysDir.isDirectory) throw IllegalStateException(
            "no BIOS installed under ${sysDir.absolutePath}")
        val files = sysDir.listFiles { f -> f.isFile } ?: emptyArray()
        if (files.isEmpty()) throw IllegalStateException(
            "no BIOS to export under ${sysDir.absolutePath}")
        val out = contentResolver.openOutputStream(uri)
            ?: throw IllegalStateException("无法写入目标文档（权限被拒？）")
        java.util.zip.ZipOutputStream(out).use { zos ->
            for (f in files) {
                zos.putNextEntry(java.util.zip.ZipEntry(f.name))
                f.inputStream().use { ins ->
                    val buf = ByteArray(64 * 1024)
                    var n: Int
                    while (ins.read(buf).also { n = it } > 0) zos.write(buf, 0, n)
                }
                zos.closeEntry()
            }
        }
        Log.i(TAG, "exported ${files.size} BIOS files → $uri")
        return true
    }

    /**
     * Removes a single BIOS file from `<filesDir>/system/`. Per-core
     * staged copies under `system/mame/roms/<name>` are also cleared so
     * the next launch's `LockedRom` mirror step doesn't resurrect the
     * deleted file. Returns true on success.
     */
    private fun deleteBios(name: String): Boolean {
        val safe = sanitize(name)
        val targets = listOf(
            File(filesDir, "system/$safe"),
            File(filesDir, "system/mame/roms/$safe")
        )
        var changed = false
        for (t in targets) {
            if (t.exists()) { if (t.delete()) changed = true }
        }
        return changed
    }

    /**
     * Imports a user-picked JSON moves-config file. Copies it into
     * `<filesDir>/library/imports/moves-<ts>.json` so the editor can adopt
     * it (overwrite `library/moves.json`) without ever touching the live
     * file until validation passes. Returns a small map { path, name,
     * size, ok } where `ok` is true iff the bytes parse as a JSON object.
     */
    private fun importMovesConfig(uri: Uri): Map<String, Any?> {
        val importsDir = File(filesDir, "library/imports").apply { mkdirs() }
        val displayName = queryDisplayName(uri) ?: "moves_${System.currentTimeMillis()}.json"
        val safeName = if (displayName.endsWith(".json", ignoreCase = true))
            displayName else "$displayName.json"
        val dest = File(importsDir, "moves-${System.currentTimeMillis()}-${sanitize(safeName)}")
        var size = 0L
        contentResolver.openInputStream(uri)!!.use { input ->
            dest.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var n: Int
                while (input.read(buf).also { n = it } > 0) {
                    out.write(buf, 0, n); size += n
                }
            }
        }
        val ok = try {
            val raw = dest.readText()
            val obj = org.json.JSONObject(raw)
            obj.has("profiles")
        } catch (_: Exception) { false }
        return mapOf(
            "path" to dest.absolutePath,
            "name" to displayName,
            "size" to size,
            "ok" to ok
        )
    }

    /**
     * Imports a user-picked virtual-pad layout JSON. Copies it into
     * `<filesDir>/library/imports/pad-<ts>.json` and returns { path, name,
     * size, ok } where `ok` is true iff the bytes parse as a JSON object.
     * The settings sheet validates the scale / offsetX / offsetY fields and
     * adopts them (overwriting the live prefs) only after validation passes.
     */
    private fun importPadConfig(uri: Uri): Map<String, Any?> {
        val importsDir = File(filesDir, "library/imports").apply { mkdirs() }
        val displayName = queryDisplayName(uri) ?: "pad_${System.currentTimeMillis()}.json"
        val safeName = if (displayName.endsWith(".json", ignoreCase = true))
            displayName else "$displayName.json"
        val dest = File(importsDir, "pad-${System.currentTimeMillis()}-${sanitize(safeName)}")
        var size = 0L
        contentResolver.openInputStream(uri)!!.use { input ->
            dest.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var n: Int
                while (input.read(buf).also { n = it } > 0) {
                    out.write(buf, 0, n); size += n
                }
            }
        }
        val ok = try {
            val raw = dest.readText()
            org.json.JSONObject(raw)
            true
        } catch (_: Exception) { false }
        return mapOf(
            "path" to dest.absolutePath,
            "name" to displayName,
            "size" to size,
            "ok" to ok
        )
    }

    private fun importRom(uri: Uri): Map<String, Any?> {        val romsDir = File(filesDir, "roms").apply { mkdirs() }
        val displayName = queryDisplayName(uri) ?: "rom_${System.currentTimeMillis()}"
        val safeName = uniqueName(romsDir, sanitize(displayName))
        val dest = File(romsDir, safeName)

        val crc = CRC32()
        var size = 0L
        var ines = false
        contentResolver.openInputStream(uri)!!.use { input ->
            dest.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                val head = ByteArray(4)
                var headOff = 0
                while (true) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    if (headOff < 4) {
                        val take = minOf(n, 4 - headOff)
                        System.arraycopy(buf, 0, head, headOff, take)
                        headOff += take
                    }
                    crc.update(buf, 0, n)
                    out.write(buf, 0, n)
                    size += n
                }
                ines = headOff == 4 &&
                        head[0] == 0x4E.toByte() && head[1] == 0x4E.toByte() &&
                        head[2] == 0x4E.toByte() && head[3] == 0x1A.toByte()
            }
        }

        return mapOf(
            "name" to safeName,
            "originalName" to displayName,
            "relativePath" to "roms/$safeName",
            "size" to size,
            "crc32" to crc.value.toLong(),
            "ines" to ines
        )
    }

    /**
     * Copies a user-picked ZIP into [filesDir]/import_cache and returns its
     * on-device path so Dart can parse/extract it (gamepouch package, plain
     * ROM zip, or a single ROM) with the `archive` package. The ZIP magic
     * (PK\x03\x04) is verified up front so a wrong pick fails clearly.
     */
    private fun importZipPackage(uri: Uri): Map<String, Any?> {
        val cacheDir = File(filesDir, "import_cache").apply { mkdirs() }
        val displayName = queryDisplayName(uri) ?: "package_${System.currentTimeMillis()}.zip"
        val safeName = uniqueName(cacheDir, sanitize(displayName))
        val dest = File(cacheDir, safeName)
        var size = 0L
        contentResolver.openInputStream(uri)!!.use { input ->
            dest.outputStream().use { out ->
                val buf = ByteArray(64 * 1024)
                var n: Int
                while (input.read(buf).also { n = it } > 0) {
                    out.write(buf, 0, n)
                    size += n
                }
            }
        }
        val head = ByteArray(4)
        dest.inputStream().use { it.read(head) }
        if (!(head[0] == 0x50.toByte() && head[1] == 0x4B.toByte() &&
                    head[2] == 0x03.toByte() && head[3] == 0x04.toByte())) {
            dest.delete()
            throw IllegalStateException("选择的文件不是 ZIP 压缩包")
        }
        return mapOf("path" to dest.absolutePath, "name" to safeName, "size" to size)
    }

    /** Streams [srcPath] (a zip Dart built under filesDir) into a user-created
     *  SAF document [uri]; returns true on success. */
    private fun exportToFile(uri: Uri, srcPath: String): Boolean {
        val src = File(srcPath)
        if (!src.exists()) throw IllegalStateException("源文件不存在：$srcPath")
        contentResolver.openOutputStream(uri)?.use { out ->
            src.inputStream().use { input ->
                val buf = ByteArray(64 * 1024)
                var n: Int
                while (input.read(buf).also { n = it } > 0) out.write(buf, 0, n)
            }
        } ?: throw IllegalStateException("无法写入目标文档（权限被拒？）")
        return true
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (DocumentsContract.isDocumentUri(this, uri)) {
            try {
                contentResolver.query(uri, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)
                    ?.use { c -> if (c.moveToFirst() && !c.isNull(0)) return c.getString(0) }
            } catch (_: Throwable) { /* fall through */ }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.substringAfterLast(':')
    }

    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|]+"), "_").trim()
        return cleaned.ifBlank { "rom" }
    }

    private fun uniqueName(dir: File, name: String): String {
        if (!File(dir, name).exists()) return name
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (File(dir, "${base}_$i$ext").exists()) i++
        return "${base}_$i$ext"
    }
}
