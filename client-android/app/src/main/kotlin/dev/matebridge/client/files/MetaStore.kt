package dev.matebridge.client.files

/**
 * Finder metadata files (`._*` AppleDouble, `.DS_Store`) kept in memory instead of the tablet's shared storage, so the
 * gallery and file apps never show them (T-135 review). Keys are storage paths (`dir/sub/._name`, "" separators by `/`).
 * Bounded: at most [maxEntries] files of at most [maxEntryBytes] each and [maxTotalBytes] together; the least recently
 * used entries go first. A file larger than [maxEntryBytes] is not kept (Finder then just finds no metadata).
 * Lives as long as one server run. Thread-safe.
 */
class MetaStore(
    private val maxEntries: Int = 1024,
    val maxEntryBytes: Int = 512 * 1024,
    private val maxTotalBytes: Long = 8L * 1024 * 1024,
) {
    class Entry(val data: ByteArray, val modifiedMs: Long)

    private val map = LinkedHashMap<String, Entry>(64, 0.75f, true)
    private var total = 0L

    @Synchronized fun get(key: String): Entry? = map[key]

    @Synchronized fun contains(key: String) = map.containsKey(key)

    /** Stores [data]; false when it is too large to keep (any older entry under [key] is removed then). */
    @Synchronized fun put(key: String, data: ByteArray, modifiedMs: Long): Boolean {
        remove(key)
        if (data.size > maxEntryBytes) return false
        map[key] = Entry(data, modifiedMs)
        total += data.size
        trim()
        return true
    }

    @Synchronized fun remove(key: String): Boolean {
        val old = map.remove(key) ?: return false
        total -= old.data.size
        return true
    }

    /** Entries directly inside directory [dirKey] ("" = the storage root), as (name, entry). */
    @Synchronized fun list(dirKey: String): List<Pair<String, Entry>> {
        val prefix = if (dirKey.isEmpty()) "" else "$dirKey/"
        return map.entries.filter { (k, _) -> k.startsWith(prefix) && k.indexOf('/', prefix.length) < 0 }
            .map { (k, v) -> k.substring(prefix.length) to v }
    }

    /** Drops every entry below directory [dirKey] (it was deleted). */
    @Synchronized fun removeUnder(dirKey: String) {
        for (k in keysUnder(dirKey)) remove(k)
    }

    /** Re-keys every entry below [from] to below [to] (a directory was moved), or copies them when [copy]. */
    @Synchronized fun moveUnder(from: String, to: String, copy: Boolean) {
        removeUnder(to)
        for (k in keysUnder(from)) {
            val e = map[k] ?: continue
            if (!copy) remove(k)
            put(to + k.substring(from.length), e.data, e.modifiedMs)
        }
    }

    @Synchronized fun size() = map.size

    private fun keysUnder(dirKey: String): List<String> = map.keys.filter { it.startsWith("$dirKey/") }

    private fun trim() {
        val it = map.entries.iterator()
        while ((map.size > maxEntries || total > maxTotalBytes) && it.hasNext()) {
            total -= it.next().value.data.size
            it.remove()
        }
    }

    companion object {
        fun isMetaName(name: String) = name.startsWith("._") || name == ".DS_Store"

        fun key(segments: List<String>) = segments.joinToString("/")
    }
}
