package com.retroemupouch.app

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Per-slot macro spec as authored by the user: a label shown on the pill
 * and a compact script that compiles down to the same per-frame retropad
 * masks `nativePlayMacro` already consumes.
 *
 * Persistence happens in [SpecialMovesStore]; the model class stays pure
 * so the editor UI (and tests) can construct / serialise it freely.
 */
data class MoveSpec(val label: String, val script: String) {
    fun toJson() = JSONObject().put("label", label).put("script", script)

    companion object {
        fun fromJson(o: JSONObject): MoveSpec = MoveSpec(
            label = o.optString("label", ""),
            script = o.optString("script", "")
        )
    }
}

/** Preset profile — a named set of [maxSlots] slots. */
data class SpecialMoveProfile(
    val id: String,
    val label: String,
    val gameHints: List<String>,
    val moves: List<MoveSpec>
) {
    fun toJson(): JSONObject {
        val arr = JSONArray()
        moves.forEach { arr.put(it.toJson()) }
        return JSONObject()
            .put("label", label)
            .put("gameHints", JSONArray(gameHints))
            .put("moves", arr)
    }

    companion object {
        fun fromJson(id: String, o: JSONObject): SpecialMoveProfile {
            val moves = mutableListOf<MoveSpec>()
            val arr = o.optJSONArray("moves")
            if (arr != null) {
                for (i in 0 until arr.length()) {
                    val mo = arr.optJSONObject(i) ?: continue
                    moves.add(MoveSpec.fromJson(mo))
                }
            }
            val hints = mutableListOf<String>()
            val ha = o.optJSONArray("gameHints")
            if (ha != null) {
                for (i in 0 until ha.length()) hints.add(ha.optString(i))
            }
            return SpecialMoveProfile(
                id = id,
                label = o.optString("label", id),
                gameHints = hints,
                moves = moves
            )
        }
    }
}

/** Top-level config: version + active profile id + profile map. */
data class SpecialMovesConfig(
    val version: Int,
    val activeProfileId: String,
    val profiles: Map<String, SpecialMoveProfile>
) {
    fun activeProfile(): SpecialMoveProfile =
        profiles[activeProfileId] ?: profiles.values.first()

    fun toJsonString(): String {
        val root = JSONObject()
        root.put("version", version)
        root.put("activeProfileId", activeProfileId)
        val pmap = JSONObject()
        profiles.forEach { (k, v) -> pmap.put(k, v.toJson()) }
        root.put("profiles", pmap)
        return root.toString(2)
    }

    companion object {
        fun fromJsonString(s: String): SpecialMovesConfig {
            val root = JSONObject(s)
            val pmap = root.optJSONObject("profiles") ?: JSONObject()
            val profiles = linkedMapOf<String, SpecialMoveProfile>()
            val keys = pmap.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                profiles[k] = SpecialMoveProfile.fromJson(k, pmap.getJSONObject(k))
            }
            val active = root.optString("activeProfileId", "")
                .ifEmpty { profiles.keys.firstOrNull() ?: "" }
            return SpecialMovesConfig(
                version = root.optInt("version", 1),
                activeProfileId = active,
                profiles = profiles
            )
        }
    }
}

/**
 * Compiles a user-authored script into the per-frame retropad mask
 * sequence. Mirrors the Dart side in `lib/data/play/special_moves.dart`
 * — same grammar, same framesPerStep — so the editor and the runtime
 * stay in lockstep regardless of which side validates a script.
 *
 * Grammar (whitespace ignored):
 *   script     := segments
 *   segments   := segment (',' segment)* ('+' buttons)?
 *   segment    := digit+            // numpad digits, e.g. "236"
 *   buttons    := button ('+' button)*
 *   button     := 'P' | 'H' | 'L' | 'K' (case-insensitive)
 *
 * Each digit holds for [framesPerStep] frames (~50 ms — the digital d-pad
 * cadence VirtualPadView uses today). When the trailing `+buttons` group
 * is present, those bits are OR'd onto the last motion frame and held for
 * another [framesPerStep] frames so the attack lands after the motion.
 */
object ScriptCompiler {
    const val framesPerStep = 3

    // VirtualPadView constants: BUTTON_UP=1<<4, BUTTON_DOWN=1<<5,
    // BUTTON_LEFT=1<<6, BUTTON_RIGHT=1<<7.
    private const val UP = 1 shl 4
    private const val DN = 1 shl 5
    private const val LF = 1 shl 6
    private const val RT = 1 shl 7
    private const val BUTTON_B = 1 shl 0  // P (LP) — NeoGeo candy
    private const val BUTTON_Y = 1 shl 1  // H (HP)
    private const val BUTTON_A = 1 shl 8  // L (LK)
    private const val BUTTON_X = 1 shl 9  // K (HK)

