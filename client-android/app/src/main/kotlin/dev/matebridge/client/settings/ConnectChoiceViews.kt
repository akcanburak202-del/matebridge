package dev.matebridge.client.settings

import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.graphics.drawable.StateListDrawable
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.Switch
import android.widget.TextView
import dev.matebridge.client.R
import dev.matebridge.client.session.ConnectChoice
import dev.matebridge.client.session.ConnectPath
import dev.matebridge.client.session.ConnectPlanner

/**
 * T-362 (decision 0042 section 1): the connect screen's "Yerel ağ | Tailscale" segmented control and, on Tailscale only,
 * the "Veri tasarrufu" switch. Same look as [SettingsViews] (T-352). The choice itself is kept by the caller;
 * [show] redraws it.
 */
class ConnectChoiceViews(
    private val context: Context,
    container: LinearLayout,
    private val onChange: (ConnectChoice) -> Unit,
) {
    private val density = context.resources.displayMetrics.density
    private var choice = ConnectChoice.DEFAULT
    private val local: TextView
    private val tailscale: TextView
    private val saverRow: LinearLayout
    private val saverSwitch: Switch

    init {
        val outer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            background = GradientDrawable().apply { cornerRadius = dp(RADIUS_DP).toFloat(); setStroke(dp(1), color(R.color.mb_outline)) }
            setPadding(dp(1), dp(1), dp(1), dp(1))
        }
        local = segment(first = true, last = false).apply {
            text = context.getString(R.string.path_local)
            setOnClickListener { pick(ConnectPath.LOCAL) }
        }
        tailscale = segment(first = false, last = true).apply {
            text = context.getString(R.string.path_tailscale)
            setOnClickListener { pick(ConnectPath.TAILSCALE) }
        }
        outer.addView(local, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        outer.addView(
            View(context).apply { setBackgroundColor(color(R.color.mb_outline)) },
            LinearLayout.LayoutParams(dp(1), ViewGroup.LayoutParams.MATCH_PARENT),
        )
        outer.addView(tailscale, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.MATCH_PARENT, 1f))
        // Fixed height: with WRAP_CONTENT the MATCH_PARENT divider measures to the whole remaining screen height.
        container.addView(outer, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(CONTROL_DP)))

        saverSwitch = Switch(context).apply {
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
        val label = TextView(context).apply {
            text = context.getString(R.string.saver_label)
            textSize = 16f
            setTextColor(color(R.color.mb_text))
        }
        saverRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            minimumHeight = dp(CONTROL_DP)
            isClickable = true
            isFocusable = true
            defaultFocusHighlightEnabled = false
            setOnClickListener { update(choice.copy(saver = !choice.saver)) }
            addView(label, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f).also { it.marginEnd = dp(16) })
            addView(saverSwitch)
        }
        container.addView(
            saverRow,
            LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).also { it.topMargin = dp(8) },
        )
        show(choice)
    }

    private fun pick(path: ConnectPath) { if (path != choice.path) update(choice.copy(path = path)) }

    private fun update(c: ConnectChoice) {
        show(c)
        onChange(c)
    }

    fun show(c: ConnectChoice) {
        choice = c
        for ((seg, path) in listOf(local to ConnectPath.LOCAL, tailscale to ConnectPath.TAILSCALE)) {
            seg.isSelected = c.path == path
            seg.setTextColor(color(if (c.path == path) R.color.mb_on_accent else R.color.mb_text))
        }
        saverRow.visibility = if (ConnectPlanner.showsSaver(c)) View.VISIBLE else View.GONE
        saverSwitch.isChecked = c.saver
    }

    private fun segment(first: Boolean, last: Boolean): TextView = TextView(context).apply {
        gravity = Gravity.CENTER
        textSize = 16f
        minHeight = dp(CONTROL_DP)
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

    private fun color(id: Int) = context.getColor(id)

    private fun dp(v: Int) = (v * density).toInt()

    private companion object {
        const val RADIUS_DP = 8
        const val CONTROL_DP = 48
    }
}
