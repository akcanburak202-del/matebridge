package dev.matebridge.client.bench

import android.app.Activity
import android.graphics.Color
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView
import dev.matebridge.client.session.MbLog

/**
 * Experiment-only raw TCP throughput screen (T-090). Reached only through MainActivity's `--es net_bench HOST:PORT`
 * extra together with `--ez dev true` (T-185); no MateBridge session, no input is sent. The result stays on screen
 * until the user leaves. Debug source set only (T-185): MainActivity starts it by class name.
 */
class NetBenchActivity : Activity() {
    private lateinit var text: TextView
    private var runner: NetBenchRunner? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        text = TextView(this).apply {
            setBackgroundColor(Color.BLACK)
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 28f)
            gravity = Gravity.CENTER
            text = "Ağ ölçümü…"
        }
        setContentView(text)

        val i = intent
        val parsed = NetBenchConfig.parse({ i.getStringExtra(it) }, { i.hasExtra(it) }, { i.getIntExtra(it, 0) })
        val config = (parsed as? NetBenchConfig.Parsed.Ok)?.config
        if (config == null) {
            MbLog.w("error", "stage=parse reason=bad_endpoint", COMPONENT)
            text.text = "Ağ ölçümü: geçersiz adres (HOST:PORT bekleniyor)"
            return
        }
        val r = NetBenchRunner(
            config,
            log = { level, ev, fields -> if (level == 'W') MbLog.w(ev, fields, COMPONENT) else MbLog.i(ev, fields, COMPONENT) },
            onUpdate = { s -> runOnUiThread { if (!isDestroyed) text.text = s } },
        )
        runner = r
        Thread({ r.run() }, "netbench").start()
    }

    override fun onDestroy() {
        runner?.cancel()
        runner = null
        super.onDestroy()
    }

    companion object {
        const val COMPONENT = "netbench"
    }
}
