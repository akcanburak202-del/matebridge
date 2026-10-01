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

## 2026-09-29 — Huawei'de APK kurulumu

- Yeni bir paket adının **ilk** `adb install`'unda HarmonyOS, AppGallery'nin "kurulum risk denetimi" ekranını açıyor (`InstallDistActivity`) ve tablette onay istiyor. `adb install` bu sırada `failed to install` döndürse de kullanıcı onaylayınca paket kuruluyor. Doğrulama: `adb shell pm list packages | grep matebridge`.
- Kurulu olmayan bir paketi başlatmaya çalışmak (`monkey -p`) AppGallery'de arama açıyor. Başlatmadan önce kurulumu doğrula.
- Aynı paketin güncellemeleri (`install -r`) onay istemedi (input-probe deneyimi).
- adb sunucusu komutlar arasında sık sık kapanıp yeniden başlıyor ("daemon not running; starting now"). Zararsız ama ilk komutu yavaşlatıyor.

## 2026-09-29 — İlk uçtan uca görüntü: Mac HEVC → tablet donanım decoder (T-011 + T-013)

- Mac: `MateBridgeApp --dump-video` (T-011, dee7ae7/d121007), sanal ekran 2800×1840 HiDPI → SCK (420f, tam aralık) → VideoToolbox HEVC 30 Mbps hedef. 6 sn: 138 kare (SCK yalnızca ekran değişince kare veriyor), 1 keyframe, kodlama ort. 13 ms / maks. 38 ms, kuyruk atma 0. Akış VPS/SPS/PPS ile başlıyor (Annex-B).
- Tablet: `VideoTestActivity` (T-013, c316327), dosyadan 30 fps oynatma. `OMX.hisi.video.decoder.hevc` 2800×1840, **30/30/30 alındı/çözüldü/gösterildi, 0 atma**, 29,8 fps. Görüntü ve renkler doğru görünüyor.
- Decoder çıkış formatı: `range=1` (tam), `standard=1` (BT.709), `transfer=2` (kamuya açık sabitlerde yok; muhtemelen üreticinin sRGB karşılığı).
- `KEY_LOW_LATENCY`: **desteklenmiyor** (`FEATURE_LowLatency` yok). Ortalama çözme süresi ~16 ms. Gecikmeyi azaltmak için üreticiye özel anahtarlar Aşama 1 ölçümünde denenecek.
- adb ile `Android/data/<paket>/files/` altına gönderilen dosya, uygulama dizini ilk kez oluştururken silinebiliyor. Uygulamayı bir kez başlattıktan sonra `adb push` yap.

## 2026-09-29 — İlk canlı oturum: tablet ↔ Mac (T-010, T-012)

