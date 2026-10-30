package com.retroemupouch.app

import android.util.Log
import java.io.File
import java.io.RandomAccessFile
import java.util.zip.ZipEntry
import java.util.zip.ZipFile
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Helpers around the ROM container that ships in the library.
 *
 * Two input formats are accepted (the loader tries the encrypted path
 * first and falls back to the plaintext path when the file isn't an
 * MGS1-locked container):
 *
 *   - MGS1-locked ZIP — single-entry `.zip` whose only payload is the
 *     MGS1 ciphertext (see tools/library/lib/rom_crypto.dart on the
 *     server side, crypto/rom_crypto.cpp on the native side). Decrypted
 *     into the app-private cache directory; the plaintext is `unlink`'d
 *     when the activity tears down.
 *
 *   - Plain (unencrypted) ZIP — a multi-entry archive where each entry
 *     is already a ROM chunk in MAME / FBA / libretro expected layout.
 *     Detected when `nativeDecryptRom` returns null but the file is
 *     itself a valid ZIP container; we then just copy the file through
 *     to `rom_cache/` without further processing. This is the
 *     fallback for sideloaded WinKawaks / MAME / FBA dumps.
 *
 * On the phone we never persist the decrypted ROM past the session —
 * the cache entry is rewritten by `materialize` and deleted by
 * `release` (or wiped on activity teardown). This keeps the on-device
 * attack surface limited to whatever a temporary `unlink()` after use
 * can offer.
 */
object LockedRom {

    private const val TAG = "GS-LockedRom"

    /**
     * Basenames that must be preserved across a cache wipe. These are
     * BIOS / system files that FBA-2012 looks up directly in the same
     * directory as the game ROM — wiping them at launch time means
     * every NeoGeo (and similar BIOS-fronted) game fails to find its
     * BIOS, even though `system/neogeo.zip` is still present in the
     * app bundle.
     *
     * Names are matched case-insensitively against `rom_cache/<name>`.
     */
    private val PRESERVED_CACHE_FILES = setOf(
        "neogeo.zip",          // FBA-2012 NeoGeo BIOS
        "neogeo_2.zip",        // alternate BIOS bundle names some
                               // forks ship
        "mslug.zip",
        "pocketneo.zip",       // FBA-2012 "pocket" NeoGeo BIOS bundle
    )

    /** Cache dir for decrypted ROMs. Created lazily. */
    fun cacheDir(filesDir: File): File =
        File(filesDir, "rom_cache").apply { mkdirs() }

