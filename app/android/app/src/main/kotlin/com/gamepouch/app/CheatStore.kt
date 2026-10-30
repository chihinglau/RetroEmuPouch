package com.retroemupouch.app

import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** A selectable value inside a [ChoiceCheat] (e.g. 装备=剑 → its code). */
data class CheatOption(val label: String, val code: String)

/**
 * A user-facing cheat command. Commands are authored on the PC manager and
 * synced to the phone; the emulator never asks the player to type codes.
 */
sealed class CheatCommand {
    abstract var name: String

    /** The core code currently activated by this command, or null when off. */
    abstract val activeCode: String?

    abstract fun toJson(): JSONObject

    /** Simple on/off command, e.g. 「无限生命」. */
    class Switch(
        override var name: String,
        val code: String,
        var enabled: Boolean = false,
    ) : CheatCommand() {
        override val activeCode: String? get() = if (enabled) code else null
        override fun toJson() = JSONObject()
            .put("name", name).put("kind", "switch")
            .put("code", code).put("enabled", enabled)
    }

    /**
     * Value/equipment picker, e.g. 「武力值」= 10/50/100 or 「装备」= 剑/枪.
     * [selected] is the active option index, -1 = off (no code applied).
     */
    class Choice(
        override var name: String,
        val options: MutableList<CheatOption>,
        var selected: Int = -1,
    ) : CheatCommand() {
        override val activeCode: String?
            get() = options.getOrNull(selected)?.code

        override fun toJson() = JSONObject()
            .put("name", name).put("kind", "choice")
            .put("selected", selected)
            .put("options", JSONArray().apply {
                options.forEach { put(JSONObject().put("label", it.label).put("code", it.code)) }
            })
    }

    companion object {
        fun fromJson(o: JSONObject): CheatCommand? {
            val name = o.optString("name").trim().ifEmpty { o.optString("code") }
            val kind = o.optString("kind").ifEmpty {
                // Legacy entries (v1.2.0) were always simple switches.
                if (o.has("code")) "switch" else ""
            }
            return when (kind) {
                "choice" -> {
                    val arr = o.optJSONArray("options") ?: return null
                    val opts = (0 until arr.length()).mapNotNull { i ->
                        val p = arr.optJSONObject(i) ?: return@mapNotNull null
                        val code = p.optString("code").trim()
                        if (code.isEmpty()) return@mapNotNull null
                        CheatOption(
                            p.optString("label").trim().ifEmpty { code }, code)
                    }.toMutableList()
                    if (opts.isEmpty()) return null
                    val sel = o.optInt("selected", -1).let { if (it in opts.indices) it else -1 }
                    Choice(name, opts, sel)
                }
                "switch" -> {
                    val code = o.optString("code").trim()
                    if (code.isEmpty()) null
                    else Switch(name, code, o.optBoolean("enabled", false))
                }
                else -> null
            }
        }
    }
}

/**
 * Per-game cheat command persistence.
 *
 * Storage:
 *   <filesDir>/library/cheats.json        — PC/ADB-synced or authored in-game
 *   <filesDir>/library/cloud_cheats.json  — LAN cloud sync snapshot
 *   both shaped { "version": 1, "byCrc": { "<CRC32-8HEX>": [ <command>, ... ] } }
 *
 * Commands are authored on the PC manager; the app only flips switches /
 * picks options and writes that state back. A non-empty local entry wins for
 * its CRC (it carries the player's toggle state); otherwise the cloud
 * snapshot is used — mirroring RomLibrary._applyCheats on the Dart side.
 */
object CheatStore {
    private const val DIR = "library"
    private const val FILE = "cheats.json"
    private const val CLOUD_FILE = "cloud_cheats.json"

    /** Codes that should currently be active for [commands]. */
    fun activeCodes(commands: List<CheatCommand>): List<String> =
        commands.mapNotNull { it.activeCode }

    /** Resolves the unsigned 8-hex CRC32 key for a ROM relative path. */
    fun crcKey(filesDir: File, romRel: String): String? {
        val idx = File(filesDir, "rom_index.json")
        if (!idx.exists()) return null
        return try {
            val arr = org.json.JSONArray(idx.readText())
            for (i in 0 until arr.length()) {
                val o = arr.optJSONObject(i) ?: continue
                if (o.optString("relativePath") == romRel) {
                    val v = o.optLong("crc32", 0L)
                    // Stored as a signed 32-bit int by the Dart side.
                    val u = if (v in 0..0xFFFFFFFFL) v else (v and 0xFFFFFFFFL)
                    return u.toString(16).padStart(8, '0').uppercase()
                }
            }
            null
        } catch (_: Exception) {
            null
        }
    }

    /** Loads commands for [romRel]; empty list when none / unreadable. */
    fun load(filesDir: File, romRel: String): MutableList<CheatCommand> {
        val key = crcKey(filesDir, romRel) ?: return mutableListOf()
        // Local (PC/ADB-synced or toggled in-game) wins when it actually has
        // commands; an empty/absent entry falls through to the cloud snapshot.
        readCommands(File(filesDir, "$DIR/$FILE"), key)?.let { if (it.isNotEmpty()) return it }
        readCommands(File(filesDir, "$DIR/$CLOUD_FILE"), key)?.let { return it }
        return mutableListOf()
    }

    /**
     * Parses the command array for [key] from one snapshot file.
     * Returns null when the file/key is absent or unreadable, an empty list
     * for a present-but-empty array.
     */
    private fun readCommands(f: File, key: String): MutableList<CheatCommand>? {
        if (!f.exists()) return null
        return try {
            val byCrc = JSONObject(f.readText()).optJSONObject("byCrc") ?: return null
            val arr = byCrc.optJSONArray(key) ?: return null
            (0 until arr.length()).mapNotNull { i ->
                arr.optJSONObject(i)?.let(CheatCommand::fromJson)
            }.toMutableList()
        } catch (_: Exception) {
            null
        }
    }

    /** Replaces commands for [romRel] and atomically rewrites the store. */
    fun save(filesDir: File, romRel: String, commands: List<CheatCommand>) {
        val key = crcKey(filesDir, romRel) ?: return
        val dir = File(filesDir, DIR).apply { mkdirs() }
        val f = File(dir, FILE)
        val root = if (f.exists()) {
            try { JSONObject(f.readText()) } catch (_: Exception) { JSONObject() }
        } else JSONObject()
        var byCrc = root.optJSONObject("byCrc")
        if (byCrc == null) {
            byCrc = JSONObject()
            root.put("version", 1)
            root.put("byCrc", byCrc)
        }
        val arr = JSONArray()
        commands.forEach { arr.put(it.toJson()) }
        byCrc.put(key, arr)
        val tmp = File(dir, "$FILE.tmp")
        tmp.writeText(root.toString(2))
        tmp.renameTo(f)
    }
}
