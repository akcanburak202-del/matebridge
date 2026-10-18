package dev.matebridge.client.settings

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.Switch
import android.widget.TextView
import dev.matebridge.client.R

/**
 * Renders [SettingsCatalog] sections into [container] with plain Views (decision 0004: no Compose). The connect panel
 * and the in-stream side panel each own one instance over the same [SettingsHost]; [onChanged] runs after every user
 * action so the activity can refresh both. Main thread only.
 *
 * T-352 look: one heading per section; Choice = segmented control (rows of at most four segments, so no option is ever
 * cut off); Toggle = label left, Switch right; Stepper = label left, small "- value +" right; Info = small grey text
 * under the control it belongs to; Actions (Bağlantıyı kes, Bu Mac'i unut, Varsayılanlara dön) are collected into a
 * quiet text-button group at the very end. The catalog is untouched: same items, keys and hiding rules.
 */
class SettingsViews(
    private val context: Context,
    private val container: LinearLayout,
    sections: List<SettingsSection>,
    private val onChanged: () -> Unit,
) {
    private val refreshers = ArrayList<() -> Unit>()
    private val density = context.resources.displayMetrics.density

    init {
        val actions = ArrayList<SettingItem.Action>()
        var resetHint: SettingItem.Info? = null
        for (s in sections) {
            container.addView(header(s.title), rowParams(top = 32, bottom = 8))
            for (item in s.items) {
                when {
                    item is SettingItem.Action && !item.inline -> actions += item
                    item is SettingItem.Info && item.key == "reset_hint" -> resetHint = item // sits under "Varsayılanlara dön"
                    else -> container.addView(build(item, s.title), rowParams(top = if (item is SettingItem.Info) 4 else 8))
                }
            }
        }
        if (actions.isNotEmpty()) {
            container.addView(divider(), rowParams(top = 32, height = dp(1)))
            for (a in actions) {
                container.addView(actionRow(a), rowParams(top = 8))
                if (a.key == "reset_defaults") resetHint?.let { container.addView(build(it, ""), rowParams(top = 0)) }
            }
        }
        refresh()
    }

    /** Re-reads every label and selection from the host. */
    fun refresh() = refreshers.forEach { it() }

    private fun build(item: SettingItem, sectionTitle: String): View = when (item) {
        is SettingItem.Choice -> choice(item, sectionTitle)
        is SettingItem.Toggle -> toggle(item)
        is SettingItem.Stepper -> stepper(item)
        is SettingItem.Action -> actionRow(item)
        is SettingItem.Info -> text("", SECONDARY_SP, color(R.color.mb_text_secondary)).also { t ->
            refreshers += {
                t.visibility = if (item.hidden()) View.GONE else View.VISIBLE // T-238/T-280: e.g. "Uygulanan: HDR10" in Çizim
                t.text = item.text()
            }
        }
    }

    private fun choice(item: SettingItem.Choice, sectionTitle: String): View {
        val col = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        // T-352: "Bağlantı" under the heading "Bağlantı" said the same thing twice.
        val title = if (item.title.equals(sectionTitle, ignoreCase = true)) null else text(item.titleText(), LABEL_SP, color(R.color.mb_text))
        title?.let { col.addView(it, rowParams(bottom = 8)) }
        val n = item.options.size
        val maxLen = item.options.maxOf { it.label.length }
        val perRow = when {
            n <= 3 -> n
            n == 4 && maxLen <= 11 -> 4
            else -> 3
        }
        val segments = ArrayList<TextView>(n)
        for (rowStart in 0 until n step perRow) {
            val count = minOf(perRow, n - rowStart)
            val outer = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; weightSum = perRow.toFloat() }
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                background = GradientDrawable().apply { cornerRadius = dp(RADIUS_DP).toFloat(); setStroke(dp(1), color(R.color.mb_outline)) }
                setPadding(dp(1), dp(1), dp(1), dp(1))
            }
            for (k in 0 until count) {
                val o = item.options[rowStart + k]
                if (k > 0) {
                    row.addView(
                        View(context).apply { setBackgroundColor(color(R.color.mb_outline)) },
                        LinearLayout.LayoutParams(dp(1), ViewGroup.LayoutParams.MATCH_PARENT),
                    )
                }
                val seg = segment(first = k == 0, last = k == count - 1).apply {
                    setOnClickListener { item.select(o.id); onChanged() }
                }
                segments += seg
                row.addView(seg, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
            }
            outer.addView(row, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, count.toFloat()))
            col.addView(outer, rowParams(top = if (rowStart == 0) 0 else 8))
        }
        refreshers += {
            col.visibility = if (item.hidden()) View.GONE else View.VISIBLE // T-223: e.g. "Kare hızı" in Çizim
            title?.text = item.titleText() // T-109: "(oyun modu)" comes and goes with game mode
            val enabled = item.enabled() // T-238: grey row, e.g. "HDR (Bu cihazda yok)"
            title?.setTextColor(color(if (enabled) R.color.mb_text else R.color.mb_disabled))
            val sel = item.selected()
            for ((i, b) in segments.withIndex()) {
                val o = item.options[i]
                val optionEnabled = enabled && o.enabled() // T-260: e.g. "Tam renk (Bu cihazda yok)"
                b.isEnabled = optionEnabled
                b.alpha = if (optionEnabled) 1f else DISABLED_ALPHA
                b.text = o.label // T-242: e.g. "Otomatik (60 Mbps)" inside a mode layer
                b.isSelected = o.id == sel
                b.setTextColor(color(if (o.id == sel) R.color.mb_on_accent else R.color.mb_text))
            }
        }
        return col
    }

    private fun toggle(item: SettingItem.Toggle): View {
        val label = text("", LABEL_SP, color(R.color.mb_text))
        val sw = Switch(context).apply {
            showText = false
            isClickable = false // the whole row is the touch target
            isFocusable = false
            thumbTintList = ColorStateList(
                arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
                intArrayOf(color(R.color.mb_on_accent), color(R.color.mb_text_secondary)),
            )
            trackTintList = ColorStateList(
                arrayOf(intArrayOf(android.R.attr.state_checked), intArrayOf()),
                intArrayOf(color(R.color.mb_accent), color(R.color.mb_outline)),
            )
        }
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(CONTROL_DP)
            setOnClickListener { item.set(!item.get()); onChanged() }
        }
        styleFocusable(row)
        row.addView(label, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).also { it.marginEnd = dp(16) })
        row.addView(sw)
        refreshers += {
            row.visibility = if (item.hidden()) View.GONE else View.VISIBLE // T-350
            label.text = item.title + item.marker()
            sw.isChecked = item.get()
        }
        return row
    }

    private fun stepper(item: SettingItem.Stepper): View {
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(CONTROL_DP)
        }
        val label = text(item.title, LABEL_SP, color(R.color.mb_text))
        val value = text("", LABEL_SP, color(R.color.mb_text)).apply { gravity = Gravity.CENTER; minWidth = dp(64) }
        row.addView(label, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).also { it.marginEnd = dp(16) })
        row.addView(smallButton("−") { item.dec() })
        row.addView(value)
        row.addView(smallButton("+") { item.inc() })
        refreshers += { value.text = item.value() }
        return row
    }

    private fun smallButton(label: String, action: () -> Unit): View {
        val box = LinearLayout(context).apply {
            background = GradientDrawable().apply { cornerRadius = dp(RADIUS_DP).toFloat(); setStroke(dp(1), color(R.color.mb_outline)) }
            setPadding(dp(1), dp(1), dp(1), dp(1))
        }
        val seg = segment(first = true, last = true).apply {
            text = label
            minWidth = dp(CONTROL_DP)
            setTextColor(color(R.color.mb_text))
            setOnClickListener { action(); onChanged() }
        }
        box.addView(seg, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, dp(CONTROL_DP - 4)))
        return box
    }

    /** A segment of a segmented control: transparent at rest, accent when [View.isSelected], white ring when focused. */
    private fun segment(first: Boolean, last: Boolean): TextView = TextView(context).apply {
        gravity = Gravity.CENTER
        textSize = 15f
        maxLines = 2
        minHeight = dp(CONTROL_DP - 4)
        setPadding(dp(8), dp(8), dp(8), dp(8))
        isClickable = true
        isFocusable = true
        defaultFocusHighlightEnabled = false
        val r = (dp(RADIUS_DP) - dp(1)).toFloat()
        val a = if (first) r else 0f
        val b = if (last) r else 0f
        val radii = floatArrayOf(a, a, b, b, b, b, a, a)
        fun shape(fill: Int, ring: Boolean) = GradientDrawable().apply {
            cornerRadii = radii
            setColor(fill)
            if (ring) setStroke(dp(2), color(R.color.mb_focus))
        }
        val sd = StateListDrawable()
        val clear = Color.TRANSPARENT
        sd.addState(intArrayOf(android.R.attr.state_focused, android.R.attr.state_selected), shape(color(R.color.mb_accent), true))
        sd.addState(intArrayOf(android.R.attr.state_focused), shape(clear, true))
        sd.addState(intArrayOf(android.R.attr.state_pressed, android.R.attr.state_selected), shape(color(R.color.mb_accent_pressed), false))
        sd.addState(intArrayOf(android.R.attr.state_pressed), shape(color(R.color.mb_pressed), false))
        sd.addState(intArrayOf(android.R.attr.state_selected), shape(color(R.color.mb_accent), false))
        sd.addState(intArrayOf(), shape(clear, false))
        background = sd
    }

    /** A quiet text button: no fill, pressed/focused feedback only. "Bu Mac'i unut" is reddish. */
    private fun actionRow(item: SettingItem.Action): View =
        text(item.title, LABEL_SP, color(if (item.key == "forget_host") R.color.mb_danger else R.color.mb_text)).apply {
            gravity = Gravity.CENTER_VERTICAL
            minHeight = dp(CONTROL_DP)
            setOnClickListener { item.run(); onChanged() }
            styleFocusable(this)
            if (item.inline) refreshers += { visibility = if (item.hidden()) View.GONE else View.VISIBLE } // T-357: e.g. only while the camera streams
        }

    private fun styleFocusable(v: View) {
        v.isClickable = true
        v.isFocusable = true
        v.defaultFocusHighlightEnabled = false // T-246 rule; the controls draw their own ring
        fun shape(fill: Int, ring: Boolean) = GradientDrawable().apply {
            cornerRadius = dp(RADIUS_DP).toFloat()
            setColor(fill)
            if (ring) setStroke(dp(2), color(R.color.mb_focus))
        }
        val sd = StateListDrawable()
        sd.addState(intArrayOf(android.R.attr.state_focused), shape(Color.TRANSPARENT, true))
        sd.addState(intArrayOf(android.R.attr.state_pressed), shape(color(R.color.mb_pressed), false))
        sd.addState(intArrayOf(), shape(Color.TRANSPARENT, false))
        v.background = sd
    }

    private fun divider() = View(context).apply { setBackgroundColor(color(R.color.mb_outline)) }

    private fun header(title: String) = text(title, LABEL_SP, color(R.color.mb_accent)).apply { setTypeface(typeface, Typeface.BOLD) }

    private fun text(s: String, sp: Float, color: Int) = TextView(context).apply {
        text = s
        textSize = sp
        setTextColor(color)
    }

    private fun color(id: Int) = context.getColor(id)

    private fun rowParams(top: Int = 0, bottom: Int = 0, height: Int = ViewGroup.LayoutParams.WRAP_CONTENT) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, height).also {
            it.topMargin = dp(top)
            it.bottomMargin = dp(bottom)
        }

    private fun dp(v: Int) = (v * density).toInt()

    private companion object {
        const val LABEL_SP = 16f
        const val SECONDARY_SP = 13f
        const val CONTROL_DP = 48
        const val RADIUS_DP = 8
        const val DISABLED_ALPHA = 0.4f
    }
}

