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
- **Krita 5.3.4 sentetik kalem basıncını tanıyor** (Basic-5 Size Opacity: kalınlık + opaklık). Ayrı bir tablet sürücüsü gerekmiyor.

## 2026-09-29 — Girdi probu sonuçları (T-003)

Kaynak: MB Input Probe (776b179), MatePad MRDI-W09, HarmonyOS 4.3 / API 31. Ham veriler repoda değil.

**Kalem (`huawei,ts_pen`, source 0x5002, tool STYLUS)**
- Örnekleme ~**330 Hz** (eventTime farkı medyan 3 ms). Olay başına 0–8 historical örnek (çoğunlukla 2). Ekran 60/120 Hz olsa da kalem verisi 3 ms'de bir geliyor: protokol historical örnekleri **toplu** taşımalı.
- Basınç 0,0044–0,879 (kullanıcı en sert basışında), en küçük adım 6,1e-5 = **1/16384**. 16.384 seviye doğrulandı. Koordinatlar 1/8 piksel hassasiyetinde (float).
- **Eğim temas sırasında neredeyse donuk:** hover'da `AXIS_TILT`/`AXIS_ORIENTATION` sürekli değişiyor (417+ farklı değer), temas halinde vuruş başına 1–5 farklı değer. HarmonyOS temas sırasında eğimi seyrek güncelliyor. Mac'te eğim tabanlı gölgeleme vuruş içinde sınırlı kalacak. Eğim radyan: 0 = dik, ~1,22'ye kadar görüldü. Orientation radyan.
- `AXIS_DISTANCE` her zaman 0: hover yüksekliği bilgisi yok. HOVER_ENTER/EXIT var, yakınlık (proximity) bunlardan türetilir.
- Hareket olaylarında `buttonState` hep 0. Kalem hareketleri tek pointer'la geldi.
- **M-Pencil ayrıca Bluetooth cihazı olarak görünüyor:** "HUAWEI M-Pencil 3 Mouse" (vendor 0x12d1, product 0x10a5). Kalemdeki çift dokunma/sıkma hareketi bu cihazdan `keyCode 718 / scanCode 190` olarak iki kısa DOWN/UP çifti üretiyor (~4–20 ms aralıklı). Mac'e silgi/araç değiştirme kısayolu olarak eşlenebilir.
- Avuç teması `input_mt_wrapper` (FINGER) olarak ayrı geliyor. Kalemle çizimde yok sayılmalı.