- Bonjour `_matebridge._tcp` keşfi Wi-Fi'de çalıştı. `NSBonjourServices` ile paketlenen uygulama için macOS ayrıca "yerel ağ" izni **sormadı**.
- Akış: `connect_ok` → HELLO → `hello_ack status=1` (PENDING) → Mac'te onay → `status=0` → `STREAM_CONFIG` → video bağlantısı. Onaydan sonra tekrar bağlanmalar onaysız kabul ediliyor.
- **AppKit tuzağı:** `NSApp.abortModal()` modal döngünün kendi olay işleyişi dışından (Task/timer) çağrılınca döngü bir sonraki olaya kadar fark etmiyor; eski onay penceresi ekranda kalıyor ve kullanıcının sonraki tıklaması boşa gidiyor. Çözüm: `runModal` yerine modal olmayan panel (T-010b).
- **Kullanım notu:** Tablette MateBridge arka plana geçince (ör. Parsec'e geçiş) oturum BYE ile kapanıyor. Mac'e Parsec ile tabletten bakarken test yapılamaz. Onay tıklamaları orkestratör tarafından AX (System Events) ile yapılabiliyor.
- adb sunucusu sık sık "didn't ACK / failed to start daemon" ile açılamıyor (libunwind uyarısı). `adb kill-server; adb start-server` döngüsüyle aşılıyor. `adb install` de ara sıra boş hata verip kurmuyor; `dumpsys package … lastUpdateTime` ile doğrula.

## 2026-09-29 — İlk canlı görüntü: Mac ekranı tablette (T-014 + T-015)

- Wi-Fi, HEVC 2800×1840 HiDPI, hedef 30 Mbps / 60 fps. Tablet Mac'in ana ekranı olarak.
- Hareketli içerik (Safari'de 60 fps CSS/JS animasyonu): tablette **56–59 fps, 0 atma**, uçtan uca (yakalama → çözülmüş kare) **~36–41 ms**, çözme ~15 ms, Wi-Fi RTT ~24 ms. Durağan ekranda ~10 fps (SCK yalnız değişince kare veriyor).
- **Kullanıcı değerlendirmesi:** netlik Parsec'e göre "kat be kat keskin", 13 px ve 11 px yazılar ve Türkçe karakterler temiz. **Hafif takılma ve ara ara fps düşüşü** var.
- Tablet ekranı akış sırasında **60 Hz** modunda (`SurfaceFlinger --latency` 16,67 ms). Kareler çözülür çözülmez çiziliyor; Wi-Fi varış titreşimi bazı vsync'lere 0, bazılarına 2 kare düşürüyor. İyileştirme: T-016 (kare zamanlaması, 120 Hz tercih, titreşim ölçümü).
- MateBridge.app'in kendi Ekran Kaydı izni yok; test Terminal'den başlatılan ikiliyle yapıldı. `codesign` ilk kez anahtarlık onayı istedi ("Her Zaman İzin Ver" ile kalıcı). Mac kilitliyken imzalama ve yakalama çalışmıyor; 10 dk sonra ekran kilitleniyor.

## 2026-09-29 — Akıcılık ölçümü (T-016)

- Tablette 120 Hz isteği (`preferredDisplayModeId` = 120 Hz modu) **uygulanmıyor**: video gösteren uygulamanın vsync'i 16,67 ms'de kalıyor, sistem ayarı "Yüksek" olsa bile. HarmonyOS FrameRateManager video yüzeyini 60 Hz'e sınırlıyor gibi. Denenecek: `Surface.setFrameRate(120, FIXED_SOURCE)`, üretici anahtarları.
- vsync'e hizalı sunum + 1–2 karelik titreşim tamponu takılma sayısını ölçülebilir biçimde azaltmadı, ~17 ms/kare gecikme ekledi → varsayılan kapalı.
- Kare kaybının ana kaynağı Mac: 60 fps içerik tablete ~57 fps geliyor, test sayfası da Mac'te 56–57 fps gösteriyor. Ağ varış aralığı p95 ~22 ms (iyi). → T-017.

## 2026-09-29 — Kare kaybının kökü ve USB/Wi-Fi karşılaştırması (T-017)

- **Kök neden (Mac):** SCK `minimumFrameInterval` tam 1/60 iken, biraz erken gelen kareler atılıyordu: 60 fps içerik → 57,4 fps yakalama, p99 aralık 33 ms. **1/(2×fps) = 8,33 ms** yapınca 60,0 fps ve p99 16,7 ms. Sanal ekran 60 Hz'de kalıyor; 120 Hz sanal ekran yardımcı olmadı. Kodlama/gönderim hattında kayıp yok (T-017 cadence ölçümü).
- Düzeltme sonrası Wi-Fi: tablete 60 fps, gecikme **26–33 ms** (önce ~39). Kullanıcı: "takılma azalmış ama hâlâ var, yeşil çubuk arada sıçrıyor".
- **USB (adb reverse, elle 127.0.0.1:port):** gecikme **~19 ms**, RTT ~1,7 ms (Wi-Fi ~20 ms), varış p95 ~18 ms (Wi-Fi ~21), geç kare 0–5/sn (Wi-Fi ~10). Kullanıcı: "Wi-Fi'ye göre daha akıcı ama hâlâ takılma var".
- **Ağ kurulumu:** Mac **Wi-Fi'de** (en1, 802.11ax, 5 GHz kanal 44, 80 MHz); Ethernet (en0) boş. Tablet 5 GHz, RSSI -44, ~1 Gbps. İki kablosuz atlama titreşimi artırıyor → Mac'i Ethernet'e bağlamak önerildi (PLAN §5.6).
- **Kalan takılma tablet tarafında:** USB'de bile 60 fps içerik 60 Hz'e kilitli ekranda ara ara bir vsync kaçırıyor. MediaCodec'in zamanlı `releaseOutputBuffer`'ı ve titreşim tamponu fark yaratmadı → T-018 (GL yolu ile sunumu kontrol etme, 120 Hz'i video katmanı dışında deneme).
- adb: `adb kill-server` reverse tünellerini siler; USB testinde tüneller yeniden kurulmalı. Tablet klavyesi Türkçe Q: `adb shell input text` içinde `:` → `Ş` oluyor; adresi SharedPreferences'a `run-as` ile yazmak işe yaradı.
- Kullanıcı kararı (2026-09-29): Mac'i Ethernet'e bağlamak şimdilik ertelendi; ölçümler Mac Wi-Fi'deyken yapılıyor.

## 2026-09-29 — Akıcılık çalışması park edildi (T-018, T-019)

- GL yolu (T-018) seçenek olarak main'de; varsayılan surface. HarmonyOS GL yüzeyini de 60 Hz'de tutuyor.
- GL titreşim tamponu (T-019) ölçümde kısmen iyileşme gösterdi ama kullanıcı gözüyle daha kötü; ayrıca soğuk başlangıçta GL'ye kare gelmeme hatası var. Dal park edildi.
- Mevcut durum (varsayılan): Mac 60,0 fps, Wi-Fi gecikme ~26–42 ms (ağ koşuluna göre), USB ~19 ms, kullanıcıya göre "Parsec'ten kat be kat keskin", "hafif takılma var". Sonraki adım: Mac'i Ethernet'e bağlayıp yeniden ölçmek.

## 2026-09-29 — adb sunucusu çöküyordu (kök neden)

- Gün boyu görülen "daemon not running / didn't ACK" kararsızlığının nedeni: **adb 37.0.1 sunucusu kendi mDNS köprüsünde (`adbmdns_bridge … FQServiceName::try_from`) `abort()` ile çöküyor** (SIGABRT, gün içinde 29 çökme raporu). Muhtemelen ağdaki bir mDNS hizmet adını (bizim `_matebridge._tcp` yayınımız da olabilir) ayrıştıramıyor. Sunucu çökünce `adb reverse` tünelleri de kayboluyor → USB modu "adb reverse kurulu mu?" uyarısı.
- Çözüm: adb sunucusunu `ADB_MDNS=0 ADB_MDNS_AUTO_CONNECT=0` ile ve launchd altında çalıştırmak (`scripts/usb-mode.sh on`). Sonrasında çökme durdu.
- Parsec host'u Mac'te çalışırken ekran yakalama/kodlama ve Wi-Fi bant genişliği paylaşılıyor; performans ölçümleri sırasında Parsec oturumu kapalı olmalı.

## 2026-09-29 — USB, Parsec kapalı: en iyi ölçüm ve Parsec karşılaştırması

- USB + Parsec kapalı: ~60 fps, gecikme **~21 ms**, RTT ~2 ms, geç kare çoğu saniyede 0 (arada 2–5). Kullanıcı: "daha iyi ama takılma devam ediyor".
- **Kullanıcı: Parsec aynı tablette "bu kadar takılmıyor".** Kalan takılma büyük olasılıkla iki bağımsız 60 Hz saatin faz kaymasından (Mac sanal ekranı / tablet paneli). Çözüm kare zamanlaması; HarmonyOS video katmanında sunum zamanı kontrol edilemedi. Karar: akıcılık Faz 5'e (PLAN §6 Aşama 5).

## 2026-09-30 — 30 dakikalık dayanıklılık testi (Faz 1 kapanışı)

- Koşul: USB (adb reverse, 47001/47002), Parsec kapalı, Mac'te Safari 60 fps animasyonu, `caffeinate -d`. MateBridge.app kendi Ekran Kaydı izniyle (`open` ile) çalıştı.
- 30 örnek (dakikada 1): Mac RSS **64 MB sabit**, tablet PSS **68–73 MB** (artış eğilimi yok), Mac CPU ~%10, gecikme 19–25 ms (ort. 21), decoder atma ort. 0,6/sn, **bağlantı kopması 0**, adb çökmesi 0.
- 15.–18. dakikada fps 30'a düştü; Mac yakalaması da 30 (`cap_fps=30`) → Safari animasyonu kendini 30 fps'e kısmış (enerji tasarrufu), hat değil.
- `ps %cpu` Türkçe yerelde ondalık virgül yazıyor; CSV ayrıştırırken dikkat.
- **Faz 1 bitiş ölçütü karşılandı:** 60 fps'e yakın, yazılar net (kullanıcı: "Parsec'ten kat be kat keskin"), 30 dk'da bellek şişmesi ve donma yok. Açık kalan: akıcılık (periyodik takılma) → Faz 5.

## 2026-09-30 — Faz 2 ilk canlı deneme (T-025, sürüyor)

- Koşul: `main` b2617f5, MateBridge.app kendi kimliğiyle (`open`), tablet USB'de; ikinci oturum tablet uygulamaya dönünce **Wi-Fi** ile kuruldu (keşif yolu).
- **İzin ve ekran:** Erişilebilirlik istemi açılışta çıktı; izin verilince uygulama yeniden başlatılmadan `input_gate accessibility=1`. Tablet bağlanınca `display=1`; sanal ekran vendor/product ile bulundu: `v0x4d42/m0x1/1400x920/active=1/mirror=0/main=1`. Sanal ekran kurulunca Mac'te **tek** ekran o oluyor (`count=1`); öncesindeki 1920×1080 ekran (`v0x756e6b6e/m0x76697274`, "unkn"/"virt") fiziksel monitör değil, başsız Mac'in yedek ekranı.
- **Çalışanlar (kullanıcı):** hover imleci, Krita'da çizgi ve basınç, el ekrana yaslıyken ve kaldırılırken çizim, parmakla tek dokunuş. İlk oturum: 51.913 girdi mesajı, 165.068 enjekte olay, oturum sonunda basılı kalan yok (`released=0`), düşürülen girdi yok.
- **Tablet sayaçları:** kalem 300–420 örnek/sn, 90–125 PEN mesajı/sn (mesaj başına ~3 örnek), `merged=0`, `refused=0`, `hover_stale=0`, `contact_stale=0`.
- **Çokgen eğri (kullanıcı):** Krita'da daire yayları çokgen kenarı gibi; hızlı çizimde belirgin, yavaşta az. Ölçüm (scratch AppKit penceresi, yalnızca alır): olay birleştirmesi **açıkken** vuruş başına **60 olay/sn**, aralık p50 16,6 ms, en uzun parça 28–43 pt; **kapalıyken** ~480 olay/sn, aralık p50 0,3 ms / p95 ~13,6 ms (öbekler), en uzun parça 6,6–7,9 pt. Kullanıcı: "maviler (kapalı) daha pürüzsüz". Yani host her şeyi enjekte ediyor ama **öbek öbek**: bir mesajın örnekleri art arda, mesajlar arası ~14 ms. Birleştirme kapalıyken olayların ~%25'i bir öncekiyle aynı konumda (mesaj başına yaklaşık bir yinelenen örnek; kaynağı belirsiz). → T-026 (tablette bekletmesiz iletim, yinelenen örnek sayacı). Krita'nın hangi mekanizmayla etkilendiği (birleştirme mi, varış zamanına dayalı yumuşatma mı) henüz ayrılmadı.
- **Takılma (kullanıcı):** ilk denemede, özellikle tuvalin sağ üstünde çizerken bir kez takılı girdi görüldü; tekrarlanamadı. O anın tablet log'u yok (logcat tamponu dönmüştü; sonrasında sürekli kayıt açıldı), host log'unda o oturumda release/watchdog/hata satırı yok. **Açık.**
- M-Pencil çift dokunma tablette algılandı (`pen_gesture gesture=double_tap`); Krita'da silgiye geçiş henüz ayrıca doğrulanmadı.

## 2026-09-30 — Faz 2 canlı deneme, devam (T-025, T-026)

- **T-026 (bekletmesiz kalem iletimi) cihazda çalışıyor:** `unbuffered path=source`, her örnek kendi mesajında (`pen_msgs` ≈ `pen_samples` ≈ 360/sn, `max_batch` 1–2).
- **Mac'e varış aralığı (ölçüm penceresi, birleştirme kapalı, 6 hızlı daire, ~362 olay/sn):**

  | | aralık medyan | aralık %95 | en uzun boşluk | yinelenen konum |
  |---|---|---|---|---|
  | T-026 öncesi (toplu) | 0,3 ms | 13,6 ms | ~15 ms | ~%25 |
  | T-026, USB | 2,8 ms | ~4 ms | 4–7,5 ms | 0 |
  | T-026, Wi-Fi | 0,5–1,1 ms | ~10 ms | 10,5–14 ms | 0 |

  Wi-Fi'de öbeklenme ağda oluşuyor (RTT ~20 ms, Mac de Wi-Fi'de). Kullanıcı: Krita'da köşeler USB'de azaldı, Wi-Fi'de daha köşeli. Host'ta zamana yayma kullanıcı kararıyla Faz 5'e bırakıldı.
- **Ölçüm tuzağı:** AppKit, uygulama açılışında fare olay birleştirmesini yeniden açıyor; `NSEvent.isMouseCoalescingEnabled = false` açılıştan **sonra** verilmeli. İlk Wi-Fi/USB karşılaştırmasında bu yüzden bir ölçüm geçersiz çıktı (60 olay/sn).
- **Fiziksel temas ile alınan vuruş karşılaştırması (USB):** tabletin çekirdek olayları (`getevent`, `huawei,ts_pen`, `/dev/input/event2`) 48 temas, Mac 47 vuruş; eksik olan pencere kapatma dokunuşu. Temas → Mac olayı farkı medyan 2 ms (en çok 5 ms). "Kalem değdi ama çizmedi" bu ölçümde tekrarlanmadı.
- **"Takılma" = "kalem çizmedi" (kullanıcı):** iki kez görüldü (13:3x, ~15:14), tekrarlanamadı. Silgi modu açıklaması düştü (Krita silgi ucunda fırça değiştirmiyor, aşağıda). Host ve tablet log'larında o anlara ait release, watchdog ya da hata satırı yok. **Açık.** Bir dahaki sefere tablet log'u olay anında çekilmeli (logcat tamponu dakikalar içinde dönüyor).
- **Çift dokunma:** tablet algılıyor, host kalemi silgi ucuna çeviriyor (`pointerType` 1 ↔ 3), Krita'nın Tablet Sınayıcı'sı "eraser" gösteriyor; ama Krita 5.3.4 fırçayı değiştirmiyor. → T-027.
- **Dokunma:** tek dokunuş, sürükleme, iki parmakla kaydırma (Krita tuvali ve paneller) çalışıyor. İki parmakla yakınlaştırma yok (protokolde tanımlı değil) → kullanıcı isteğiyle PLAN Aşama 3'e eklendi.
- **Video (Wi-Fi, çizim sırasında):** 14–60 fps (ekran değiştikçe), gecikme 21–30 ms; ara ara `keyframe_request reason=2` (tablette kare atılması). Bir kez durağan ekranda `decode_ms` 2806 ms görüldü (son karenin decoder'da beklemesi olabilir); incelenmedi.
- **Tablet uygulaması:** görüntü akarken bağlantı paneli gizli olduğu için USB/Wi-Fi seçimi değiştirilemiyor; denemede ayar `run-as` ile elle çevrildi (Faz 4 notu).
- **Kullanıcı kararları:** çizim ve oyun için USB kullanılacak; Wi-Fi kalem iyileştirmesi en sona.

## 2026-09-30 — Faz 2 canlı deneme, ikinci oturum: kablo çekme ve siyah ekran (T-025, T-028)

- **Vuruş ortasında kablo çekme (USB):** kalem basılıyken kablo çekildi; host `input_release cause=disconnected events=2 pen_up=1 pen_leave=1 buttons=0 scroll=0` yazdı, Mac'te basılı kalan olmadı. Aynı oturumun `input_session_end` satırı `released=0` diyor: sayaç bu bırakmayı saymıyor (yalnızca log tutarsızlığı mı, bakılacak).
- **Kablo çekilince `adb reverse` tünelleri de gidiyor;** kablo geri takılınca tablet kendiliğinden bağlanamıyor. `scripts/usb-mode.sh on` yeniden çalıştırılmalı (denemede bir izleme döngüsü bunu otomatik yaptı). Faz 4 notu: USB modu kullanıcı için kendini onarmalı.
- **Siyah ekran (yeni hata, T-028):** tablet 10 sn'lik ekran bekleme süresi içinde yeniden bağlanırsa (`display_reused`) hiç kare çözmüyor: tablet `recv>0 dec=0`, `output_format` yok, anahtar kare isteği yok. `am force-stop` + 2 sn + `am start` ile 3/3 tekrarlandı; 15 sn bekleyince (`display_created`) 3/3 çalışıyor. Geçici çözüm: 15 sn beklemek.
- **Ölçüm notu:** host'un `stats fps=0.0 ... sent_frames=0` satırları durağan ekranda normal; siyah ekranı ayıran şey tabletin `MB/decoder` satırındaki `recv` ile `dec` farkı.
- **"Kalem bir süre algılanmadı, sonra upuzun düz çizgi" (kullanıcı, ~17:0x–17:12, serbest çizimde; tekrarlanmadı):** kayıtta yeri bulunamadı. Ham kalem kaydı (`getevent`, 16:47–17:20, 255+ temas): temas içinde 30 ms'den uzun boşluk yok (kablo çekme anı hariç). Tablet her saniye ~360 örneği mesaj olarak göndermiş (`refused=0`, `*_stale=0`). "Kalem temas hâlinde hareket ediyor ama Mac ekranı değişmiyor" taraması (çekirdek kaydı × host `cadence cap`, 1 sn çözünürlük, 254 saniye) yalnızca bilinen anları veriyor (kablo çekme, bildirim paneli denemeleri). Host tek tek kalem olaylarını loglamadığı için Krita'ya ne gittiği görülemiyor: **kör nokta**. Öneri: host'ta vuruş başına özet (olay sayısı, en uzun olay aralığı, en büyük konum sıçraması) `info` düzeyinde.
- **Bildirim paneli, kalem basılıyken (17:10:49):** Android uygulamaya `Motion Cancel` veriyor (panel açılmadan 1,3 sn önce), tablet `flags=0` + `RELEASE_ALL(2)` gönderiyor; panel kapanınca `input_resume`. Kullanıcı tekrar denedi: düz çizgi ya da takılı girdi yok.
- **Ekran yakalama kendiliğinden durdu (17:05:41):** `pipeline_failed` SCStream `-3817` ("Kullanıcı duraksız yayını durdurdu"); host 1,2 sn'de `pipeline_retry` → `display_created`, bu sürede `input_release cause=gate_lost` ve `no_display=7` mesaj atıldı. Hemen öncesinde kalem ekranın sağ üst köşesine (menü çubuğu) kısa dokunuşlar yapmış: büyük olasılıkla menü çubuğundaki ekran kaydı göstergesinden yayın durduruldu. Kurtarma çalıştı.
- **Düz çizgi, kayıtlı tekrar (17:26:48–17:28:21):** Mac'te dinleme amaçlı bir olay kaydedici (`CGEventTap`, listen-only, yalnızca fare/tablet olayları; repo dışında, scratch) çalışırken kullanıcı "şimdi oldu" dedi. Karşılaştırma: tabletin ham kalem kaydındaki 69 temasın 69'u Mac'e ulaşan bir vuruşla eşleşiyor; başlangıç/bitiş konumları aynı, olay sayısı n+1 (down), hız 360/sn, vuruş içinde 60 ms'den uzun boşluk ya da 25 pt'den büyük adım yok. **Bu tekrar için MateBridge yolu (tablet → host → pencere sunucusu) temiz.** Tuvaldeki yeni düz çizgilerin hepsi kalemin gerçekten temas hâlinde izlediği yolun üstünde (kayıt, ekran görüntüsüne bindirildi). Kalan adaylar: Krita (2,9 GiB belge, "Pencil-5 Tilted" 40 px; takılıp olayları birleştirmesi) ya da kullanıcının hangi çizgiyi kastettiği. 17:23'teki ekran görüntüsünde sağ alta inen iki çizgi bu kayıttan önce oluştu; onlar açıklanmadı.
- **Düz çizgi, ikinci kayıtlı tekrar (17:29–17:33:36, yeni 55 MiB belge):** yine 145 temasın 145'i Mac'e birebir ulaşmış (konum sıçraması, boşluk yok). Bu kez tuvalde **kalemin hiç gitmediği bir çizgi** var: baş bölgesinden (≈755,295 pt) sağ üste (≈848,177 pt ve ötesi) uzanan ince düz çizgi; o koordinatlarda Mac'e hiç olay gitmemiş. Son vuruş (17:33:32.0–35.7, 1323 olay) çizginin başladığı noktadan defalarca geçiyor. Yani çizgiyi Krita üretiyor; belge boyutu neden değil. **Hipotez (doğrulanmadı):** Krita'nın "Basic" fırça yumuşatması teğetleri olaylar arası zamandan hesaplıyor; 360 Hz'de olaylar arası süre 0–1 ms'ye düşebiliyor (alım aralıkları: %5,5'i ≤1 ms, %0,3'ü 0 ms) ya da Krita takılıp olayları topluca işliyor → teğet patlıyor → hareket yönünde uzun düz "diken". Host, CGEvent zaman damgasını ayarlamıyor (gönderim anı). Sınama: Krita'da Fırça Yumuşatma = Hiçbiri. Olası host önlemleri (karar gerekir): olay zaman damgasını tabletin örnek zamanından üretmek ya da kalem olay hızını sınırlamak.
- **Düz çizgi ("diken"), üçüncü kayıtlı tekrar — tetikleyici yakalandı (18:00:47):** Krita "Fırça Pürüzsüzleştirme = Yok" ile 12 dk / 224 vuruşta diken yok; "Temel"e dönünce 18:00:47'de boş alana doğru ≈155 pt'lik belirgin bir diken çıktı (vuruşun kendi hareketi ≈37 pt, diken aynı yönde). Ham kalem kaydı ve Mac olay kaydı aynı şeyi gösteriyor: kalem **8 ms'lik tek örneklik bir temas** yaptı (basınç 76/16384 ≈ %0,5, hareket yok), 22 ms kalktı, 3 pt ötede yeniden değdi (basınç 236 ≈ %1,4) ve vuruş oradan sürdü. Host bunu olduğu gibi iletti: `down` (press 0,004) → 7,7 ms sonra `up` → hover → 21 ms sonra `down` → sürükleme. Diken, bu ikinci vuruşun başından çıkıyor. Yani kalem ucu "sekiyor", Krita da tek noktalık vuruşun hemen ardından gelen vuruşta (Temel yumuşatma) taşıyor.
  - Sınırlar: "Yok" döneminde tek örneklik temas hiç olmadı (en kısa vuruş 8 olay), bu yüzden "Yok" ayarının dikeni önlediği kanıtlanmış değil. Temel dönemde bir tek örneklik temas daha var (17:52:39), kullanıcı orada diken bildirmedi. 17:33'teki diken için kayıtta böyle bir sekme yok (önceki vuruşla arası 570 ms): o açıklanmadı. Olay zaman damgaları: ardışık sürükleme olaylarının %1,5'i aynı ms'de, %11,8'i 1 ms arayla; 30 ms'den uzun boşluk yok.
  - Hızlı kalk-değ (≤60 ms) çok yaygın (35 dakikada ~65 kez) ve çoğu zararsız; ayırt edici olan ilk temasın tek örnek olması.
  - Olası önlemler (karar gerekir): (a) tablette temas eşiği — çok düşük basınçlı örnekleri (ör. <%1) hover say; (b) çok kısa temastan hemen sonraki yeniden temasın tek vuruşta birleştirilmesi (pen-up'a ~30 ms gecikme ekler); (c) yalnızca belgeleyip Krita'da yumuşatma ayarı önermek. Önce `--inject-test` ile aynı olay dizisini Krita'ya verip dikeni isteğe bağlı üretmek gerekir.
- **Diken isteğe bağlı üretildi (18:1x, kullanıcı onayıyla yapay olay):** 18:00:47'deki kayıtlı olay dizisi (hover → tek örneklik temas → 21 ms → vuruş; 541 olay, özgün zamanlamayla) host'un `CGEventFactory` alanlarıyla aynı biçimde boş bir Krita belgesine yeniden oynatıldı (scratch aracı, repo dışında). Sekmeli dizi: 23 oynatmanın 3'ünde diken (biri vuruşun gerisine doğru ≈100 pt, ikisi tuval boyunca çok soluk uzun çizgi; belge belleği 40 MiB → 764 MiB). Sekme çıkarılmış aynı dizi (ilk `down`/`up` atıldı): 23 oynatmanın 0'ında. Örnek küçük (Fisher p≈0,12) ama özgün olayla aynı yönde: **tek örneklik temas + hemen ardından vuruş, Krita "Temel" yumuşatmada dikeni tetikliyor; olasılıksal (~%13).** Sekmesiz dizi, "tek örneklik teması hiç iletme" düzeltmesinin üreteceği şeyle aynı.
- **Siyah ekran kök nedeni ve düzeltme (T-028 → T-030, 18:35):** yeniden kullanılan ekranda host `[CODEC_CONFIG, keyframe]`'i hemen gönderiyor; tablet `STREAM_CONFIG`'i UI iş parçacığında sonradan uygularken (`queue.reset(keepConfig = false)`) config'i atıp `KEYFRAME_REQUEST(STARTUP)` istiyor; host config'i yeniden göndermiyordu. T-030: STARTUP/DECODE_ERROR isteğinde config keyframe'den önce yeniden gönderilir (Codex iki ek yarış buldu, düzeltildi). Cihazda hızlı yeniden bağlanma 5/5: `codec_config_resent reason=0`, `output_format`, durağan ekranda `dec=1 shown=1`.
- **T-029 cihazda (18:38):** yeni APK ile yapay kalem olayları (`adb shell input stylus swipe|tap`, repo dışı): 300 ms'lik kaydırma Mac'te tek vuruş olarak çıktı; anlık dokunuş (DOWN+UP, hareket yok) iki denemede de `bounce_dropped=1` ile atıldı ve Mac'e temas gitmedi. `adb shell input stylus …` tablette kalem girdisini pensiz sınamak için kullanılabiliyor (hover üretmez, basınç 1,0).
- **Host yeniden başlatılınca Krita'nın pencere düzeni bozuluyor** (sanal ekran kapanıp açılırken pencereler 1920×1080 yedek ekrana taşınıp geri geliyor; paneller kayıyor). Faz 4 notu: host yeniden başlarken ekranı mümkünse yeniden kullanmalı ya da kullanıcı uyarılmalı.
- **Diken T-029'dan sonra da çıktı (18:49:57, "Temel"):** yeni APK ile 41 vuruşta bir diken (vuruş başından hareket yönünde ≈127 pt). Bu kez **sekme yok**: `bounce_dropped=0`, önceki vuruşla arası 470 ms, en kısa vuruş 5 olay. Mac'e giden olaylar yine temiz (konum sıçraması yok, vuruş başı diğer vuruşlarla aynı desen: 3–4 örnek aynı noktada, sonra yavaş hareket). **Sonuç: sekme dikenin gerekli koşulu değil.** 17:33'teki sekmesiz diken ve bu olay aynı türden; 3/23'e karşı 0/23'lük oynatma sonucu büyük olasılıkla tesadüftü (p≈0,12 idi). T-029 zararsız bir süzgeç olarak kalıyor (8 ms'lik temas zaten istenmeyen bir nokta), ama dikenin çözümü değil; karar 0007'ye not düşüldü.
  - Güncel hipotez (doğrulanmadı): Krita "Temel" yumuşatmada teğeti kendi işlem saatine göre hesaplıyor (`kritarc`: `useTimestampsForBrushSpeed=false`, "Use tablet driver timestamps for brush speed" kapalı). Vuruş başında Krita kısa süre takılırsa kuyrukta biriken olaylar art arda, neredeyse sıfır aralıkla işlenir → teğet patlar → hareket yönünde diken. 360 Hz'lik olay akışı bunu sıradan tabletlere göre daha olası kılar. Sınanacak: (1) sekmesiz diziyi "Temel"de 60+ kez oynatıp taban oranı ölçmek, (2) aynı şeyi "Yok" ile, (3) sürücü zaman damgası ayarı açıkken, (4) host'ta olay hızını düşürerek (ör. 180 Hz).
- **Arka plan izleyicisi 18:50'de süresi dolduğu için durdu** (2 saatlik sınır): kablo çekilirse `adb reverse` tünelleri kendiliğinden kurulmaz, tablet log'u sürekli kaydedilmiyor (gerekince `logcat -d` ile çekilir). Mac olay kaydedicisi çalışıyor.
- **Diken ölçümü (19:00–19:25, yapay oynatma, Krita 5.3.4, "Pencil-5 Tilted" 40 px):** 18:00:47'deki kayıtlı vuruş (sekmesiz) 12×5 ızgarada 60 kez oynatıldı; tuvalden çıkan soluk çizgiler ekran görüntüsünden sayıldı (scratch: `batch.sh`, `lines.py`; eşik gri<253, çizgiler çoğunlukla çok soluk).

  | Durum (60 vuruş) | Diken |
  |---|---|
  | Temel, tam hız (5 tur) | 7, 8, 9, 8, 3 |
  | Temel, sekmeli dizi | 8 |
  | Temel, olayların yarısı (180 Hz) | 15 |
  | Temel, olayların üçte biri (120 Hz) | 20 |
  | Temel, olaylar arası en az 2,5 ms | 3 |
  | **Yok (pürüzsüzleştirme kapalı), 2 tur** | **0, 0** |

  Sonuçlar: (1) diken Krita'nın "Temel" pürüzsüzleştirmesinde oluşuyor, "Yok"ta 120 vuruşta sıfır; (2) sekme etkisiz (T-029 bu sorunun çözümü değil); (3) olay hızını düşürmek kötüleştiriyor; (4) çoğu diken vuruşun **sonundan**, son hareket yönünde tuval kenarına kadar uzanıyor, birkaçı vuruş başından geriye; çoğu soluk (uçta basınç düşük), kullanıcının gördükleri koyu olanlar. Önceki "23'te 3'e karşı 0" sonucu eşik yüzünden soluk dikenleri saymıyordu. Olası mekanizma (Krita kaynak kodundan hatırlanan, doğrulanmadı): `KisToolFreehandHelper::finishStroke` teğeti son iki noktanın zaman farkına bölüyor ve bu fark sıfıra yakınken taşıyor. Sınanacak: "tablet sürücüsü zaman damgaları" ayarı; vuruş sonundaki aynı-konumlu örneklerin etkisi.
  Devam (19:30–19:50, 60'ar vuruş, "Temel"): sürücü zaman damgaları açık (`useTimestampsForBrushSpeed=true`): 8, 5. Aynı-konumlu örnekler atılmış: 4, 5. Bırakıştan sonra hover yok: 9. Bırakış basıncı korunmuş: 5. Geç kontrol (değişiklik yok): 3. Hepsi tam hız turlarının gürültü bandında (3–9): **denenen hiçbir olay-akışı değişikliği (hız, aralık, sekme, yinelenen konum, bırakış biçimi) ve Krita'nın zaman damgası ayarı dikeni gidermiyor; yalnızca pürüzsüzleştirmeyi kapatmak gideriyor.** Host/tablet tarafında düzeltme yok. Öneri: Krita'da "Fırça Pürüzsüzleştirme = Yok" (360 Hz'de çizgi zaten düzgün). Denenmeyenler: "Ağırlıklı"/"Sabitleyici" kipleri, başka fırça, başka uygulama. Mac olay kaydedicisi 19:4x'te süre sınırından durdu.

## 2026-09-30 — Krita çift dokunma: kök neden bulundu (T-027)

- **Krita tablet olay günlüğü** (Krita Terminal'den `QT_LOGGING_RULES="krita.tabletlog.debug=true"` ile başlatıldı, `Ctrl+Shift+T`): tuvale gelen `TabletPress` olaylarında çift dokunmadan sonra işaretçi `Eraser`, öncesinde `Pen`; yani host'un silgi bildirimi Qt'ye doğru ulaşıyor. Ama **her olayda cihaz türü `NoDevice`, `id: 0`**.
- **Neden:** Qt 5.15 macOS (`qnsview_tablet.mm`, `wacomTabletDevice`) cihaz türünü yakınlık olayının `vendorPointingDeviceType` alanından çıkarıyor (0 ise ve `uniqueID` da 0 ise `NoDevice`). Host bu alanı doldurmuyordu. Krita'da `KoInputDevice::isMouse()` cihaz türü `Unknown` olan her girdiyi fare sayıyor ve `KoToolManager::Private::switchInputDevice` fareden fareye geçişi yok sayıyor → `inputDeviceChanged` hiç yayılmıyor → silgi fırçasına geçiş olmuyor. `kritarc`'ta yalnızca `LastPreset_-1` (fare) bulunması da bununla tutarlı. Tablet Sınayıcı yalnızca işaretçi türünü gösterdiği için "eraser" diyordu.
- T-027 kartındaki "Qt `vendorPointingDeviceType` 0 olsa da cihazı Stylus sayıyor" varsayımı **yanlıştı**.
- **Düzeltme:** yakınlık olayına Wacom tipi `vendorPointerType` (kalem 0x0802, silgi 0x080A; ikisi de Qt'de `Stylus`) ve sıfırdan farklı sabit bir `uniqueID` → T-031. Beklenen yan etki: Krita kalemi artık gerçek tablet cihazı sayacak; kalemin ilk kullanımında fırça Krita'nın o cihaz için hatırladığı ön ayara (ilk seferde varsayılan "b) Basic-5 Size Opacity") geçebilir, sonra cihaz başına hatırlanır.
- Açık soru: kalem Krita'da "fare" sayılırken ölçülen "Temel" pürüzsüzleştirme dikeni (yukarıda) bu düzeltmeden etkilenebilir; T-031 sonrası isteğe bağlı yeniden ölçülebilir.
- **T-031 cihazda (20:30):** Krita günlüğünde artık `Stylus Pen id: 331825038670`; `kritarc`'a `LastEraser_331825038670` yazıldı. Kullanıcı: çift dokunma silgiye geçiriyor ve geri döndürüyor. T-027 kapandı.
- **T-025 kontrolleri (20:30):** arka plandan dönüşte ilk parmak dokunuşu tık üretti. Parmakla sekme sürüklerken kalem yaklaşınca parmak işlevini kaybetti ve kalem devraldı (kalem önceliği; zıplama bildirilmedi). Aynı saniyede tablet `pen_samples=81 touch_msgs=92`. Host olay başına log tutmadığı için devralmanın hover'da mı (Android'in parmağı iptal etmesi) yoksa temasta mı (host'un kalem önceliği) olduğu ayırt edilemedi.
- **Eğim (20:4x):** kullanıcı "Pencil-5 Tilted" ile eğimin çizgiyi değiştirdiğini doğruladı.
- **Vuruş ortasında force-stop (20:47:33):** kullanıcı çizerken (tablet `pen_samples=361/sn`, temas sürüyor) `am force-stop dev.matebridge.client`. Host: `input_release cause=disconnected events=2 pen_up=1 pen_leave=1`; basılı kalan yok. `input_session_end released=0` sayaç tutarsızlığı yine görüldü (kablo çekmedeki gibi).

## 2026-09-30 — İki parmakla yakınlaştırma: araştırma (Faz 3, kart yok henüz)

- macOS'ta genel bir "yakınlaştırma hareketi" CGEvent API'si yok. Mac Mouse Fix (`Helper/Core/Touch/TouchSimulator.m`) yalnızca alanlarla sahte hareket olayı üretiyor: tip 29 (`NSEventTypeGesture`), alan 110 = 8 (HID zoom), alan 132 = faz (1 başla, 2 sürüyor, 4 bitti, 8 iptal), alan 113 = büyütme farkı; `kCGHIDEventTap`'e gönderiliyor. macOS 27'de alan tabanlı dock kaydırmaları bozulmuş (MMF issue #1876); büyütmenin 27'de çalıştığı doğrulanmadı → önce kısa bir deneme (scratch `magnify-spike`, gerçek olay gönderir, kullanıcıyla birlikte).
- Qt 5.15 (`qnsview_gestures.mm`): yalnızca "sürüyor" fazı `ZoomNativeGesture` olur; iptal fazının karşılığı yok (Krita'da hareket kapanmaz) → host her zaman "bitti" ile kapatmalı. Yakınlaştırma merkezi olay konumu değil imleç konumu → host başlangıçta imleci iki parmağın ortasına taşımalı. Krita'nın varsayılan profili macOS büyütme hareketini tuval yakınlaştırmaya bağlıyor.
- Yedek yol: Krita'da fazsız tekerlek olayı yakınlaştırır; Safari/Preview'da Cmd+= / Cmd+-.
- Olası tel mesajı (protokol değişikliği, orkestratör): `PINCH { phase u8, scale_delta f32 (d_şimdi/d_önceki − 1), center_x u16, center_y u16 }`.

## 2026-09-30 — Faz 3 ilk cihaz testi (T-032, T-033, T-034)

- Kullanıcı: klavye (Türkçe karakterler, `"`, `<`, AltGr+Q, Ctrl→Cmd kısayolları, tekrar, Caps Lock), touchpad (tık, dokunarak tık, sağ tık, iki parmak kaydırma, sürükleme), Bluetooth fare ve kalem/parmak **hepsi çalışıyor**. Arka plana alınca basılı kalan tuş yok.
- Sorunlar: (1) touchpad ve fare ile imleç fazla hızlı/hassas; (2) MateBridge'den Android'e dönülemiyor (önceden klavyedeki Esc Android'e BACK olarak gidiyordu; artık Mac'e gidiyor ve touchpad capture altında). → T-035.
- **Büyütme denemesi (21:45, macOS 27.0.1, Krita 5.3.4):** scratch `magnify-spike` (tip 29, alan 110 = 8, 132 = faz, 113 = değer; `kCGHIDEventTap`) Krita tuvalinin üstünde began + 25 × changed(0,04) + ended gönderdi: yakınlaştırma %176,3 → %452,0 (beklenen ≈ 1,04^25 × 176 ≈ %470). **Alan tabanlı büyütme macOS 27'de çalışıyor.** → karar 0009, PINCH (protokol `proto/pinch` dalında), T-036/T-037.
- **Yakınlaştırma cihazda (22:1x):** kullanıcı: dokunmatik ekranda iki parmakla yakınlaştırma ve kaydırma doğru çalışıyor; `Ctrl+Shift+Esc` Android'e döndürüyor. Glide Keyboard'da F tuşları yok → F1/F2/F3 kısayolları kullanılamıyor → T-038 (Ctrl+Shift+8/9/0).
- **Güvenlik (22:3x):** `scripts/usb-mode.sh` adb sunucusunu `-a` ile başlatıyordu: `lsof` → `TCP *:5037 (LISTEN)`, yani ev ağındaki herkes tablete adb ile erişebilirdi. Çalışan sunucu `-a`'sız yeniden başlatıldı (`127.0.0.1:5037`), tüneller geri kuruldu, tablet yeniden bağlandı. Kalıcı düzeltme T-039 dalında (betik + host bekçisi, `-a` yasak testi).

## 2026-09-30 — Oturum şifrelemesi cihazda (T-041, T-042)

- Protokol v1 kuruldu (host + APK). İlk bağlantı PAIRING: tablet "Mac'teki kodla aynı mı? 872 536", Mac onay penceresi aynı kod. Kullanıcı başsız Mac'teki pencereyi göremedi (Mac ekranı onaydan önce tablete gelmiyor; Parsec'e geçince MateBridge arka plana düşüp BYE gönderiyor, pencere kapanıyor; iki deneme 60 sn süreyi doldurdu). Orkestratör kodları karşılaştırıp Erişilebilirlik ile "İzin ver"e bastı → `approval_approved`, `session_started`, Anahtar Zinciri'nde `dev.matebridge.host.pair` öğesi, tablette şifreli görüntü `dec=9 shown=9`. Uygulama yeniden başlatılınca `mode=paired` (kodsuz). Eşzamansız anahtar araması (Codex 2. tur düzeltmesi) sonrası da PAIRED çalışıyor. → T-043 (ön onay, Parsec'ten onay).
- Açılışta `host_identity_replaced` (ilk v1 açılışı; eski onaylar silindi) beklendiği gibi.
- **Bağlantı koptuktan sonra onay cihazda (23:57, T-043/T-044):** menüden "Onaylı cihazları unut" (AX) → tablet PAIRING, iki tarafta aynı kod → tablet Home ile arka plana → Mac penceresi açık kaldı ("Tablet ayrıldı…") → İzin ver → host anahtarı sakladı (`orphan_pairing_stored`) → tablet uygulaması açılınca `mode=paired`, şifreli görüntü akıyor. Kullanıcının akışı: kod görünce Parsec'e geç, Mac'te İzin ver, MateBridge'e dön.
- Not: `NSPanel` onay penceresi, uygulama öne alınmadan AX'te görünmüyor (`count of windows = 0`); `set frontmost` sonrası okunuyor.

## 2026-10-01 — 120 fps ölçümü (Faz 5, T-045)

Kurulum: USB, host `MATEBRIDGE_FPS=120` (sanal ekran 120 Hz, SCK 1/240 s), içerik: scratch `anim` (CADisplayLink 120 Hz'te kayan kutu; Safari rAF 120 Hz ekranda bile 61 fps'te kalıyor, ölçüm için kullanılamaz). Ölçüm: host `cadence`, tablet `MB/decoder` istatistikleri, `dumpsys SurfaceFlinger --latency` video katmanı.

| | 60 fps (varsayılan, Safari içeriği) | 120 fps (anim) |
|---|---|---|
| Mac yakalama | 60,0 | **120,0** (geç 0) |
| Mac kodlama | 60, 13,5 ms | **~99 fps**, 20 ms, `enc_behind` ≈ 21/sn → **kodlayıcı darboğaz** |
| Tablet alınan / çözülen / gösterilen | 60 / 60 / 55–60 (drop 0–5) | ~99 / 75–97 / 67–96 (drop 1–32) |
| Tablet panel vsync (video oynarken) | **16,67 ms (60 Hz)** | **16,67 ms (60 Hz)** |

- Tablet durağan ekranda 120 Hz (8,33 ms) raporluyor, ama video katmanı güncellenirken HarmonyOS paneli 60 Hz'e indiriyor (29 Eylül bulgusuyla aynı). Tablet üreticinin ölçümü: HEVC çözücü 1080p 258 fps, 4K 71 fps → 2800×1840'ta kabaca 105–115 fps.
- Sonuç: bugün uçtan uca 120 fps **yok**; üç engel: (1) panel video sırasında 60 Hz (denenmemiş: `Surface.setFrameRate(120, FIXED_SOURCE)`), (2) Mac HEVC kodlayıcısı bu çözünürlükte gerçek zamanlı ayarla ~100 fps, (3) tablet çözücüsü sınırda.
- 60 fps'te gösterim aralıkları çoğunlukla 16,7 ms, arada 33/50 ms (kaçan vsync) → takılmanın kaynağı; kare zamanlaması işi.
- **120 Hz isteği (T-046 deneme APK'sı, 00:15):** `set_frame_rate rate=120 fixed_source strategy_always`, `display_mode requested_hz=120` uygulandı; SurfaceFlinger `sfFps 120` görüyor, ama Huawei `AGPService FrameRateManager`: `strategyCode 60120 … JudgeFinalLcdFps sceneinfo(0,-2,0,0) … isSurface 1 … final lcd fps: 60`. Panel video sırasında 60 Hz'te kaldı (`display_hz=60 vsync_ms_p50=16.67`). Karşılaştırma: `com.huawei.appmarket` kaydırmada `sceneinfo(120,4,2,0)` ile 120 Hz. Sistem dosyalarında politika dosyası bulunamadı (büyük olasılıkla servis içinde/bulut). → T-048 (TextureView deneyi). Not: bu denemede Mac kodlayıcısı 73 fps'e düştü; aynı anda T-047 tezgâhı çalışıyordu (medya motoru paylaşımı).
- **Kodlayıcı 120 fps'e yetişiyor (T-047, 00:4x):** tezgâh: 2800×1840'ta ~100 fps tavanı düşük gecikmeli hız denetiminden (LLRC); LLRC kapalı + `RealTime=false` → en çok 174 fps, 120'de kodlama 5,8 ms. Canlı (`MATEBRIDGE_FPS=120`, anim): yakalama 120,0, **kodlama 120,0 fps, 8,2 ms**, `enc_behind=0`. Tablet: alınan ~120, çözülen **63–104**, gösterilen 53–95, `drop` 26–74/sn; panel 60 Hz. **Kalan engeller tablette:** çözücü (uygulama çözücüye büyük olasılıkla tek kare verip çıkışı bekliyor → verim ≈ 1/gecikme ≈ 65–70 fps; donanımın CTS ölçümü ~105–115 fps) ve Huawei'nin 60 Hz kararı (T-048).
- Yan bulgu: LLRC'siz yapılandırma 60 fps'te de kodlama süresini ~13,5 ms'den ~6–8 ms'ye indirebilir (gecikme kazancı); canlı ölçülmedi.
- **Huawei 120 Hz kuralı bulundu (01:0x, T-048 deneyi):** `FrameRateManager` bizim paket için `strategyCode 60120: min 60, max 120, idle 60`. Dokunma yokken `touchinfo(1,1,3,60)` → **60 Hz**; ekrana dokunma/kaydırma sırasında `touchinfo(1,0,0,120)` → **120 Hz** (`display_hz=120`, `vsync_ms_p50=8.33`). Bu **SurfaceView yolunda da aynı**; TextureView (`render=texture`) fark yaratmadı (`isSurface 1` her iki yolda). Yani panel, kullanıcı tablete dokunurken/çizerken 120 Hz, yalnızca izlerken 60 Hz. 120 fps akışta dokunma sırasında tablet 103–110 fps çözüp gösteriyor (drop 12–20/sn), boşta ~90.
- Sonuç: TextureView yolu gerekmiyor (T-048 dalı merge edilmedi). 120 fps akış, çizim sırasında ~100–110 fps gösterir; 120 Hz panelde düzensiz (bazı kareler 1, bazıları 2 vsync) ama gecikme ve hareket çözünürlüğü daha iyi. Karar kullanıcının gözüne kalıyor.
- **Kullanıcı karşılaştırması (01:2x):** tablet ayarı "Orta" (120 Hz'e kadar) da "Dinamik" gibi: dokunma yokken 60 Hz, dokunurken 120 Hz. Kullanıcı: **"120 çizim sırasında daha akıcı"** (60'a göre). Host şimdilik `MATEBRIDGE_FPS=120` ile çalışıyor (elle başlatıldı; yeniden başlatmada 60'a döner). İstek: performans modu (düşük çözünürlük, daha düzgün 120 ya da 144) → protokol `STREAM_PREFS` (`proto/stream-prefs`), T-049/T-050.

## 2026-10-01 — Performans modu cihazda (T-049, T-050)

Host `STREAM_PREFS` ile yeniden yapılandırıyor; içerik: scratch `anim` (120/144 Hz), tablet dokunması `adb shell input swipe` ile.

| Mod | Mac yakalama/kodlama | Tablet çözülen/gösterilen | Gecikme |
|---|---|---|---|
| Akıcı (120, 2800×1840) | 120 / 120, 8,6 ms | ~107 | ~18 ms |
| Performans (120, 2100×1380) | 120 / 120, 5,7 ms | **~120** | **~12 ms** |
| Performans 144 (144, 2100×1380) | 144 / 144, 6,9 ms | ~140 | ~13–17 ms |

- Tablet ayarı ve panel: **Dinamik**: boşta 60 Hz, dokunurken 120 Hz (144 isteğinde de 120). **Orta**: boşta ve (adb swipe ile) dokunurken 60 Hz — önerilmez. **Yüksek**: boşta 60, dokunurken 120; 144 Hz video uygulamasına hiç verilmiyor. → Performans 144 modu kaldırıldı; önerilen: tablet "Dinamik", mod Performans (çizim/oyun) ya da Akıcı/Netlik (yazı).
- ScreenCaptureKit, sanal ekran hangi yenileme hızıyla yaratıldıysa o hızda veriyor; yerinde mod değişimi (60→120) yakalamayı hızlandırmıyor. Host yenileme değişiminde ekranı yeniden yaratıyor (`display_recreate reason=refresh_change`) ve her cihazın son tercihini hatırlıyor (`from_stored=true`), böylece yeniden bağlanmada ekran yeniden yaratılmıyor.
- **T-051 ölçümü (01:07–01:08, kullanıcı, gerçek touchpad/fare/kalem, Performans modu, tablet "Dinamik"):** touchpad ve fare ile sürüklerken panel **120 Hz**, gösterim 105–117 fps (`rel_msgs` ~115–119/sn); kalemle 120 Hz, 119–121 fps (`pen_samples` 360/sn); hareket bitince 60 Hz. Yani Huawei fareyi/touchpad'i de etkinlik sayıyor; önceki "68–70 fps" gözlemi tam boyutlu Akıcı moddaki çözücü sınırı ve/veya "Orta" ayarıyla ilgiliydi. Touchpad/fare ile ~112 fps, Mac'teki pencerenin fare olay hızında (~117/sn) güncellenmesinden. Ek iş gerekmiyor.

## 2026-10-01 — Takılma ölçümü (Performans 120, dokunma ile panel 120 Hz)

İçerik: `anim` (120 Hz). Ölçüm: `dumpsys SurfaceFlinger --latency` video katmanı sunum aralıkları (~1,2 sn pencere), host `cadence`.

| İstemci tamponu (`--ei jitter N`) | 8,3 ms | 16,7 ms (atlanan vsync) | 33 ms | ek gecikme (`pace_add`) |
|---|---|---|---|---|
| 0 (varsayılan) | 99 | 26 (%21) | 0 | 0 |
| 1 | 98 | 27 (%21) | 0 | 8,35 ms |
| 2 | 123 | 0 | 2 | 16,7 ms |

- Host kusursuz: yakalama aralığı p50/95/99 = 8,3/8,3/8,3 ms, varış 8,3/8,9/9,6 ms, kodlama ~6–7 ms, tablet `drop=0`. **Takılma tablette sunumda**: çözme süresi (~9–12 ms, vsync'ten uzun) dalgalanınca iki kare aynı vsync'e düşüyor, ardından bir vsync boş kalıyor. 2 karelik tampon gideriyor ama +16,7 ms. 1 karelik tamponun hiç etkisiz olması şüpheli (pacer hatası olabilir). → T-052 (uyarlanır kare zamanlaması). Kullanıcı: "demo animasyonlarda takılma çok göze batıyordu … performans modu akıcı görünüyor".

## 2026-10-01 01:35 — HATA (orkestratör): kurulum betiği istenmeyen uygulamalar kurdu

- Gece kurulumu kullanıcısız yapmak için yazılan scratch `install.sh`, `uiautomator` ekranında "DEVAM ET" **ya da "YÜKLE"** metnine basıyordu. Paket yükleyicinin "DEVAM ET" düğmesine doğru bastı, ardından **Huawei AppGallery'nin risk denetimi ekranındaki (`InstallDistActivity`) önerilen uygulamaların "YÜKLE" düğmelerine** de bastı. Tablete kuruldu: `com.live.soulchill`, `com.alibaba.intl.android.apps.poseidon`, `ctrip.english`, `com.dreamgames.royalmatch.huawei`, `com.zhiliaoapp.musically` (TikTok). `com.huawei.appmarket` zorla durduruldu; sonra yeni kurulum olmadı. `com.live.soulchill` daha sonra listede görünmedi (yarım kalmış olabilir). **Kalan dört uygulamanın kaldırılması kullanıcıya bırakıldı** (otomatik kaldırmaya izin verilmedi).
- Betik düzeltildi: yalnızca `com.android.packageinstaller` içindeki `android:id/button1` "DEVAM ET"e basar; AppGallery'de hiçbir şeye basmaz. Ders: ekran otomasyonunda metinle değil paket + kaynak kimliğiyle eşleştir; mağaza ekranlarına asla dokunma.

## 2026-10-01 — Uyarlanır kare zamanlaması cihazda (T-052)

Performans 120, `anim`. SurfaceFlinger sunum aralıkları (~125 kare) ve `MB/render`:
- Önce (tampon yok): 16,7 ms atlama **%21**. Sabit 2 kare tampon: %2, +16,7 ms.
- T-052 (çıkış ayrı iş parçacığında, uyarlanır D, doğru atlama ölçümü, histerezis): 120 Hz'te (dokunma) atlama **%1–3**, `pace_ms` 7–16 ms (çoğunlukla ~8–12), çözme p95 ~10–14 ms. 60 Hz'te (boşta, 120 fps akış) D sınırlı, gecikme ~15 ms, kareler bilinçli olarak atılıyor (en yeni kazanır).
- `KEY_OPERATING_RATE` / `KEY_PRIORITY` HiSilicon çözücüsünde kabul edilmiyor (`unset`). Oluşturma zaman damgaları (`OnFrameRenderedListener`) gerçek gösterim zamanı değil; atlama ölçümü pacer'ın kendi planından.

## 2026-10-01 — Pano paylaşımı cihazda (T-054, T-055) ve kurulum betiği

- Mac → tablet: `pbcopy` ile 34 baytlık Türkçe metin → host `ev=clipboard dir=out bytes=34`, tablette `DistributedPasteboardService Clipboard is written by :dev.matebridge.client`. Tablet → Mac: kullanıcı kopyalaması gerektiği için denenmedi.
- Codex (medium): 2 P1 (Mac'te gizli içerik yarışı → tutarlı anlık görüntü; gelen pano yazmaları için sınırsız kuyruklar → en-son-değer kutusu) ve 2 P2 (tablette oturum sonrası yazma, yeniden bağlanmada yinelenen filtre) düzeltildi.
- Kurulum betiği (scratch `install.sh`) kullanıcının tarifiyle: yalnızca `com.android.packageinstaller` `android:id/button1` ("DEVAM ET") ve AppGallery sayfasında yalnızca alt "YÜKLE" (`com.huawei.appmarket:id/hidden_card_install_button_continue`), kimlikle eşleşerek. Denendi: iki dokunuş, kurulum başarılı, fazladan uygulama yok. Kullanıcı yanlışlıkla kurulan uygulamaları sildi.

## 2026-10-01 ~02:20 — Takılma: güncel ölçüm ve gpt-6-astra danışması

- Güncel (T-052/T-056 sonrası, Performans 120, `anim`): 120 Hz (dokunma) 16,7 ms tekrar %2,4–4,8, `pace_ms` ~8, çözme p95 ~10 ms; 60 Hz (boşta, akış 120 fps) 33 ms boşluk %6–8, arada 25/41/50 ms.
- Kullanıcı gpt-6-astra danışmasına izin verdi (Codex, high). Önerilerin özeti (öncelik sırasıyla): (1) `AdaptivePacer`'da gecikme sınırını son sunum yuvasına uygula, geç kareleri sonraki yuvaya itmek yerine at; `drainOutput`'ta çekilişler arası "çarpışma" önceki bırakmayı geri alamıyor → yuva başına tek bırakma, en fazla bir değiştirilebilir bekleyen çıkış. (2) Faz: Choreographer zamanı sunum ızgarası değil; `Display.getAppVsyncOffsetNanos` hesaba katılmalı, bırakma öncüsü SF'ye göre kalibre edilmeli (FrameTimeline API 33, bu cihazda yok); taban/jitter değişimleri yumuşatılmalı. (3) Panel 60 Hz'teyken host kodlamadan önce 60'a seyreltsin (SCK/ekran 120'de kalır, yeniden başlatma yok) — geçici oran geri bildirimi, STREAM_PREFS'ten ayrı. (4) Çözücü içindeki kare sayısını ölç/sınırla (2/3/4); host `BoundedFrameQueue.push()` delta atınca keyframe isteyip bağımlı deltaları geçiriyor → düzelt. (5) İçerik güdümlü yakalama doğru, kopya kare yok. (6) Bit hızı sıçramalarını ancak kaçırmalarla ilişkiliyse ayarla. (7) SurfaceControl şimdilik değil.
- → T-057 (tablet sunum zamanlaması), T-058 (protokol DISPLAY_RATE + host seyreltme + kuyruk düzeltmesi), T-059 (tablet panel hızını bildirir).

## 2026-10-01 ~03:00 — Sunum zamanlaması (T-057) uzun pencerelerle

Scratch `pace-long.sh` (SF `--latency`, 18–25 sn birikimli), Performans 120, `anim`, dokunma ile 120 Hz.

| Yapılandırma | 8,3 ms | 16,7 ms tekrar | ≥25 ms |
|---|---|---|---|
| main öncesi (T-052) | %88,1 | **%11,5** | %0,5 |
| T-057, öncü P/2 (4,17 ms) | %93,3 | %6,4 | %0,3 |
| öncü 2 ms | %86,3 | %13,0 | %0,6 |
| öncü 5 ms | %94,0 | %5,5 | %0,5 |
| **öncü 6 ms** (3 tur) | %99,8 / %98,7 / %92,5 | **%0,2 / %1,1 / %7,1** | ≤%0,4 |
| öncü 6,5 ms | %95,7 | %4,1 | %0,2 |
| öncü 7,5 ms | %94,9 | %4,8 | %0,4 |
| inflight 3 / 4 | %93,0 / %90,2 | %6,3 / %8,6 | – |

- HarmonyOS değerleri: `appVsyncOffset=1,0 ms`, `presentationDeadline=13,33 ms`. Varsayılan öncü 0,72·P (120 Hz'te 6 ms), 60 Hz'te P/2. `slot_dups=0`, `late_drops≈0`, `in_codec_p95` 2–3.
- 6 ms'de turlar arası fark büyük (%0,2–%7,1): Mac ve tablet 120 Hz saatleri arasında yavaş faz kayması olası → kapalı döngü öncü ayarı (±1 ms) ya da host yakalamasını tablet vsync'ine kilitleme (açık soru).
- 60 Hz boşta (akış 120): 33 ms ve üstü boşluk %2,3–3,1 (değişmedi) → T-058/T-059 seyreltme.

## 2026-10-01 ~04:00 — Ekran hızı geri bildirimi + faz kilidi (T-058, T-059, T-060) ve 60 Hz öncü ayarı

- DISPLAY_RATE çalışıyor: boşta `display_rate hz=60 effective_fps=60`, host `cap_fps=120 enc_fps=60 decimated=60`, yeniden yapılandırma/bağlantı kopması yok; dokununca hemen 120.
- T-059 tek başına: 60 Hz'te 33 ms boşluk bir turda %2,3, bir sonrakinde **%25,6** (her kare ayrı yuvarlanınca yuva sınırında titreşim). T-060 faz kilidi (`phase_lock=1`, `rephase=0`, `slot_dups≈0`) ile %2–4.
- Birleşik `main`'de 60 Hz'te tablet kendi sayaçlarında temiz (`shown=60 drop=0`) ama SF'de %12–18 33 ms boşluk → bırakma öncüsü (P/2 = 8,33 ms) yanlış. Öncü taraması 60 Hz: 3 ms %11,7 · **6 ms %2,4 / 3,2 / 4,6** · 12 ms %4,4 · 14,5 ms %3,7; 120 Hz'te 6 ms %0,2. Sonuç: bu cihazda en iyi öncü her iki hızda **sabit ~6 ms** (sabit bir kilitlenme son anı) → T-061.
- Codex (medium) iki P2 buldu ve düzeltildi: faz kilidinde geç kare kilidi histerezissiz kaydırıyordu (geçmiş yuvaları destekleyen ızgara); host kuyruğunda hayatta kalan yeni keyframe kurtarmayı karşılamıyordu.
- **T-061 (sabit 6 ms öncü) cihazda:** 60 Hz boşta 33 ms boşluk %4,3 / %3,0; 120 Hz tekrar %2,3 (≥25 ms toplam %1,8). Gecenin başına göre: 120 Hz %11,5 → ~%2; 60 Hz %2–25 (faza bağlı) → %3–4, kararlı.

## 2026-10-01 sabah — kullanıcı geri bildirimi (gece işleri sonrası)

- Krita'da çizim akıcı; **yerel kalem izi gereksiz görünüyor** ("herhalde bu özelliği kapatabiliyoruz") → varsayılan kapalı (T-064).
- Pencere sürükleme daha akıcı.
- **Pano: tablet → Mac çalışmıyor**, Mac → tablet çalışıyor (T-063).
- **Yazarken ekran donuyor gibi; imleç hareket edince yazılanlar hemen geliyor; imlecin ilk hareketinde çok takılma** (boşta → hareket geçişi) (T-062). Olası nedenler (doğrulanmadı): (a) host seyreltmesi (T-058): 60 Hz'te ızgaradan önce gelen tek kare **atılıyor, tutulmuyor** → içerik bir kez değişip durursa son kare hiç gönderilmiyor (yazma tek tek değişiklik üretir); (b) tablet `SlotReleaser` (T-057) bekleyen tek çıkışı ancak yeni bir kare gelince bırakıyor olabilir (son an zamanlayıcısı yoksa); (c) uzun boşluktan sonra pacer yeniden çapalama / faz kilidi edinimi ilk kareleri geciktiriyor.
- Kullanıcı: yeni işlere yeni oturumda geçilecek; saat kayması (Mac ve tablet 120 Hz saatleri) açık konu.
- **Geçici geri alma (sabah):** kullanıcı yazarken donma ve imleç takılmasından şikâyet edince Mac'te çalışan host, seyreltme öncesi `bdf52f0` (T-057) yapısıyla değiştirildi (`build/MateBridge.app` üzerine kopyalandı; `main` değişmedi). Tablet DISPLAY_RATE göndermeye devam ediyor; eski host bilinmeyen tipi atlıyor (§2). Donma geçerse T-058 seyreltmesi suçlu (T-062). Sonraki `bundle-host.sh` main yapısını geri getirir.
- **İkinci geri alma (sabah):** host geri alınınca donma sürdü (kullanıcı: "hâlâ var, imleç hareketlerinde de sürekli takılma") → sorun tablet tarafında. Tablet `98b325e` (T-057 öncesi: T-052 uyarlanır zamanlama + pano + kalem izi) yapısına geri alındı. Şüpheli: T-057 `SlotReleaser`/son yuva sınırı, T-060 faz kilidi, T-061 öncü (hepsi tek kare/boşta durumunu test etmeyen `anim` ile ölçülmüştü). → T-062 teşhisi buradan başlar.
