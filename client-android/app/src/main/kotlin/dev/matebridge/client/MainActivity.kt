package dev.matebridge.client

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.TextView

/** Minimal shell: fullscreen, landscape, screen kept on. Connection logic arrives in later tasks. */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val label = TextView(this).apply {
            text = "MateBridge — bağlantı yok"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.BLACK)
            textSize = 24f
            gravity = Gravity.CENTER
        }
        setContentView(label)
        @Suppress("DEPRECATION")
        label.systemUiVisibility = (View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
            or View.SYSTEM_UI_FLAG_FULLSCREEN
            or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
            or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
    }
}