/**
 * T-107: gives a button an explicit color set ([SettingsButtonPalette]) instead of the system theme's light
 * background. Selection is driven by [View.isSelected]; pressing shows a darker/lighter shade. Used by the trust
 * buttons on the connect screen.
 */
internal fun styleSettingsButton(b: Button) {
    val density = b.resources.displayMetrics.density
    fun dp(v: Int) = (v * density).toInt()
    val bg = StateListDrawable()
    for ((selected, pressed) in SettingsButtonPalette.stateOrder) {
        val states = ArrayList<Int>(2)
        if (pressed) states += android.R.attr.state_pressed
        if (selected) states += android.R.attr.state_selected
        bg.addState(
            states.toIntArray(),
            GradientDrawable().apply {
                cornerRadius = dp(8).toFloat()
                setColor(SettingsButtonPalette.colorFor(selected, pressed))
            },
        )
    }
    b.backgroundTintList = null
    b.background = bg
    b.stateListAnimator = null // flat: no theme elevation shadow
    b.setTextColor(SettingsButtonPalette.TEXT)
    b.minHeight = dp(44)
    b.minimumHeight = dp(44)
    b.setPadding(dp(14), dp(8), dp(14), dp(8))
}

/**
 * The in-stream settings panel (T-105): a full-screen transparent layer over the video with an opaque (T-352),
 * scrollable panel on the right. The video underneath keeps its size and keeps playing. A tap on the layer outside the
 * panel asks to close it on ACTION_UP, so the whole tap stays here and no half gesture reaches input capture after
 * closing. [content] is where the shared [SettingsViews] renders. Main thread only.
 */