    /**
     * Decrypts (or pass-through copies) the locked ROM at [lockedPath]
     * and returns a temporary plaintext file ready to be passed to
     * [NativeBridge.nativeInit]. The returned file lives in the app's
     * private cache and should be [release]d when the activity tears
     * down.
     *
     * The implementation tries the MGS1 decryption path first; when
     * decryption fails (the cipher blob doesn't carry an MGS1 header
     * because the file is already plaintext) and the file looks like a
     * valid ROM zip, the file is copied verbatim to `rom_cache/` and
     * returned. Other formats (single .nes / .gb / .gba / .bin files)
     * still go through the encryption layer and require a lockfile.
     *
     * [coreId] is the libretro core id from the launch intent
     * (`fbalpha2012` for arcade, `fceumm` for NES, ...). It's used to
     * decide whether the launch needs a BIOS bundle (e.g. `neogeo.zip`
     * for `fbalpha2012` + a NeoGeo ROM) — the activity-side caller always
     * knows the core, but path-based detection alone isn't reliable
     * once the cloud pipeline flattens everything to `roms/cloud/<title>`.
     */
    fun materialize(filesDir: File, lockedPath: File, coreId: String? = null): File {
        // Trace everything we touch; logcat filters sometimes drop "I"
        // priorities, so we use "W" (warning) and a unique tag prefix.
        Log.w(TAG, "=== materialize BEGIN ${lockedPath.path} (size=${lockedPath.length()}) ===")
        if (!lockedPath.exists()) error("locked rom missing: ${lockedPath.path}")
        Log.w(TAG, "exists ok")

        val isZip = isZipContainer(lockedPath)
        Log.w(TAG, "isZipContainer=$isZip")
        val mgs1Bytes: ByteArray = if (isZip) {
            try { readZipEntryViaFile(lockedPath) } catch (e: Throwable) {
                Log.w(TAG, "ZipFile failed (${e.javaClass.name}: ${e.message}); " +
                        "falling back to manual LFH parse")
                readZipEntryManual(lockedPath)
            }
        } else {
            lockedPath.readBytes()
        }
        Log.w(TAG, "mgs1Bytes.size=${mgs1Bytes.size}")
        if (mgs1Bytes.size >= 4) {
            val head = mgs1Bytes.copyOfRange(0, 4)
            Log.w(TAG, "first4=" + head.joinToString(",") { "%02x".format(it.toInt() and 0xFF) })
        }

        // R1: locked-ROM decryption has been removed. The app only passes
        // through user-supplied plaintext ROMs; encrypted MGS1 containers are
        // no longer supported.
        Log.w(TAG, "rom decryption disabled; plain pass-through only")

        // Stage the NeoGeo BIOS next to the game so the core can find it.
        // For FBA-2012 this goes flat into rom_cache; for MAME it lands in
        // rom_cache/mame (== content dir) and system/mame/roms. Without this
        // every NeoGeo title fails with a missing BIOS member (e.g.
        // "sfix.sfix NOT FOUND").
        ensureArcadeBiosInRomCache(filesDir, lockedPath, coreId)

        // Multi-entry game zip: copy verbatim into the cache.
        if (isZip && looksLikeMultiEntryRom(lockedPath)) {
            Log.w(TAG, "plain-zip pass-through")
            val out = passThroughPlainZip(filesDir, lockedPath, coreId)
            // MAME resolves ROMs (and clone parents) from the *directory*
            // (rompath), not just the content file. A lone clone zip such as
            // `1943j.zip` therefore fails unless its parent set (`1943.zip`)
            // sits beside it. Copy every other .zip in the game's library
            // folder into the MAME rom_cache dir so parent/clone/sibling sets
            // the user already imported become discoverable. MAME only loads
            // what a driver asks for, so unrelated zips are harmlessly ignored.
            if (coreId == "mame") gatherSiblingRoms(filesDir, lockedPath, out.parentFile!!)
            // Merge BIOS members into bootleg/PCB sets (e.g. kf2k3pcb) that
            // carry no implicit neogeo parent; no-op for ordinary games.
            mergeNeogeoBiosIntoGameZip(filesDir, out, coreId)
            return out
        }
        // Single-file ROM (.nes/.gb/.gba/.bin…): copy verbatim into the cache.
        val ext = lockedPath.extension.takeIf { it.isNotBlank() } ?: "bin"
        val rawStem = lockedPath.nameWithoutExtension.ifBlank { "rom" }
        val safeStem = rawStem
            .lowercase()
            .replace(Regex("\\s+"), "")
            .replace(Regex("[^a-z0-9_]"), "")
            .ifBlank { "rom_${System.currentTimeMillis()}" }
        val out = File(cacheDir(filesDir), "$safeStem.$ext")
        lockedPath.inputStream().use { ins -> out.outputStream().use { os -> ins.copyTo(os) } }
        Log.i(TAG, "materialized ${lockedPath.path} -> ${out.path} (${out.length()} bytes)")
        return out
    }

    /** Best-effort deletion of a temporary ROM materialised by [materialize]. */
    fun release(plainFile: File?) {
        if (plainFile == null) return
        try {
            if (plainFile.exists()) plainFile.delete()
        } catch (_: Throwable) {}
    }

    // ----------------------------------------------------------------- helpers

    /** Read the (only) entry via the random-access ZipFile API. */
    private fun readZipEntryViaFile(zip: File): ByteArray {
        java.util.zip.ZipFile(zip).use { zf ->
            val entries = zf.entries()
            if (!entries.hasMoreElements()) error("zip is empty: ${zip.path}")
            val entry = entries.nextElement()
            if (entry.isDirectory) error("zip must not contain directories: ${zip.path}")
            // We always write exactly one entry; drain any extras defensively.
            val bytes: ByteArray = zf.getInputStream(entry).readBytes()
            while (entries.hasMoreElements()) { zf.getInputStream(entries.nextElement()).close() }
            return bytes
        }
    }