    // Standard numpad direction encoding used by the fighting-game
    // community (the "numpad notation" KOF / SF tutorials use):
    //   7=↖  8=↑  9=↗
    //   4=←  5=中  6=→
    //   1=↙  2=↓  3=↘
    // Mask values mirror VirtualPadView's BUTTON_* bits so the compiled
    // sequence can be fed straight into nativePlayMacro.
    private val dirMasks = mapOf(
        '1' to (DN or LF), // ↙
        '2' to DN,         // ↓
        '3' to (DN or RT), // ↘
        '4' to LF,         // ←
        '5' to 0,          // 中 (neutral)
        '6' to RT,         // →
        '7' to (UP or LF), // ↖
        '8' to UP,         // ↑
        '9' to (UP or RT)  // ↗
    )
    private val buttonMasks = mapOf(
        'P' to BUTTON_B,
        'H' to BUTTON_Y,
        'L' to BUTTON_A,
        'K' to BUTTON_X
    )

    class CompileException(message: String) : RuntimeException(message)

    /**
     * Returns the per-frame masks. Throws [CompileException] on bad input.
     * Empty / whitespace-only scripts return an empty array (= no-op
     * macro; tapping the slot does nothing).
     */
    fun compile(script: String): IntArray {
        val s = script.replace(Regex("\\s+"), "")
        if (s.isEmpty()) return IntArray(0)
        val parts = s.split('+')
        if (parts.isEmpty()) return IntArray(0)
        // `+` is the only separator between motion chunks and the trailing
        // button group. When no `+` is present, the whole script is motion
        // — unconditionally peeling the last chunk as buttons would route
        // pure-direction scripts like "236" into the button parser and fail.
        val hasButton = parts.size > 1
        val tail = if (hasButton) parts.last() else ""
        val segments = if (hasButton) parts.dropLast(1) else parts
        val out = ArrayList<Int>()
        for (seg in segments) {
            for (j in seg.indices) {
                val d = dirMasks[seg[j]]
                    ?: throw CompileException(
                        "未知的方向字符 \"${seg[j]}\" — 仅支持数字 1-9（小键盘方向）")
                repeat(framesPerStep) { out.add(d) }
            }
        }
        if (tail.isNotEmpty()) {
            val tailMasks = ArrayList<Int>()
            for (i in tail.indices) {
                val ch = tail[i].uppercaseChar()
                val b = buttonMasks[ch]
                    ?: throw CompileException(
                        "未知的按键 \"${tail[i]}\" — 仅支持 P/H/L/K（轻拳/重拳/轻踢/重踢）")
                repeat(framesPerStep) { tailMasks.add(b) }
            }
            val base = if (out.isEmpty()) 0 else out.last()
            for (m in tailMasks) out.add(base or m)
        }
        return out.toIntArray()
    }

    /** Returns null on success, or a human-readable error message. */
    fun validate(script: String): String? = try {
        compile(script); null
    } catch (e: CompileException) {
        e.message
    }
}

/**
 * Persistence + assets fallback for the special-moves configuration.
 *
 * On-disk location: `<filesDir>/library/moves.json` (sibling to the
 * cheat JSON). Atomic write via `.tmp` + `rename`, mirroring
 * [CheatStore] so a crash mid-write never leaves a half-baked file
 * behind.
 *
 * When the file is missing / unreadable / invalid the loaders return
 * the bundled `assets/moves_presets.json` instead. The native side keeps
 * running even on a first launch with no user customisation.
 */
object SpecialMovesStore {
    private const val DIR = "library"
    private const val FILE = "moves.json"
    private const val ASSET = "moves_presets.json"

    fun file(filesDir: File): File = File(filesDir, "$DIR/$FILE")

    /**
     * Loads the user config, falling back to the bundled default asset
     * when the on-disk file is missing / corrupt. Never returns null —
     * the view can rely on at least one profile with entries.
     */
    fun load(filesDir: File, context: Context): SpecialMovesConfig {
        val f = file(filesDir)
        try {
            if (f.exists()) {
                val s = f.readText()
                if (s.isNotBlank()) return SpecialMovesConfig.fromJsonString(s)
            }
        } catch (_: Exception) {
            // fall through to the asset default
        }
        return loadDefaults(context)
    }

    /** Bundled default JSON shipped inside the APK (`assets/moves_presets.json`). */
    fun loadDefaults(context: Context): SpecialMovesConfig = try {
        val s = context.assets.open(ASSET).bufferedReader().use { it.readText() }
        SpecialMovesConfig.fromJsonString(s)
    } catch (e: Exception) {
        android.util.Log.w("SpecialMoves", "default asset missing: ${e.message}")
        // Last-resort: empty config so the view still loads — it will
        // simply render an empty palette instead of crashing.
        SpecialMovesConfig(version = 1, activeProfileId = "", profiles = emptyMap())
    }

    /**
     * Atomic write: dump the JSON to `moves.json.tmp` then `renameTo` so
     * a crash mid-write never overwrites the live file. Matches the
     * CheatStore convention.
     */
    fun save(filesDir: File, cfg: SpecialMovesConfig) {
        val dir = File(filesDir, DIR).apply { mkdirs() }
        val f = File(dir, FILE)
        val tmp = File(dir, "$FILE.tmp")
        tmp.writeText(cfg.toJsonString())
        tmp.renameTo(f)
    }
}