class SettingsSidePanel(context: Context, private val onCloseRequest: (SettingsPanelState.Via) -> Unit) {
    private val density = context.resources.displayMetrics.density

    /** Add to the activity root as its top-most child (MATCH_PARENT). */
    val layer: FrameLayout = FrameLayout(context)

    val content: LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(24), dp(0), dp(24), dp(32))
    }

    private var downOutside = false

    init {
        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(context.getColor(R.color.mb_surface))
            isClickable = true // touches on the panel's empty areas stay on the panel (not a tap outside)
        }
        val head = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(24), dp(16), dp(8), dp(8))
        }
        head.addView(
            TextView(context).apply {
                text = "Ayarlar"
                textSize = 24f
                setTextColor(context.getColor(R.color.mb_text))
                setTypeface(typeface, Typeface.BOLD)
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        head.addView(
            Button(context, null, 0, R.style.MbButtonText).apply {
                text = "Kapat"
                setOnClickListener { onCloseRequest(SettingsPanelState.Via.CLOSE_BUTTON) }
            },
        )
        panel.addView(head)
        val scroll = ScrollView(context).apply { addView(content) }
        panel.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))
        layer.addView(
            panel,
            FrameLayout.LayoutParams(dp(PANEL_WIDTH_DP), ViewGroup.LayoutParams.MATCH_PARENT, Gravity.END),
        )
        layer.visibility = View.GONE
        layer.setOnTouchListener { _, ev -> onLayerTouch(ev) }
    }

    val isShown get() = layer.visibility == View.VISIBLE

    fun show() {
        downOutside = false
        layer.visibility = View.VISIBLE
        layer.bringToFront()
    }

    fun hide() {
        downOutside = false
        layer.visibility = View.GONE
    }

    /** Only touches outside the panel get here (the panel consumes its own); all of them are consumed. */
    private fun onLayerTouch(ev: MotionEvent): Boolean {
        when (ev.actionMasked) {
            MotionEvent.ACTION_DOWN -> downOutside = true
            MotionEvent.ACTION_UP -> if (downOutside) {
                downOutside = false
                onCloseRequest(SettingsPanelState.Via.TAP_OUTSIDE)
            }
            MotionEvent.ACTION_CANCEL -> downOutside = false
        }
        return true
    }

    private fun dp(v: Int) = (v * density).toInt()

    private companion object {
        const val PANEL_WIDTH_DP = 460
    }
}