    /**
     * Manual fallback for the rare case where [readZipEntryViaFile]
     * can't open the archive (e.g. transient I/O error): walk the local
     * file header by hand and copy out the entry bytes directly. We
     * trust the LFH's compressed/uncompressed sizes — both are equal
     * since we always write STORE-method single-entry ZIPs.
     */
    private fun readZipEntryManual(zip: File): ByteArray {
        val raf = java.io.RandomAccessFile(zip, "r")
        try {
            if (raf.length() < 30) error("zip too small: ${zip.path}")
            // Verify signature.
            val sig = IntArray(4) { 0 }
            for (i in 0..3) sig[i] = raf.read()
            if (sig[0] != 0x50 || sig[1] != 0x4b || sig[2] != 0x03 || sig[3] != 0x04) {
                error("not a ZIP local file header: ${zip.path}")
            }
            raf.seek(8)
            val method = raf.readUnsignedShortLE()
            // Skip to compressed-size (offset 18).
            raf.seek(18)
            val compSize = raf.readUnsignedIntLE()
            // Read filename length at offset 26.
            raf.seek(26)
            val nameLen = raf.readUnsignedShortLE()
            val extraLen = raf.readUnsignedShortLE()
            val dataStart = 30L + nameLen + extraLen
            // RandomAccessFile.readUnsignedIntLE returns Long for symmetry
            // with the 64-bit read APIs; the ZIP on-wire size is a 32-bit
            // unsigned int — clamp to Int for ByteArray allocation.
            val buf = ByteArray(compSize.coerceAtMost(Int.MAX_VALUE.toLong()).toInt())
            raf.seek(dataStart)
            raf.readFully(buf)
            if (method != 0) error("unsupported ZIP method $method (only STORE supported)")
            return buf
        } finally {
            raf.close()
        }
    }

    /** Helper: read a 16-bit LE unsigned int via RandomAccessFile. */
    private fun java.io.RandomAccessFile.readUnsignedShortLE(): Int {
        val b0 = read(); val b1 = read()
        if (b0 == -1 || b1 == -1) error("unexpected EOF")
        return b0 or (b1 shl 8)
    }

    /** Helper: read a 32-bit LE unsigned int via RandomAccessFile. */
    private fun java.io.RandomAccessFile.readUnsignedIntLE(): Long {
        val b0 = read(); val b1 = read(); val b2 = read(); val b3 = read()
        if (b0 == -1 || b1 == -1 || b2 == -1 || b3 == -1) error("unexpected EOF")
        return (b0 or (b1 shl 8) or (b2 shl 16) or (b3 shl 24)).toLong() and 0xFFFFFFFFL
    }

    /**
     * Returns true when [f] starts with the ZIP local-file-header magic
     * `PK\x03\x04`. Used so the same code can handle files written with
     * the `.zip` extension **and** files that the cloud sync renamed
     * without the extension (e.g. `roms/cloud/<title>.gba` containing a
     * `<title>.gba.zip` container).
     */
    private fun isZipContainer(f: File): Boolean = try {
        if (!f.name.endsWith(".zip", ignoreCase = true) && f.length() < 4) {
            false
        } else f.inputStream().use { ins ->
            val head = ByteArray(4)
            if (ins.read(head) != 4) return@use false
            head[0] == 0x50.toByte() && head[1] == 0x4B.toByte() &&
                    head[2] == 0x03.toByte() && head[3] == 0x04.toByte()
        }
    } catch (_: Throwable) {
        false
    }

    private fun ByteArray.zero() {
        for (i in indices) this[i] = 0
    }

    // ------------------------------------------------------------- plaintext zip
    //
    // The pass-through path supports unencrypted WinKawaks / MAME / FBA
    // dumps that were sideloaded onto the device without going through
    // the import / lockfile builder. They are real, multi-entry ROM zips
    // that any libretro core could already handle. Without this path the
    // user would need to push every sideloaded ROM through the lockfile
    // tool just to launch it.

    /**
     * Heuristic: a "real" ROM zip usually carries 2+ entries with
     * MAME / Kawaks / libretro file extensions (`.bin`, `.rom`, `.c1`,
     * `.sfx`, etc.) — as opposed to an MGS1 lockfile which always has
     * exactly one entry (`MGS1` header inside). Returns false for
     * single-entry zips so a corrupt MGS1 ciphertext doesn't get
     * pass-through'd into the runner and silently fail there.
     */
    private fun looksLikeMultiEntryRom(zip: File): Boolean = try {
        java.util.zip.ZipFile(zip).use { zf ->
            val entries = zf.entries()
            var count = 0
            while (entries.hasMoreElements()) {
                val e = entries.nextElement()
                if (e.isDirectory) continue
                count++
                if (count >= 2) return true
            }
            false
        }
    } catch (_: Throwable) {
        false
    }

