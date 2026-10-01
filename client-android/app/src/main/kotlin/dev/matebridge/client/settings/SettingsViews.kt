package dev.matebridge.client.settings

import android.content.Context
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
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView

/**
 * Renders [SettingsCatalog] sections into [container] with plain Views (decision 0004: no Compose). The connect panel
 * and the in-stream side panel each own one instance over the same [SettingsHost]; [onChanged] runs after every user
 * action so the activity can refresh both. Main thread only.
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
        for (s in sections) {
            container.addView(header(s.title), rowParams(top = 20))
            for (item in s.items) container.addView(build(item), rowParams(top = 6))
        }
        refresh()
    }

    /** Re-reads every label and selection from the host. */
    fun refresh() = refreshers.forEach { it() }

    private fun build(item: SettingItem): View = when (item) {
        is SettingItem.Choice -> choice(item)
        is SettingItem.Toggle -> button("") {
            item.set(!item.get())
        }.also { b -> refreshers += { b.text = item.text() } }
        is SettingItem.Stepper -> stepper(item)
        is SettingItem.Action -> button(item.title) { item.run() }
        is SettingItem.Info -> text("", 15f, INFO_COLOR).also { t -> refreshers += { t.text = item.text() } }
    }

    private fun choice(item: SettingItem.Choice): View {
        val col = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
        val title = text(item.titleText(), 16f, TEXT_COLOR)
        col.addView(title)
        val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
        val buttons = item.options.map { o ->
            button(o.label) { item.select(o.id) }.also { row.addView(it, rowParams(top = 0, end = 6)) }
        }
        val scroller = HorizontalScrollView(context).apply { isHorizontalScrollBarEnabled = false; addView(row) }
        col.addView(scroller)
        refreshers += {
            title.text = item.titleText() // T-109: "(oyun modu)" comes and goes with game mode
            val sel = item.selected()
            for ((i, b) in buttons.withIndex()) {
                val on = item.options[i].id == sel
                b.isSelected = on // the background's state_selected entry turns it blue (T-107)
                b.setTypeface(null, if (on) Typeface.BOLD else Typeface.NORMAL)
            }
        }
        return col
    }

    private fun stepper(item: SettingItem.Stepper): View {
        val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL; gravity = Gravity.CENTER_VERTICAL }
        val label = text("", 16f, TEXT_COLOR)
        row.addView(label, rowParams(top = 0, end = 12))
        row.addView(button("−") { item.dec() }, rowParams(top = 0, end = 6))
        row.addView(button("+") { item.inc() }, rowParams(top = 0))
        refreshers += { label.text = "${item.title}: ${item.value()}" }
        return row
    }

    private fun button(label: String, action: () -> Unit) = Button(context).apply {
        text = label
        isAllCaps = false
        minWidth = 0
        minimumWidth = 0
        styleSettingsButton(this)
        setOnClickListener {
            action()
            onChanged()
        }
    }

    private fun header(title: String) = text(title, 19f, TEXT_COLOR).apply { setTypeface(typeface, Typeface.BOLD) }

    private fun text(s: String, sp: Float, color: Int) = TextView(context).apply {
        text = s
        textSize = sp
        setTextColor(color)
    }

    private fun rowParams(top: Int, end: Int = 0) =
        LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).also {
            it.topMargin = dp(top)
            it.marginEnd = dp(end)
        }

    private fun dp(v: Int) = (v * density).toInt()

    private companion object {
        val TEXT_COLOR = Color.WHITE
        val INFO_COLOR = Color.parseColor("#BBBBBB")
    }
}

/**
 * T-107: gives a settings-panel button explicit colors ([SettingsButtonPalette]) instead of the system theme's light
 * background. Selection is driven by [View.isSelected]; pressing shows a darker/lighter shade.
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
 * The in-stream settings panel (T-105): a full-screen transparent layer over the video with a semi-transparent,
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
        setPadding(dp(20), dp(4), dp(20), dp(24))
    }

    private var downOutside = false

    init {
        val panel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(PANEL_COLOR)
            isClickable = true // touches on the panel's empty areas stay on the panel (not a tap outside)
        }
        val head = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(20), dp(12), dp(12), dp(4))
        }
        head.addView(
            TextView(context).apply {
                text = "Ayarlar"
                textSize = 22f
                setTextColor(Color.WHITE)
                setTypeface(typeface, Typeface.BOLD)
            },
            LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
        )
        head.addView(
            Button(context).apply {
                text = "Kapat"
                isAllCaps = false
                styleSettingsButton(this)
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
        val PANEL_COLOR = Color.parseColor("#D9141418") // ~85 % opaque: the video stays visible behind
    }
}
