// Wi-Fi workload (T-127): full-screen borderless window, repeating 40 s cycle for argv[1] seconds:
//   0–20 s  smooth scroll of dense coloured text (sustained motion),
//   20–30 s full-screen content switch every 2 s (app-switch-like bursts: whole frame changes),
//   30–40 s static (settled text; idle/recovery).
// Deterministic: the same content and timing every run.
import AppKit
import QuartzCore

let seconds = Double(CommandLine.arguments.dropFirst().first ?? "300") ?? 300
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let screen = NSScreen.main!.frame
let scale = NSScreen.main!.backingScaleFactor
let win = NSWindow(contentRect: screen, styleMask: .borderless, backing: .buffered, defer: false)
win.level = .floating
let host = NSView(frame: NSRect(origin: .zero, size: screen.size)); host.wantsLayer = true
win.contentView = host

func page(_ seed: Int, height: CGFloat, bg: NSColor) -> CGImage {
    let img = NSImage(size: NSSize(width: screen.width, height: height), flipped: true) { r in
        bg.setFill(); r.fill()
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let colors: [NSColor] = seed % 2 == 0
            ? [.black, .systemBlue, .systemRed, .systemGreen, .darkGray, .systemPurple]
            : [.white, .systemYellow, .systemTeal, .systemPink, .lightGray, .systemOrange]
        let words = ["func", "let", "var", "return", "guard", "struct", "self.value", "CMSampleBuffer", "0x1F3A", "if",
                     "else", "// yorum", "VTCompressionSession", "kbps", "latency_ms", "{", "}", "(x, y)", "=>", "çığ"]
        var y: CGFloat = 4; var i = seed * 31
        while y < height {
            var line = String(format: "%5d  ", i)
            for j in 0..<14 { line += words[(i * 7 + j * 3 + j * j + seed) % words.count] + " " }
            (line as NSString).draw(at: NSPoint(x: 8, y: y),
                                    withAttributes: [.font: font, .foregroundColor: colors[i % colors.count]])
            y += 17; i += 1
        }
        return true
    }
    return img.cgImage(forProposedRect: nil, context: nil,
                       hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: scale))])!
}

let scrollH = screen.height * 4
let scrollImg = page(0, height: scrollH, bg: .white)
let switchImgs = [page(1, height: screen.height, bg: NSColor(white: 0.12, alpha: 1)),
                  page(2, height: screen.height, bg: NSColor(calibratedRed: 0.95, green: 0.93, blue: 0.85, alpha: 1)),
                  page(3, height: screen.height, bg: NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.25, alpha: 1))]
let layer = CALayer()
layer.contentsScale = scale
layer.frame = NSRect(x: 0, y: 0, width: screen.width, height: scrollH)
layer.contents = scrollImg
host.layer!.addSublayer(layer)
win.makeKeyAndOrderFront(nil)

let start = CACurrentMediaTime()
var offset: CGFloat = 0
let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in
    let t = CACurrentMediaTime() - start
    if t >= seconds { app.terminate(nil) }
    let c = t.truncatingRemainder(dividingBy: 40)
    CATransaction.begin(); CATransaction.setDisableActions(true)
    if c < 20 {
        if layer.contents as AnyObject !== scrollImg { layer.contents = scrollImg
            layer.frame = NSRect(x: 0, y: 0, width: screen.width, height: scrollH) }
        offset = (offset + 4).truncatingRemainder(dividingBy: scrollH - screen.height)
        layer.frame.origin.y = -offset
    } else if c < 30 {
        let k = Int((c - 20) / 2) % switchImgs.count
        if layer.contents as AnyObject !== switchImgs[k] {
            layer.contents = switchImgs[k]
            layer.frame = NSRect(x: 0, y: 0, width: screen.width, height: screen.height)
        }
    } else if layer.contents as AnyObject !== scrollImg {
        layer.contents = scrollImg
        layer.frame = NSRect(x: 0, y: -offset, width: screen.width, height: scrollH)
    }
    CATransaction.commit()
}
RunLoop.main.add(timer, forMode: .common)
app.activate(ignoringOtherApps: true)
app.run()