    /**
     * Copy an unencrypted ROM zip verbatim into the cache directory
     * and return the cache path. Preserves any BIOS file already
     * living in the cache so the runner can find it next to the game.
     *
     * MAME layout requirement: the libretro MAME core derives the
     * *system* name from the content's PARENT directory and the game
     * (driver) name from the file name. A ROM sitting directly in
     * `rom_cache/` therefore parses as system `rom_cache` and boot fails
     * with `Unknown system 'rom_cache'`. Arcade content must live in a
     * folder named after the system — `rom_cache/mame/<driver>.zip` —
     * exactly like RetroArch's `downloads/mame/` convention. FBA-2012
     * keeps the flat layout because it wants the NeoGeo BIOS in the
     * *same* directory as the game zip.
     */
    private fun passThroughPlainZip(filesDir: File, lockedPath: File, coreId: String?): File {
        val cd = if (coreId == "mame") {
            File(cacheDir(filesDir), "mame").apply { mkdirs() }
        } else {
            cacheDir(filesDir)
        }
        val rawStem = lockedPath.nameWithoutExtension.ifBlank { "rom" }
        val safeStem = rawStem.lowercase()
            .replace(Regex("\\s+"), "")
            .replace(Regex("[^a-z0-9_]"), "")
            .ifBlank { "rom_${System.currentTimeMillis()}" }
        val out = File(cd, "$safeStem.zip")
        // Guard against a self-copy: when the source already lives at the exact
        // cache destination (e.g. a ROM sideloaded straight into
        // rom_cache/mame), opening the output stream would truncate the file
        // before the input stream finishes reading — destroying the very bytes
        // we are about to load. In that case the cached file is already
        // materialised; return it untouched.
        if (out.canonicalPath == lockedPath.canonicalPath) {
            Log.i(TAG, "pass-through no-op (source already at dest): ${out.path}")
            return out
        }
        lockedPath.inputStream().use { ins -> out.outputStream().use { os -> ins.copyTo(os) } }
        Log.i(TAG, "pass-through ${lockedPath.path} → ${out.path} (${out.length()} bytes)")
        return out
    }

    /**
     * Copy every other `.zip` in [gameZip]'s library folder into [destDir]
     * (the MAME `rom_cache/mame` directory). MAME scans the content's parent
     * directory for ROMs, so a clone that needs its parent set (e.g. `1943j`
     * → `1943`) only boots when that parent zip is present there. We only copy
     * sibling zips the user already imported; unrelated files are ignored by
     * MAME. Idempotent: skips a sibling already copied with the same length.
     */
    private fun gatherSiblingRoms(filesDir: File, gameZip: File, destDir: File) {
        val srcDir = gameZip.parentFile ?: return
        if (!srcDir.exists() || !srcDir.isDirectory) return
        try {
            // Never copy a sibling that is a *system BIOS* set (e.g. the stray
            // `neogeo.zip` that ships inside some collections with only 3 of its
            // members): MAME also scans its rompath, and a truncated BIOS would
            // shadow the authoritative one under filesDir/system/mame/roms and
            // make every NeoGeo game fail with a missing-member error.
            srcDir.listFiles { f ->
                f.isFile && f.extension.equals("zip", true) &&
                    f.name != gameZip.name &&
                    !f.name.equals("neogeo.zip", ignoreCase = true)
            }?.forEach { src ->
                val dst = File(destDir, src.name)
                if (!dst.exists() || dst.length() != src.length()) {
                    src.inputStream().use { ins -> dst.outputStream().use { os -> ins.copyTo(os) } }
                    Log.i(TAG, "gathered sibling rom ${src.name} → ${dst.path}")
                }
            }
        } catch (e: Throwable) {
            Log.w(TAG, "gatherSiblingRoms failed: ${e.message}")
        }
    }

