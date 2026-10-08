package dev.matebridge.client.stream

/**
 * T-243: panel rate switches for `MB/render ev=stats hz_switches=`. Fed the debounced `display_rate` reports; a report
 * that differs from the previous one is a switch. [take] returns the count since the last take and resets it; the last
 * rate is kept across windows. [restart] forgets the last rate (a new vsync run: its first report is not a switch).
 */
class HzSwitchCounter {
    private var last = 0
    private var count = 0

    fun observe(hz: Int) {
        if (hz <= 0) return
        if (last != 0 && hz != last) count++
        last = hz
    }

    fun take(): Int = count.also { count = 0 }

    fun restart() { last = 0 }
}
