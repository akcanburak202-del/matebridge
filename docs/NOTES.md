# Bulgular defteri

Donanım ve platform bulguları buraya **tarihli** olarak eklenir (en yeni en altta). Sohbette kalan bulgu ajanlar için yoktur.

## 2026-09-29 — Başlangıç

- Mac: Mac mini, Apple M6, macOS 27.0.1 (26A434), Xcode 27.0, Swift 6.4. Şu an 1920×1080 bir harici monitör bağlı.
- `CGVirtualDisplay`, `CGVirtualDisplayDescriptor`, `CGVirtualDisplayMode`, `CGVirtualDisplaySettings` sınıfları macOS 27.0.1'de mevcut (`/System/Library/Frameworks/CoreDisplay.framework` yüklenerek). Henüz ekran oluşturma denenmedi → T-004.
- Tablet: Huawei MatePad Pro 12.2 (2025), HarmonyOS 4.3, 2800×1840 tandem OLED (PaperMatte), 144 Hz, M-Pencil 3. nesil (16.384 basınç seviyesi, üretici verisi). Android API seviyesi → T-002.
- Referans: [LukeLogix/android-display](https://github.com/LukeLogix/android-display) (Apache-2.0) — CGVirtualDisplay + VideoToolbox H.264 + UDP + tablet olayı enjeksiyonu örnekleri.

## 2026-09-29 — Tablet adb ile bağlandı (T-002)

- Model **MRDI-W09** (MatePad Pro 12.2 2025), yazılım `4.3.0.143(C432E1R1P2)`, HarmonyOS 4.3.0, Android uyumluluğu **Android 12 / API 31**.
- Ekran: 2800×1840 fiziksel, density 360 (~275 dpi). Modlar: 60 / 120 / 144 Hz. Ölçüm anında sistem 60 Hz'e sınırlıydı (`primaryRefreshRateRange=[0 60]`, muhtemelen akıllı yenileme/güç modu). Renk modları [0, 7, 9], HDR tipleri [2, 3] (HDR10, HLG), maks. 500 nit (sistem raporu).
- `adb exec-out screencap -p` çalışıyor (2800×1840 PNG). Çekim sırasında tablet Parsec ile Mac ekranını gösteriyordu (16:9 → 3:2, üst/altta siyah bant). Bu da tabletin tam çözünürlüğünde sanal ekranın neden gerekli olduğunu gösteriyor.
- **Donanım decoder'ları** (`/vendor/etc/media_codecs*.xml`):
  - `OMX.hisi.video.decoder.avc`: maks. 4096×4096, performans noktası 4K@60
  - `OMX.hisi.video.decoder.hevc`: maks. 5120×5120, performans noktası 4K@60
  - Ayrıca VVC (4K@30), VP9. 2800×1840 ≈ 5,2 MP < 4K (8,3 MP). 60 FPS için rahat. 120 FPS HEVC ile ölçülerek denenecek.
  - XML'de `low-latency` özelliği ilan edilmemiş. Çalışma zamanında `KEY_LOW_LATENCY` denenecek.
- **Girdi cihazları** (`dumpsys input`):
  - `HUAWEI Glide Keyboard`, `... Touchpad`, `... Consumer Control`: Bluetooth (bus 0x0005), vendor 0x12d1, product 0x10b2
  - `huawei,ts_pen`: dahili kalem girişi (M-Pencil)
  - `HUAWEI Mouse CD26 SE`: Bluetooth fare (eşleşmiş)

## 2026-09-29 — Sanal ekran ve kalem enjeksiyonu (T-004, T-005)

- **CGVirtualDisplay macOS 27.0.1'de çalışıyor.** `hiDPI=1` iken mod boyutları **nokta** cinsinden: 1400×920 mod + `maxPixels` 2800×1840 → 1400×920 pt / 2800×1840 px HiDPI. Sistem ayrıca 800×526…2800×1840 arası ek modlar türetiyor. ScreenCaptureKit ekranı ~1 sn içinde görüyor, kareler 2800×1840.
- Sanal ekran oluşunca **ana ekran oldu** (menü çubuğu, Dock ve pencereler oraya geçti) ve fiziksel 1920×1080 ekran aktif ekran listesinden çıktı. Yansıtma mı ana ekran değişimi mi, henüz ayrıştırılmadı.
- **Kullanıcı tercihi:** tablet tek ana ekran olarak kullanılacak. Sonuçları: (1) MateBridge çökerse Mac ekransız kalmasın diye HDMI dummy yedek olarak takılı kalır, Parsec yedek erişim olur. (2) Kısa Wi-Fi kopmalarında sanal ekran hemen kaldırılmamalı (pencereler öbür ekrana dökülür), bir bekleme süresi gerekli.
- TCC: Ekran Kaydı ve Erişilebilirlik izinleri Terminal.app'e verildiğinde **Terminal yeniden başlatılmadan** yeni süreçlerde etkin oldu.
- **Sentetik kalem olayları çalışıyor:** tabletProximity (enter, pointerType=1 pen, capability mask 0x25C7) + `leftMouseDown/Dragged/Up` subtype `tabletPoint` (1). AppKit penceresinde basınç 0→1, eğim −1…+1 doğru görünüyor. Vuruş sonunda sıra: mouseUp → proximity out.
- Enjeksiyon hedef pencere önde değilse olaylar alttaki/öndeki başka pencereye gider (ilk denemede böyle oldu). Ürün kodunda sorun değil (imleç nerede ise olay oraya gider), ama testlerde hedef pencere öne alınmalı.
- Parsec üzerinden tablet klavyesinde **Caps Lock uzak Mac'e geçmiyor** (Shift çalışıyor). MateBridge klavye iletiminde Caps Lock durumu ayrıca eşitlenmeli.
- İmza: Apple Development sertifikası oluştu ama anahtar zincirinde yalnızca süresi dolmuş (2023) WWDR ara sertifikası vardı; `find-identity -v` 0 geçerli kimlik gösterdi. Apple WWDR **G3** ara sertifikası (apple.com/certificateauthority) kurulunca kimlik geçerli oldu.