    /**
     * Names of BIOS bundles that have to be mirrored into the per-core lookup
     * directories before every arcade launch. Mirrors `SystemFiles.requiredBios`
     * in `app/lib/system_files.dart`; the two lists must stay in lockstep so
     * the missing-file guidance dialog and the on-launch staging stay
     * consistent. The user supplies these blobs from their own legitimate
     * copies — the app never ships them.
     *
     * - `neogeo.zip` is required by every NeoGeo title for FBA-2012 / FBNeo,
     *   and the libretro MAME core falls back to it for several drivers.
     * - `qsound.zip` holds `dl-1425.bin`, the Q-Sound BIOS the libretro MAME
     *   core needs for every CPS-1 / CPS-2 game (1944, sf2ce, samsho2, msh,
     *   …). FBA-2012 / FBNeo ship their own QSound emulation and never look
     *   up the BIOS, so `stageOneArcadeBios` simply finds no source under
     *   `system/qsound.zip` for those cores and returns — no copy, no log.
     */
    private val ARCADE_BIOS_NAMES = listOf("neogeo.zip", "qsound.zip", "qsound_hle.zip", "pgm.zip")

    /**
     * For every arcade-core launch, walk [ARCADE_BIOS_NAMES] and make sure
     * each one lives in every directory a core might look. FBA-2012 / FBNeo
     * want the BIOS flat in the rom cache (next to the game); libretro MAME
     * scans `<content_dir>` (`rom_cache/mame`) AND
     * `<system_dir>/mame/roms`, so we stage the file in both.
     *
     * The source for each name is whichever system location the user dropped
     * it into — root (`system/<name>`) for fba-style imports, or
     * `system/mame/roms/<name>` when the MAME pipeline landed it there.
     * We compare length + CRC32 so an old WinKawaks-style 3-file subset
     * never shadows a freshly bundled full BIOS.
     */
    private fun ensureArcadeBiosInRomCache(
        filesDir: File,
        lockedPath: File,
        coreId: String?
    ) {
        val arcadeCore = coreId == "fbalpha2012" || coreId == "fbneo" || coreId == "mame"
        if (!arcadeCore) return
        for (name in ARCADE_BIOS_NAMES) {
            stageOneArcadeBios(filesDir, name, coreId)
        }
    }

    private fun stageOneArcadeBios(filesDir: File, name: String, coreId: String?) {
        // Authoritative source: prefer the root (where importBios writes it),
        // fall back to the MAME per-core subdir (where a previous run may
        // have staged it). Case-insensitive: we test both with lowercase
        // and accept the first match.
        val candidates = listOf(
            File(filesDir, "system/$name"),
            File(filesDir, "system/mame/roms/$name")
        )
        val src = candidates.firstOrNull { it.exists() } ?: run {
            // Don't spam the log for every absent BIOS on every launch —
            // a CPS-1 game doesn't need a neogeo BIOS, and most users won't
            // have every BIOS on the device. Quietly skip.
            return
        }
        val targets = if (coreId == "mame") {
            listOf(
                File(cacheDir(filesDir), "mame/$name").apply { parentFile?.mkdirs() },
                File(filesDir, "system/mame/roms/$name").apply { parentFile?.mkdirs() }
            )
        } else {
            listOf(File(cacheDir(filesDir), name))
        }
        for (target in targets) {
            if (target.exists() && target.length() == src.length() &&
                fileCrc32(target) == fileCrc32(src)
            ) {
                Log.i(TAG, "$name BIOS up to date at ${target.path} (${target.length()} bytes)")
                continue
            }
            try {
                src.inputStream().use { ins -> target.outputStream().use { os -> ins.copyTo(os) } }
                Log.i(TAG, "staged $name BIOS ${src.length()} → ${target.path}")
            } catch (e: Throwable) {
                Log.w(TAG, "failed to stage $name BIOS → ${target.path}: ${e.message}")
            }
        }
    }