**Klavye (HUAWEI Glide Keyboard, BT, vendor 0x12d1 product 0x10b2)**
- Linux scan code'ları standart (A=30, Esc=1, Space=57, oklar 103/105/106/108, Caps=58, LShift=42, LCtrl=29, LAlt=56). Karar 0003 (fiziksel tuş kodu) için uygun.
- `metaState` Num Lock'u hep açık (0x200000) gösteriyor. **Caps Lock sonrası 0x300000** (CAPS_LOCK_ON): Caps Lock durumu metaState'ten okunabilir, Mac ile eşitlenebilir.
- Basılı tutmada Android otomatik tekrar üretiyor (repeatCount 1…n, ilk tekrarda FLAG_LONG_PRESS). Mac kendi tekrarını üreteceği için **repeatCount>0 olaylar iletilmemeli**.
- **Esc iki olay üretiyor:** aynı scanCode 1 ile hem `KEYCODE_ESCAPE` hem `KEYCODE_BACK`. İstemci BACK'i tüketmeli, yoksa Esc uygulamayı kapatır/geri gider.
- **Tekrar testi (aynı gün, normal + pointer capture):** Tab DOWN/UP düzgün geliyor (ilk oturumdaki eksik DOWN kullanıcı kaynaklıydı). Ctrl (scan 29) ve Alt (scan 56) her iki modda geliyor. **Fn ve Huawei'nin halka sembollü tuşu uygulamaya hiç ulaşmıyor** (klavye donanımı/sistem yutuyor). Pointer capture tuş olaylarını değiştirmiyor.
- **Sonuç: Glide Keyboard'da uygulamaya ulaşan bir Cmd/Meta tuşu yok.** Mac'in Cmd'si için değiştirici eşlemesi gerekecek (örn. Ctrl→Cmd, Alt→Option, gerçek Control için ayrı çözüm). Bu bir kullanıcı tercihi. Klavye görevi öncesi karar kaydı yazılacak.
- Backspace henüz test edilmedi (kullanıcı Space'e bastı). Bir sonraki tablet testinde bakılacak.

**Trackpad (Glide Keyboard touchpad)**
- **Normal mod:** source MOUSE (0x2002), tool FINGER, mutlak imleç konumu, relX/relY yok. Dokunarak tıklama → touch ACTION_DOWN/UP (tool MOUSE, buttonState 1). Fiziksel tık → BUTTON_PRESS/RELEASE. **İki parmakla kaydırma scroll olayı üretmiyor**, HarmonyOS bunu tek parmak dokunmatik sürüklemeye çeviriyor (ACTION_DOWN + MOVE FINGER). AXIS_VSCROLL/HSCROLL hiç görülmedi.
- **Pointer capture modu:** source **TOUCHPAD (0x100008)**, ham mutlak parmak koordinatları (x ~174–1734, y ~97–1624), **çoklu dokunma** (POINTER_DOWN/UP ile 2 parmak), basınç sabit 1,0, relX/relY yok. Fiziksel tık BUTTON_PRESS olarak geliyor.
- Sonuç: Mac'te düzgün imleç ve iki parmak kaydırma için trackpad **pointer capture ile ham veri olarak** alınmalı, hareketler Mac tarafında (veya istemcide) göreli harekete/scroll'a çevrilmeli. Normal mod kaydırma için kullanılamaz.

**Diğer:** Eşleşmiş "HUAWEI Mouse CD26 SE" BT fare de mevcut (source MOUSE, tool MOUSE, hover olayları).

## 2026-09-29 — İmza ve TCC kalıcılığı (T-006)

- `scripts/bundle-host.sh` ile Apple Development kimliğiyle imzalanan `.app`, `open` ile başlatıldığında **kendi TCC kimliğini** kullanıyor (Terminal'in izinleri geçmiyor). Bir kez izin verildikten sonra debug/release yeniden derlemelerde (farklı CDHash) Ekran Kaydı izni korundu.
- `open` ile başlayan uygulamanın çalışma dizini `/`. Ürün kodunda dosya yolları mutlak olmalı (örn. `~/Library/Logs/MateBridge/`).

## 2026-09-29 — Aşama 0 özeti (T-007 girdisi)

| Konu | Sonuç | Protokole etkisi |
|---|---|---|
| Sanal ekran | 2800×1840 px HiDPI (1400×920 pt) çalışıyor, ana ekran oluyor | `STREAM_CONFIG` = sanal ekranın piksel boyutu; koordinatlar normalize |
| Kalem | ~330 Hz, 1/16384 basınç, eğim temas sırasında seyrek, mesafe yok | `PEN` toplu örnek, u16 basınç, tilt_x/y, `IN_RANGE`/`CONTACT` bayrakları |
| Kalem hareketi | Çift dokunma = ayrı BT cihazından keyCode 718 | `PEN_GESTURE` |
| Sentetik kalem (Mac) | proximity + tabletPoint, Krita basıncı tanıyor | Host durum makinesi bayrak geçişlerinden olay üretir |
| Klavye | Standart evdev scan code, Caps durumu metaState'te, Esc→BACK çiftlemesi, Cmd tuşu yok | `KEY` scan code + `lock_state`, tekrar yok, BACK yutulur |
| Trackpad | Normal modda kaydırma yok, capture'da ham çoklu dokunma | `POINTER_REL` + `SCROLL` istemcide üretilir |
| Donanım decoder | HEVC/H.264 4K@60 | `STREAM_CONFIG.codec`, varsayılan HEVC |