    /**
     * Merge the bundled NeoGeo BIOS members into a materialised arcade game
     * zip so drivers that carry the BIOS *inside the game set* — bootleg PCB
     * boards such as `kf2k3pcb`, which FBA-2012 loads without an implicit
     * `Archive: neogeo` parent — find sfix.sfix / 000-lo.lo / sm1.sm1 / … by
     * CRC. The core looks entries up by CRC (the embedded name is only a
     * hint), so members already present are matched on CRC and never
     * duplicated, and BIOS members unrelated to the game (CPS sets) are
     * simply ignored. The only cost is ~1 MB inside the single-session
     * rom_cache, which is wiped on the next launch.
     *
     * No-op for non-arcade cores, a missing system BIOS, or a game zip that
     * already carries every BIOS member. The archive is rebuilt to a sibling
     * temp file (STORED, streamed so a 90+ MB set doesn't hit the heap) and
     * swapped in with rollback; on any failure the original is left intact.
     */
    private fun mergeNeogeoBiosIntoGameZip(
        filesDir: File,
        gameZip: File,
        coreId: String?
    ) {
        val arcadeCore = coreId == "fbalpha2012" || coreId == "fbneo" || coreId == "mame"
        if (!arcadeCore || !gameZip.exists()) return
        val bios = File(filesDir, "system/neogeo.zip")
        if (!bios.exists()) return
        try {
            val presentCrc = HashSet<Long>()
            val presentName = HashSet<String>()
            ZipFile(gameZip).use { zf ->
                val it = zf.entries()
                while (it.hasMoreElements()) {
                    val e = it.nextElement()
                    if (e.isDirectory) continue
                    presentCrc.add(e.crc)
                    presentName.add(e.name.lowercase())
                }
            }
            // Collect only the BIOS members the game lacks (by CRC); a fully
            // self-contained set then skips the rewrite altogether.
            val toAdd = ArrayList<Pair<String, ByteArray>>()
            ZipFile(bios).use { bf ->
                val it = bf.entries()
                while (it.hasMoreElements()) {
                    val e = it.nextElement()
                    if (e.isDirectory || presentCrc.contains(e.crc)) continue
                    var name = e.name
                    if (presentName.contains(name.lowercase())) name = "mgbios_$name"
                    toAdd.add(name to bf.getInputStream(e).use { s -> s.readBytes() })
                }
            }
            if (toAdd.isEmpty()) {
                Log.i(TAG, "game zip already carries neogeo BIOS: ${gameZip.name}")
                return
            }
            val parent = gameZip.parentFile!!
            val tmp = File(parent, gameZip.name + ".biostmp")
            val bak = File(parent, gameZip.name + ".biosbak")
            if (tmp.exists()) tmp.delete()
            if (bak.exists()) bak.delete()
            ZipOutputStream(tmp.outputStream().buffered()).use { out ->
                // Re-emit the game's own entries STORED, streaming the bytes so
                // a large ROM set isn't buffered wholly in the heap. The
                // central directory already carries each entry's size + CRC.
                ZipFile(gameZip).use { zf ->
                    val it = zf.entries()
                    while (it.hasMoreElements()) {
                        val e = it.nextElement()
                        val ne = ZipEntry(e.name)
                        ne.method = ZipEntry.STORED
                        ne.size = e.size
                        ne.compressedSize = e.size
                        ne.crc = e.crc
                        out.putNextEntry(ne)
                        if (!e.isDirectory) zf.getInputStream(e).use { s -> s.copyTo(out) }
                        out.closeEntry()
                    }
                }
                for ((name, bytes) in toAdd) {
                    val crc = java.util.zip.CRC32().apply { update(bytes) }.value
                    val ne = ZipEntry(name)
                    ne.method = ZipEntry.STORED
                    ne.size = bytes.size.toLong()
                    ne.compressedSize = bytes.size.toLong()
                    ne.crc = crc
                    out.putNextEntry(ne)
                    out.write(bytes)
                    out.closeEntry()
                }
            }
            // Swap with rollback so a failed rename can never leave the game
            // zip missing.
            if (!gameZip.renameTo(bak)) { tmp.delete(); return }
            if (!tmp.renameTo(gameZip)) {
                bak.renameTo(gameZip)
                return
            }
            bak.delete()
            Log.i(TAG, "merged ${toAdd.size} neogeo BIOS members into ${gameZip.name}")
        } catch (e: Throwable) {
            Log.w(TAG, "merge neogeo BIOS into ${gameZip.name} failed: ${e.message}")
        }
    }

    /** CRC32 of a file's full contents; 0 when the file can't be read. */
    private fun fileCrc32(f: File): Long = try {
        val crc = java.util.zip.CRC32()
        f.inputStream().use { ins ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = ins.read(buf)
                if (n <= 0) break
                crc.update(buf, 0, n)
            }
        }
        crc.value
    } catch (_: Throwable) {
        0L
    }
}