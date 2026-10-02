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
- **Geri alma sonucu (sabah, kullanıcı):** tablet `98b325e` + host `bdf52f0` ile yazarken donma ve imleç takılması **geçti** → suçlu T-057/T-060/T-061 (tablet sunum zamanlaması), T-058 değil. Kalan, nadir: **uzun beklemeden sonra ilk tuş** (ör. boşluk) ekrana gelmiyor; imleç hareket edince ya da yazmaya devam edince geliyor ("fark etmek için çok dikkat gerek"). Bu, eski yapılarda da var → ayrı neden: boşta kalmadan sonraki **tek kare** yolunda (host: SCK/FrameGate/kodlayıcı tek kareyi geciktiriyor ya da tutuyor; tablet: T-052 pacer uzun boşluktan sonra ilk kareyi bekletiyor). T-062'ye eklendi.

## 2026-10-01 ~09:30 — Yazarken donma düzeltildi (T-062 → T-065, T-066), cihazda

- Kök neden (birim simülasyonu, pacer + `SlotReleaser` uçtan uca): 60 Hz panelde 100–600 ms arayla gelen tek karelerde T-060 faz kilidi slotu eski kilitten `round(dCapture/P)` ile tahmin ediyordu; host 120 Hz ızgarası yüzünden yarım periyot kayınca kare `lateDrop` olup bırakılmış slota düşüyor ve `SlotReleaser` onu atıyordu (ardılı yok) → **126/300 kare hiç gösterilmedi**. > 1 s boşlukta yeniden çapalama sayesinde 0. Host T-058 seyreltmesi de ızgaradan erken gelen son kareyi atıyordu (kullanıcının o sabah çalışan hostunda yoktu).
- İlke (iki taraf): **bir kare ancak daha yeni bir kare yerini alırsa atılabilir.** T-065: releaser reddedilen kareyi bir sonraki slota taşır; kilit > 3 periyot boşlukta yeniden edinilir. T-066: seyreltmede erken kare tutulur, slot + teslim gecikmesi + yarım kaynak aralığında gönderilir (`deferred=`).
- Cihaz (host + tablet `main` a35f802, Performans 120, panel 60 boşta): scratch `blinker` + `sparse.py` (Mac'te 40 pt kare renk değiştirir, tablette `screencap` pikseli): ani 5'li dizi (100–600 ms) 12/12, 8 ms arayla iki renk 12/12, 2–4 s bekleme sonrası tek değişiklik 6/6 doğru. Eski yapılarda taban 16/16. Host sürekli akışta `decimated=60 deferred=0`.
- 60 Hz akıcılık (`anim` 120 Hz, SF `--latency`, 12–14 sn pencereler): ≥25 ms boşluk %2,6 / 2,9 / 5,7 / 7,3 / 7,7; eski yapı (98b325e + bdf52f0) %5,1; gece `main` %2,4–4,6. Gerileme görülmedi; pencereler arası fark `late_drops` (0–4/sn) ile değişiyor → Mac/tablet saat kayması açık konusu. 120 Hz ölçülmedi (dokunma enjeksiyonu Mac'e girdi gönderir; kullanıcı aktif).
- T-063 (pano tablet → Mac): orkestratörün "saat tabanı" teşhisi yanlıştı (`ClipDescription.getTimestamp()` AOSP'de `currentTimeMillis`). Tanı logu (`MB/clipboard diag=check`, içeriksiz) kuruldu; kullanıcının tek kopya denemesi bekleniyor.

## 2026-10-01 ~11:05 — Mac iki kez ani kapanma (uyku değil)

- `pmset -g log` / `log show`: sistem günlüğü **05:59:29**'da ve **10:29:43**'te kapanma sırası olmadan aniden kesiliyor; açılışlar 07:37 ve 10:56:57. Panik raporu yok (`/Library/Logs/DiagnosticReports`), `PMRD: No sleep wake failure string`, uyku girdisi yok (`sleep 0`, MateBridge `PreventUserIdleSystemSleep` tutuyor). Görünüm: **elektrik kesintisi ya da donanım düzeyinde ani kapanma**; yazılım kaynaklı donma genelde watchdog panik raporu bırakır. `autorestart 0` olduğu için Mac güç dönünce kendiliğinden açılmıyor (2026-09-29'da bilinçli kapatılmıştı).
- 10:29:43'ten hemen önce son satırlar: `adb` EXC_GUARD uyarıları (zararsız, sık) ve Wi-Fi sayaçları; MateBridge host normal `ev=stats` yazıyordu.
- Yan etki: `/private/tmp` silindi (scratch araçları). Ölçüm araçları artık `~/.cache/matebridge-tools/` (tick, sweep.py, install.sh).

## 2026-10-01 ~11:30 — Kare başına iz (T-069) ile 60 Hz analizi

- 11:07 taraması (5 ayar × 3 tur) **geçersiz**: kullanıcı aktifti, panel 120 Hz, ~7 Mbps içerik. Yan bulgu: 120 Hz'te kilit her ~30 karede yeniden faz alıyor (`rephase` 36–70 / 20 sn), geç sayılan karelerin payı **+25…+60 ms** (kare kilit slotundan çok önce hazır → "gecikme sınırı aşımı" yolu). Görüntüyü T-065 releaser'ı kurtarıyor. 120 Hz izi henüz alınmadı (dokunma gerekiyor).
- İz `trace1.csv` (60 Hz, 16 pt köşe karesi, ~3800 kilitli kare), `~/.cache/matebridge-tools/sim.py` ile çevrimdışı:
  - Bugünkü kilit, sürekli bölümlerde planlanan slotlarda **%0,1 boşluk** ama hazır→slot **p50 42,5 ms** (≈2,5 vsync). Kilitteki jitter = 256 örneğin p99'u (~32 ms; nadir 33 ms sıçramalar), merkezleme `ideal + J/2 + P/2`, son an 13,33 ms → geç ve "çok erken" atmalar.
  - Sabit oynatma gecikmesi politikası (yakalama + taban + J_q, 2 ms histerezis): q=0,9 → 11 ms / %2,8 boşluk; q=0,95 → 26 ms / %2,0; q=0,99 → 42 ms / %0,6. Yani **60 Hz'te akıcılık ↔ gecikme ödünleşimi girdi sapmasından geliyor**, zamanlama algoritmasından değil.
- Sapmanın kaynağı (`MB/render` 60 Hz sürekli): yakalama→varış p50 16,6 ms (kodlama 6,8 ms), p95 ~18 ms, bazı saniyelerde p99 **40–44 ms** (USB/adb tüneli ya da host gönderim kuyruğu); çözme p50 10, p95 13 ms. Sonraki adım: host'ta yakalama→gönderim zamanlarını ayrıştırmak; yakalama→varışın kodlama dışındaki ~10 ms'si ve p99 sıçramaları.
- Ayrıca SF ile planlanan arasında fark olabilir (son an 13,33 ms ile 6 ms; `deadline_us` taraması kullanıcı boştayken yapılmalı).
- **120 Hz izi (kullanıcı kalemle çizdi, `trace2.csv`, 11 759 kare):** kilit sağlıklı — `locked` 11 584, geç %1,5, `rephase` 6, hazır→slot p50 **17,1 ms**, sürekli bölümde planlanan boşluk %0,7. 11:07 taramasındaki "120 Hz kilit kayması" büyük olasılıkla taramanın yeniden başlatmalarından/kullanıcı içeriğinden (doğrulanmadı, ama gerçek kullanımda görülmüyor). Simülasyon: son an 13,3 ms ile ~18 ms / %0,4; **son an 6 ms ile q=0,98 → ~10,5 ms / %0,7**. Yani gerçek mandal süresi ~6 ms ise çizimde ~7 ms kazanç; SF ile `deadline_us=6000` doğrulaması gerekli (çizim sırasında).

## 2026-10-01 ~12:00 — 6 ms son an varsayılan (T-071), kullanıcı geri bildirimi

- Kurulum (host e9b5d87 + APK): `presentation_deadline_ns=13333333`, `effective_deadline_ns=6000000`.
- Kullanıcı: çizim akıcı, harfler hemen görünüyor. Safari'de YouTube oynarken imleç hareketsizse fps ~30'a iniyor, imleç oynayınca artıyor → host içerik güdümlü yakalıyor; video 30 fps ise beklenen davranış (önceki gözlem: `cap_fps=30`, `cap_int 33,3 ms` tam). 60 fps videoda da 30 kalıyorsa ayrı sorun.
- AppGallery kurulum sonrası öneri sayfası (`InstallDistActivity`, `downbtn` indirme düğmeleri) `install.sh` döngüsünü bekletti; hiçbir şeye dokunulmadı, `am start` ile MateBridge öne alındı.
- Kullanıcı (12:15): Mac'in 05:59 ve 10:29 kapanmaları **elektrik kesintisi** kaynaklı. (`autorestart 0` olduğu için elektrik gelince kendiliğinden açılmıyor; değiştirmek kullanıcının kararı.)

## 2026-10-01 ~12:40 — DÜZELTME + host gecikme dökümü (T-072)

- **Düzeltme (~11:30 girdisi):** tablet `MB/render` satırındaki `net_p50/p95/p99_us` **gecikme değil, ağdan varış aralığı** (`networkGaps`); 60 fps'te p50 16,6 ms doğal. "Yakalama→varış 16,6 ms" ve "USB'de ~10 ms" yorumları **yanlış**. p99 40 ms = ara sıra 40 ms'lik varış boşluğu (gecikmeli kare). Gerçek gecikme alanı `latency_us` (yakalama damgası → çözücü çıkışı).
- Host (47620b2, 120 fps, `tick`): `gate_wait`/`slot_wait` ≈ 0 (T-072 kapı toleransı yarım aralık), `enc` p50 6,9 ms, `cap_to_sent` p50 7,2 / p99 ~8 ms, sıçrama yok. **`pts_vs_deliv` = +6,6 ms**: SCK'nın PTS/`displayTime` damgası, karenin geri çağrısından 6,6 ms *ileride* (gelecekteki gösterim anı). Teldeki `capture_time_us` = PTS → tabletin `latency_us` değeri gerçek yakalama→çözme süresini ~6,6 ms **eksik** gösteriyor; pacing'i etkilemez (sabit fark), yalnız raporu.
- Kaba bütçe (60 Hz, gerçek): host ~7 ms + USB/adb ~4–6 ms + çözme ~10 ms + sunum bekleme (120 Hz'te ~12,6 ms planlı; 60 Hz'te ~42 ms kilit).

## 2026-10-01 ~12:50 — Varış boşluklarının kaynağı (T-073 izi + host CSV, USB, 60 fps, 90 sn)

- Host `write_done − capture` p50 7,2 / p99 8,3 ms (bir kez 27 ms). Tablette kapasitenin üzerinde varış boşluğu 20 kez:
  - **Periyodik anahtar kare** (her 10,0 s, ~432 KB): alma +15 ms, şifre çözme **~11 ms** (~40 MB/s; 3 KB karede bile 0,8 ms) → T-075 (aralık), T-076 (şifre çözme hızı).
  - **USB/adb paketlemesi:** host 16,6 ms arayla gönderiyor, tablette bazı dönemlerde `recv` aralığı **40, 0, 40, 0…** (iki kare birlikte). İki uçta `TCP_NODELAY` açık → adbd yerel soketi Nagle + tablet gecikmeli ACK (40 ms) şüphesi → T-074 (`TCP_QUICKACK`).

## 2026-10-01 ~13:20 — Varış düzensizliği giderildi (T-074, T-075, T-076), cihazda

90 sn, USB, 60 fps köşe karesi, `pace_trace`, `gaps.py` (`~/.cache/matebridge-tools`): sürekli bölümde kapasitenin >12 ms üzerinde geç varış / <1 ms arayla ikili varış / 90 sn'deki anahtar kare:

| | geç varış | ikili varış | anahtar kare | şifre çözme p50/p99 |
|---|---|---|---|---|
| önce (trace3) | 20 (%0,35) | 8 | 12 | 0,81 / 1,97 ms |
| T-074+075+076 (trace4) | **1 (%0,02)** | **0** | 2 | 0,63 / 1,60 ms |
| aynı, `--ez quickack false` (trace5) | 79 (%1,39) | 90 | 1 | 0,68 / 1,59 ms |

- `TCP_QUICKACK` (T-074) adb tüneli paketlemesini kesin olarak gideriyor (A/B). Anahtar kare aralığı 300 s (T-075, `keyframe_interval_s=300`).
- `crypto_bench` (T-076): AndroidOpenSSL 432 KB 0,57 ms (776 MB/s), varsayılan zaten AndroidOpenSSL; BC 14 ms. Eski ~11 ms dört kopya + tahsisten. Codex P2 (Conscrypt çıkış tamponu boyutu) düzeltildi.

## 2026-10-01 ~13:40 — Bütçe sonrası (trace6, 60 Hz, `tick`)

- Hazır→slot p50 **15,8 ms** (önce 42,5): kilit jitter'ı (p99 dev) 33 → 8 ms; varış düzensizliği gidince kendiliğinden düştü. SF 60 sn: 3705 aralığın **%100'ü tek vsync**.
- p50: alım→çözücü 1,9 ms (şifre çözme 0,62 + kuyruk→giriş 1,16), çözme 8,7 ms → T-077.
- Tablet `stream_mode=performance` (2100×1380 ölçekli): tam çözünürlük (Akıcı, 2800×1840@120) yeniden denenmeli (dün çözücü sınırı).

## 2026-10-01 ~14:00 — Akıcı mod (2800×1840@120) yeniden denendi; HiWrite katmanı

- Kullanıcı çizdi (trace7): alınan/çözülen/gösterilen ~110/sn, `drop=0`, çözme p50/p95/p99 9,4/12,6/15,1 ms, hazır→slot p50 13,1 ms; planlanan boşluk %2,4 (Performans trace2'de %0,7; 6 % geç kare çözme süresi sıçramalarından). Kullanıcı: **"akıcı mod çok iyi gözüküyor"** → tablet `stream_mode=smooth` kalıyor.
- Açılıştan sonra üst ortada kalem algılanmıyor → `com.huawei.hiwrite` penceresi `[989,276][1805,558]`, `ty=2032`, dokunulabilir; bağlantı panelindeki `endpointField` tetikliyor → T-078.

## 2026-10-01 ~14:30 — T-077 ve T-078 cihazda

- T-078: iki soğuk açılışta (1,5 s / 5,5 s) `com.huawei.hiwrite` penceresi yok (önce üst ortada dokunulabilir 816×282 px katman).
- T-077 (trace8, 60 fps, 90 sn): kuyruk→giriş p50/p95 **1,16/2,72 → 0,90/2,32 ms**; ayrıştırma: uyanma 0,16, giriş tamponu hazır (%100 `inbuf_pre`), kopya 0,11, **`queueInputBuffer` 0,58 / p95 1,97 ms** (codec servisine çağrı). Şifre çözme: uygulama içinde `init` 0,34 ms, `doFinal` 0,16 ms; `crypto_bench` aynı işlemi 0,033 / 0,010 ms ölçüyor → ağ iş parçacığı düşük frekanslı çekirdekte/soğuk önbellekte. Geç varış %0,07, ikili varış 0.
- Codex (high) P2: Android `Cipher` korumalı kurucusu `specifiedSpi`'yi `engineInit` çağırmadan döndürüyor → "doğrudan SPI" yolu kaldırıldı.
- T-079 (PerformanceHintManager): HarmonyOS 4.3'te servis var (`supported=1`) ama `createHintSession` oturum vermiyor (`session=0`, hem 8,3 hem 16,7 ms hedefiyle) → platform ADPF ipucu oturumlarını desteklemiyor. Deney anahtarı varsayılan kapalı kalıyor; bu yol kapandı.

## 2026-10-01 ~14:45 — 120 Hz düzensiz içerikte kilit zayıf; sabit oynatma simülasyonu

- 60 Hz (trace6/8): kilit planlanan boşluk %0,02–0,04, 13–16 ms; simülasyon aynı (~%0).
- 120 Hz Akıcı + çizim (trace7): kilit %2,4 @ 13,1 ms, geç payı p90 +60 ms (yakalamalar düzensiz → `k` yuvarlama/çıkarım kayması). Sabit oynatma: q=0,9 13,3 ms/%1,1; q=0,95 18,1/%0,5; q=0,99 20,4/%0,2. → T-080 (anahtar arkasında, A/B çizimle). Araçlar `tools/pacing/`.

## 2026-10-01 ~13:47 (cihaz saati) — Zamanlayıcı A/B çizim sırasında (T-080)

| 120 Hz, kullanıcı çiziyor | SF tek vsync | SF çift | hazır→slot p50 | planlanan boşluk |
|---|---|---|---|---|
| A: faz kilidi (`lock`) | %98,06 | %1,54 | 11,2 ms | %0,40 |
| B: sabit oynatma (`cpd`, q=0,95) | **%99,31** | **%0,57** | 17,0 ms | %0,46 |

- `in_codec_p95` 6–7, `max` 3; `late_drops` A 2 / B 0. Kullanıcı: **"ikincisinde gecikme hissediliyor"** → varsayılan `lock` kalıyor; `cpd` anahtar arkasında (`--es pacer cpd`). Karar: çizimde gecikme > %1'lik çift kare.
- Not: kilidin planlanan boşluğu (%0,4) SF'deki çiftten (%1,5) düşük → bazı kareler planlanan slotu SF'de kaçırıyor (son an 6 ms sınırda olabilir).

## 2026-10-01 ~13:51–13:54 (cihaz saati) — Son an 6 ms vs 7 ms, dönüşümlü A/B (çizim, 120 Hz)

| bölüm | son an | SF çift | hazır→slot p50 | planlanan boşluk |
|---|---|---|---|---|
| A | 6 ms | %0,27 | 12,5 ms | %0,10 |
| B | 7 ms | %2,95 | 12,3 ms | %0,32 |
| C | 6 ms | %2,40 | 11,2 ms | %0,29 |
| D | 7 ms | %4,19 | 17,7 ms | %0,41 |

- 7 ms daha iyi değil (iki turda da 6 ms'den kötü). Bölümler arası fark büyük (kullanıcının çizim davranışı). **6 ms kalıyor.** Görüntü akıcılığı çalışması burada durduruldu (kalan paylar: donanım çözme ~9 ms, panel zamanlaması).

## 2026-10-01 ~14:10 — Ekran kilidi ölçümü (T-040), kullanıcı izniyle kilit geçici açıldı

- Kullanıcı Sistem Ayarları'ndan "parola iste: hemen" açtı (`sysadminctl -screenLock status` → immediate). `pmset displaysleepnow`:
  1. SCStream hata **-3815** ("ekran bulunamadı") → `pipeline_retry` → **`CGVirtualDisplay initWithDescriptor: returned nil`** her ~0,6 s (ekranlar uyurken yeni sanal ekran oluşturulamıyor). Uyku sırasında sistem `1920x1080` yer tutucu ekran gösteriyor (`v0x756e6b6e/m0x76697274`). Tablet donuk kare → "Gelen kare: 0" paneli; panel görünürken tablet girdiyi Mac'e göndermiyor → **tablet Mac'i uyandıramıyor**.
  2. `caffeinate -u -t 2` (kullanıcı etkinliği) → sanal ekran hemen oluştu, `video_streaming`, tablette **kilit ekranı görünüyor**.
  3. Kilit ekranında tablet klavye/fare girdisi **çalışmıyor**: `loginwindow` (PID 174) `CGSSetSecureEventInput: 1`; sentetik CGEvent'ler şifre alanına ulaşmıyor (Apple'ın bilinçli kısıtı; Erişilebilirlik izni aşmıyor).
- Seçenekler kullanıcıyla konuşuldu: sanal HID sürücüsü + root yardımcı (Karabiner VirtualHIDDevice) **reddedildi (risk)**. Risksiz/düşük riskli alternatifler: Apple Watch otomatik kilit açma; macOS Ekran Paylaşımı yalnız yerel (`VNCOnlyLocalConnections`) + host'un yerel VNC istemcisi olması (doğrulanmadı); Parsec ile açma ya da kilidi kapalı tutma. Ayrıca önerilen risksiz parça: görüntü ekran uykusu yüzünden koparsa host `IOPMAssertionDeclareUserActivity` ile uyandırır, tablet panelde iken dokunma/tuşu "uyan" isteği olarak gönderir.
- **T-081 cihazda (~14:35):** oturum açıkken `pmset displaysleepnow` → `pipeline_failed` (-3815, `SCStreamErrorDomain`) → `wake_display reason=capture_source_lost wakes=1` → `pipeline_retry` → `display_created` → `video_streaming`, toplam ~1,2 s; `CGSSessionScreenIsLocked=Yes` (kilit devrede, tablette kilit ekranı). Kullanıcı kilidi Parsec ile açar. Huawei Watch Fit Pro Apple'ın otomatik kilit açmasıyla çalışmaz.
- **DÜZELTME (~14:45, kullanıcı):** T-081 sonrası kullanıcı Mac kilidini **MateBridge'den tablet klavyesiyle açtı**. Yani kilit ekranında sentetik klavye girdisi çalışıyor; ~14:10'daki "Secure Event Input engelliyor" yorumu **yanlıştı** (`CGSSetSecureEventInput: 1` gerçek ama MateBridge'in girdisini durdurmuyor). İlk denemede başarısızlığın olası nedeni: ekran uykusunda tablet "Gelen kare: 0" paneline düştü (panel görünürken girdi yakalama kapalı) ve görüntü `caffeinate` ile dönünce yakalama/odak geri gelmedi (doğrulanmadı). T-081 ile görüntü 1,2 s'de döndüğü için tablet panele düşmüyor.

## 2026-10-01 ~15:10 — Ekran deneyleri araştırması (T-082..T-085, ajanlar + cihaz)

**T-083 — Mac yakalama fazı ↔ tablet vsync (çevrimdışı, 14 iz):**
- Mac sanal ekranının vsync'i mach zamanına bağlı bir yazılım ızgarası: tüm SCK PTS'leri 8 333 333 ns ızgarasında, faz **0,500 ms mod 8,333 ms** (2,5 saat, birçok host yeniden başlatması). Ekranı yeniden oluşturmak fazı **değiştirmiyor**.
- Tablet paneli: 8 333 215 ns (120,0017 Hz), yani **14 ppm hızlı**. Mac ile tablet saatleri arasındaki kayma 0–2 ppm.
- (yakalama − vsync) fazı **+13,95 µs/s** kayıyor: tam tur 120 Hz'te ~10 dk, 60 Hz'te ~20 dk. Kayma tamamen öngörülebilir ve bir oturum içinde çok az değişiyor.
- Hazır→slot beklemesi, 120 Hz'te ortalama 14,8 ms:

  | bileşen | süre |
  |---|---|
  | sabit son an | 6 ms |
  | kilit payı (p99 sapma + 0,5) | 6,3 ms |
  | faz kalanı r | beklenen 4,17 ms; ölçümlerde 3,1–5,9 ms |

- Aynı planlanan kaçırma oranında en iyi faz hizalamasının kazancı:

  | panel | kaçırma %1 | kaçırma %0,5 |
  |---|---|---|
  | 120 Hz | 1,4 ms | 1,1 ms |
  | 60 Hz | 5,6 ms | 4,6 ms |

- **Önemli:** dakikalar arayla yapılan A/B ölçümleri farklı r değerinde koştu (3,1–5,9 ms). Önceki gecikme A/B sonuçlarının bir kısmı faz etkisi; yeni A/B'lerde r de raporlanmalı.
- Mac tarafında faz kontrolü: `minimumFrameInterval`, `queueDepth`, ekranı yeniden oluşturmak ve kodlamayı geciktirmek fazı değiştirmiyor. Kesirli `refreshRate` denenmedi. Gizli `CGVirtualDisplaySettings.refreshDeadline` (Double, varsayılan 0) var, anlamı doğrulanmadı.
- **Karar:** 120 Hz faz hizalaması yapılmayacak. Kazanç ~1–1,5 ms; bedeli gizli API, 14 ppm kaymaya karşı sürekli kontrol, protokol mesajı ve daha fazla SF kaçırması. İsteğe bağlı, düşük öncelikli iki iş:
  1. 60 Hz panel + 120 fps içerikte FrameGate'in hangi kaynak kareyi tutacağına tabletin r'ye göre karar vermesi (~3,3 ms).
  2. `refreshDeadline` denemesi (sanal ekran oluşturur; kullanıcı onayı gerekir).

**T-084 — SurfaceControl ile doğrudan sunum:**
- Tablet `libandroid.so` gerekli NDK sembollerini içeriyor: `ASurfaceTransaction_setBuffer`, `setDesiredPresentTime`, `setOnComplete`, `ASurfaceTransactionStats_getLatchTime`, `getPresentFenceFd`, `ASurfaceControl_createFromWindow`. Java tarafındaki `Transaction.setBuffer` API 33 gerektiriyor; tablet API 31.
- Beklenen gecikme kazancı **0–1,5 ms**. `setDesiredPresentTime`, bugünkü `releaseOutputBuffer(ts)` ile aynı SF mekanizması (Android 12 BLAST). 6 ms son anın çoğu SF/HWC ofseti; yeni yol yalnızca codec→BufferQueue sıçramasını kaldırıyor.
- Yol NDK, CMake ve JNI gerektiriyor. Bunun için karar kaydı lazım; tam entegrasyon ~3–5 ajan-günü.
- **Karar:** bırakıldı (eşik ≥3 ms). Tek gerçek faydası kare başına gerçek latch/present geri bildirimi; son an ayarı için ileride bir sonda olarak düşünülebilir.

**T-082 — H.264 ve HEVC:**
- Protokol ve tablet H.264'ü uçtan uca destekliyor; yalnızca host HEVC'ye sabit.
- Tablet çözücü sınırları (`/vendor/etc/media_codecs.xml`):

  | çözücü | blok/s sınırı (16×16) | performans noktası |
  |---|---|---|
  | `OMX.hisi.video.decoder.avc` | 2 073 600 | 4K@60 |
  | `OMX.hisi.video.decoder.hevc` | 6 144 000 | 4K@60 |

- 2800×1840@120 = 2,415 M MB/s; H.264 için bu seviye 6.0 demek ve resmi sınırın dışında.
- Ayrıca VVC çözücü (`OMX.hisi.video.decoder.vvc`, 3840×2160) var; Mac VVC kodlayamıyor.
- Host'a deney düğmesi (`MATEBRIDGE_CODEC`) T-086'da eklenecek, sonra A/B.

**T-085 — bit hızı ve yazı keskinliği:**
- Akıcı mod gerçekte **60 Mbps** çalışıyor (`StreamPrefsPolicy`: 30 000 × fps/60 × scale², 20–80 sınırı). Performans modu ~34 Mbps.
- `MATEBRIDGE_BITRATE_KBPS` prefs tarafından eziliyor, yani etkisiz.
- Durağan ekranda kalite tazeleme yok: hareketin son P karesi ekranda kalıyor.
- SCK doğrudan 420f full-range yakalıyor; Akıcı modda ölçekleme yok.
- Düğmeler ve süreç içi keskinlik ölçümü (`--sharpness-bench`, PSNR/SSIM) → T-086.

## 2026-10-01 ~15:40 — T-086 bench sonuçları (M6, 2800×1840@120, süreç içi)

- **H.264:** Mac kodlayıcısı 120 fps'e yetişmiyor (~24 ms, en fazla ~103 fps). `High_5_2` 120 fps'te her karede hata veriyor. T-082 kapandı.
- **`--sharpness-bench`** (metin sayfası kaydırılıyor, sonra durağan son kare; luma PSNR):

  | ayar | PSNR | not |
  |---|---|---|
  | varsayılan HEVC 60 Mbps | 42,15 dB | |
  | boşta tazeleme 300 ms ×3 | 45,78 dB | ~0,5 MB patlama |
  | tek anahtar kare | 40,43 dB | daha kötü |
  | `QUALITY=0.8` | 45,64 dB | ~1,33× bit hızı |
  | env 100 Mbps | 51,6 dB | |
  | `PRIO_SPEED=0` | 52,4 dB | ~25 ms kodlama, kare kaybı, kullanılamaz |

- Bit hızı en büyük kaldıraç. Cihazda ölçülecek: USB'de 80–100 Mbps'in varış düzensizliğine ve gecikmeye etkisi, ayrıca boşta tazelemenin tablet pacer'ında sorunsuz geçip geçmediği.

## 2026-10-01 ~15:30 — Cihazda bit hızı A/B (T-085, USB, Akıcı, tam ekran kayan metin)

Araçlar `~/.cache/matebridge-tools`:
- `scroll`: tam ekran yoğun metin, 120 Hz kayma.
- `brab.py`: host env ile yeniden başlatma, tablette `pace_trace`, 25 s pencere, 2 tur dönüşümlü.

Kullanıcı Mac'te boştaydı. Panel Dinamik modda (girdi yok) ~60/120 arasında gidip geldi; ~89 fps.

| bit hızı | KB/kare p50/p95 | çözme p50/p95/p99 ms | alım→giriş p50 | tablet gecikme medyanı |
|---|---|---|---|---|
| 60 Mbps (bugünkü) | 40/55 | 12,3/15,2/20–27 | 2,3 ms | **22,7 ms** |
| 80 Mbps | 62/81 | 12,6/15,5/26–29 | 2,6 ms | 25,0 ms |
| 100 Mbps | 78/107 | 12,9/19–20/**40** | 2,7 ms | 25,7 ms |

- Bit hızı artınca gecikme +2–3 ms artıyor; 100 Mbps'te çözme kuyruğu da uzuyor (p99 40 ms).
- Kullanıcı gecikmeye önem veriyor (T-080), bu yüzden **hareket için 60 Mbps kalıyor**.
- Durağan yazı keskinliği için boşta tazeleme düşünülmüştü (bench'te 42,5 → 47,6 dB). Ancak gerçek hatta tazeleme kareleri **222 bayt** (atlama karesi) çıkıyor, yani etkisiz → T-087.
- Tablet ve Mac ekran görüntüleri arasındaki luma PSNR renk yönetimi farkı yüzünden ~33,7 dB'de sabit; bu yöntem keskinlik farkını ayırt edemiyor. Kare boyutu ve bench PSNR kullanılmalı.

## 2026-10-01 ~17:30 — T-087: boşta tazeleme neden etkisiz (düzeltme)

- Aynı tampon nesnesi neden değil. `--refresh-buffer same|copy` iki kipte de aynı baytı ve PSNR'ı veriyor.
- Gerçek neden: oturum oturduktan sonra son hareket karesi bu bit hızında zaten en düşük QP'de kodlanmış oluyor. Aynı içerik gelince VT 222 baytlık tamamen atlama karesi üretiyor; cihazda görülen tam buydu.
- **T-086'daki 42,5 → 47,6 dB kazancı bench ısınma yanılgısıydı.** 30 hareket karesinde açılış anahtar karesinin bit borcu ölçümü bozuyordu. Bench varsayılanı artık 240 kare.
- `fast` profil (≥120 fps) akış ortasındaki her ayar değişikliğini yok sayıyor: max QP, Quality, bit hızı, PrioritizeSpeed, flush, zorunlu anahtar kare. Kare başına `BaseFrameQP` -12900 dönüyor. Aynı ayarlar oturum oluşturulurken verilirse çalışıyor. `llrc` profili akış ortasında max QP değişikliğini uyguluyor (`MATEBRIDGE_IDLE_REFRESH_QP`, 51,1 → 57,4 dB), ama ~10 ms/kare sürdüğü için yalnızca ≤60 fps'te kullanılabilir.
- Oturmuş durağan metin (bench, 2800×1840@120, 240 kare):

  | ayar | PSNR |
  |---|---|
  | 60 Mbps | 48,5 dB |
  | 80 Mbps | 53,0 dB |
  | `QUALITY=0.8` | 53,0 dB |

- Karar: varsayılan değişmiyor (gecikme önceliği). T-085 ve T-087 kapandı.

## 2026-10-01 ~17:45 — Wi-Fi ölçümü (T-088/T-089 kuruldu, `brab.py`, tam ekran kayan metin, Akıcı)

Ağ:
- Mac en1 802.11ax, kanal 52 (5 GHz, 160 MHz, DFS), PHY 1729 Mbps, sinyal -43 dBm, `awdl0` etkin.
- Tablet Wi-Fi 6, 2161 Mbps, RSSI -36. İkisi de aynı modemde (FiberHGW).
- Boşta ping Mac→tablet: 5,6 / 9,5 / 21,8 ms (min/ort/maks).

| koşul | fps | gönderilen Mbps | KB/kare p50 | tablet gecikme medyanı | RTT p50 (`ev=net`) | host gönderim kuyruğu p95 |
|---|---|---|---|---|---|---|
| USB | 60 | 23 | 47 | **24–25 ms** | 4,6 ms | 0 KB |
| Wi-Fi | 8–11 | **27–28 (tavan)** | 275 | **350–390 ms** | 28 ms | 300–320 KB (maks 1,1 MB) |
| Wi-Fi, `WIFI_BITRATE=40000` | 17–50 | 17–27 | 29–218 | 35–370 ms | 25–28 ms | 52 KB → -1 |
| Wi-Fi, `SERVICE_CLASS=video` + `tos_ctl/video` + `wifi_ll` | 9–10 | 27 | 270 | 350–380 ms | 28 ms | ~320 KB |

- **Wi-Fi'de Mac→tablet kapasitesi ~27 Mbps'te doyuyor**, Akıcı (60 Mbps) ve Performans (~34 Mbps) bunu aşıyor.
- Host gönderim kuyruğu sınırsız büyüyor. "En yeni kare kazanır" kuralı Wi-Fi'de çalışmıyor; gecikme yüzlerce ms'ye çıkıyor (araştırma bulgusu doğrulandı).
- Kodlayıcı kare atınca kare başı boyut 275 KB'a çıkıyor.
- `wifi_ll` gerçekten etkin oldu (`dumpsys wifi` `low_latency_active_time_ms`) ama fark yaratmadı. DSCP/serviceClass da etkisiz.
- `TcpSocketProbe` Wi-Fi bağlantısında `tcp_info` bulamadı (`retx=-1`), `nw_metadata` yedeğine düştü. İncelenecek.
- Tablette `nc`/`curl` yok → ham kapasite için T-090 ölçüm kipi.
- Ölçüm tuzağı: `adb shell run-as … sed 's#…">…<#…#'` komutunda tırnaklar uzak kabukta korunmuyor, `>` yönlendirme sayılıyor. Komut tek dize olarak verilmeli. 17:13 ve 17:38 Wi-Fi turları bu yüzden aslında USB'de koştu.

## 2026-10-01 ~18:05 — Wi-Fi tavanının kökü: NWConnection kullanıcı alanı TCP yığını kayıp üretiyor

- Ham ağ kapasitesi (T-090 `net_bench` + `~/.cache/matebridge-tools/netsrv.py`):

  | yön / akış | Mbps |
  |---|---|
  | aşağı, 1 akış | 410 |
  | yukarı, 1 akış | 410 |
  | aşağı, 4 akış | 448 |
  | `SO_RCVBUF` 4 MB | 385 (fark yok) |
  | aralıklı patlama 250 KB/33 ms | ~50, `sendall` p50 0,3 ms (eksiksiz) |

- `TCP_QUICKACK` kapalı (`--ez quickack false`) Wi-Fi'de fark yaratmadı. 15 ve 8 Mbps'te akış toparlanıyor (48–54 fps), ama RTT ~23 ms ve gecikme ~34 ms.
- Akış sırasında tablet `/proc/net/tcp` rx kuyruğu 0 (uygulama hemen okuyor). Mac `netstat` gönderim kuyruğu 130–360 KB.
- `nettop -m tcp -x`:

  | bağlantı | `arch` | yeniden gönderim |
  |---|---|---|
  | MateBridge video (`NWConnection`) | `ch` (Skywalk kanalı, kullanıcı alanı TCP) | 1,22 MB / 29,3 MB = **%4,2** |
  | Python BSD soketi, aralıklı patlama | `so` (çekirdek) | **0** |
  | Python BSD soketi, toplu | `so` | 7 KB / 355 MB |

- **Sonuç:** Wi-Fi tavanının nedeni Network.framework'ün kullanıcı alanı TCP yığını (kayıp → cubic penceresi küçülüyor). Ağ ve tablet değil.
- → T-091: video bağlantısı BSD soketine ve `TCP_NOTSENT_LOWAT`'a taşınıyor (düğme arkasında, A/B). Wi-Fi'de kalem öbeklenmesi aynı nedenden olabilir (kontrol bağlantısı da `ch`); T-091 ölçümünden sonra ayrı kart.

## 2026-10-01 ~18:35 — T-091 cihazda: BSD video soketi Wi-Fi'yi düzeltti

`brab.py`, Akıcı, kayan metin, 20 s pencere. Mac 18:36'da kendiliğinden kilitlendi (~20 dk boşta); 2. turun çoğu kilit ekranı yüküyle geçti.

| koşul | fps | KB/kare p50 | gönderilen Mbps | tablet gecikme medyanı | RTT p50/p95 | gönderim kuyruğu p95 / maks | yeniden gönderim |
|---|---|---|---|---|---|---|---|
| Wi-Fi `nw` | 13 | 256 | 28,6 (tavan) | **372 ms** | 27/31 | 334/387 KB | — |
| Wi-Fi `bsd` 128 KB | 52 | 46 | 22,9 | **48,8 ms** | 28/50 | 120/943 KB | 0 |
| Wi-Fi `bsd` 64 KB | 54 | 47 | 23,1 | **38,5 ms** | 26/42 | 90/939 KB | 0 |
| Wi-Fi `bsd` 256 KB | 54 | 47 | 23,2 | **37,5 ms** | 29/52 | 85/861 KB | 0 |
| USB `bsd` 128 KB | 55 | 47 | 23,2 | 23,9 ms | 4,7/6,1 | 0 | — |
| kilit ekranı yükü, Wi-Fi `bsd` 64/256 | 30 | 188–211 | **~60 (tam)** | 52–55 ms | 25/34 | 16–19/83 KB | 0 |
| kilit ekranı yükü, USB `bsd` | 30 | 220 | 59,7 | 39,7 ms | | | |

- Wi-Fi tavanı kalktı. `bsd` 60 Mbps'i yeniden gönderimsiz taşıyor; gecikme 372 → ~40 ms.
- `TCP_NOTSENT_LOWAT` 64/128/256 arasındaki fark gürültü düzeyinde; 128 kalıyor. Varsayılan `bsd` → T-092.
- Wi-Fi'de kalan fark (USB 24 ms ↔ Wi-Fi ~40 ms):
  - RTT yük altında 25–28 ms (boşta ICMP ~9,5 ms, oynak);
  - kuyruk patlamaları (maks ~940 KB).
- Sonraki adaylar:
  - kontrol bağlantısını (girdi, kalem) da BSD'ye taşımak; Wi-Fi kalem öbeklenmesi için ölç;
  - Wi-Fi'ye özel bit hızı (`MATEBRIDGE_WIFI_BITRATE_KBPS`);
  - kullanıcı tarafı: AWDL/AirDrop/Handoff kapatma, modemi DFS olmayan kanala almak.

## 2026-10-01 ~20:50 — Ses aktarımı cihazda (T-093/T-094/T-095, karar 0011)

**Mac:**
- MateBridge'in "Yalnızca Sistem Sesi Kaydı" izni verildi (`kTCCServiceAudioCapture`, tccd `Create`).
- İzin, IOProc kurulurken verildiği için ilk akışta paket gelmedi; host yeniden başlatılınca çalıştı. Sessizken paket gelmemesi ise beklenen davranış: Mac ses çalmazken tap IO'su da duruyor.
- Ses çalarken: 100–101 paket/sn, `callback_ms` 0,06–0,07, `ring_ms_max` 10, `wire_dropped` 0.

**Tablet:**
- Tek çıkış iş parçacığı var (`AudioOut_D`, MIXER, HAL 960 kare = 20 ms). FastMixer yok, bu yüzden `perf_mode=none`, burst 960.
- `aaudio.mmap_policy=2` ve `mmap_exclusive_policy=2`: AAudio MMAP yolu muhtemelen var (NDK gerekir).

**Gecikme** (yoklama ve kısa sesler): ses ~170–190 ms, video ~51 ms, yani `av_offset_ms` ~120–140 (ses geç). Seviye tabanı 29 ms. Sessizlik aralarında alt taşma sayılıyor (`underruns` 2–3), bu da hedef tamponu büyütüyor.

**Kullanıcı testi:**
- Ses tabletten geliyor, Mac sessiz.
- Kesinti veya cızırtı yok.
- Dudak senkronunda göze batan bir şey yok.
- Uygulama arka plana alınınca Mac sesi geri geliyor.

**İyileştirme adayları** (acil değil):
- Sessizliği (host IO yok) alt taşma saymamak.
- AAudio MMAP denemesi (NDK, karar kaydı gerekir).
- Tablet tampon boyu (1920 → 960).

## 2026-10-01 ~21:50 — AAudio MMAP sondası (T-099, NDK 30.0.16248370, CMake 4.1.2)

Her durum 5 s, −40 dBFS 1 kHz ton. Gecikme = `getTimestamp` (yazılan − sunulan) / hız − (şimdi − sunum).

| durum | paylaşım | MMAP | burst | tampon | xrun | çıkış gecikmesi p50/p95 |
|---|---|---|---|---|---|---|
| a) AAudio LOW_LATENCY + EXCLUSIVE | exclusive | **evet** | 240 (5 ms) | 480 | 0 | **12,95 / 12,99 ms** |
| b) AAudio LOW_LATENCY + SHARED | shared | evet | 240 | 720 | 1 | 494 ms (zaman damgası tutarsız, ts_fail 114; dikkate alınmadı) |
| c) AudioTrack (ürün ayarı) | — | — | 960 (20 ms) | 1920 | 0 | **99,1 / 99,7 ms** |

- `dumpsys media.aaudio`: "Exclusive MMAP Endpoints: 1".
- **Kazanç ~86 ms**, T-097 eşiği 40 ms. Ses ~170–190 ms'den tahminen ~90–100 ms'ye iner.
- → Karar 0012 (NDK + AAudio istemcide) kullanıcı onayına sunuldu.

## 2026-10-01 ~22:15 — T-096 / T-098 / T-100 cihazda

**T-100 AAudio:**
- `api=aaudio`, `dumpsys media.aaudio` "Exclusive MMAP Endpoints: 1", burst 240, `buf_frames` 480, seviye tabanı 8–9 ms, `xruns`/`underruns` 0.
- Kullanıcı: ses temiz, senkron iyi.
- **Ölçüm hatası:** `audio_ms` ~470 ve `av_offset_ms` ~430 gösteriyor. Oysa seviye 9 ms + çıkış ~13 ms + yakalama/ağ ~15 ms ≈ 35–45 ms olmalı. AAudio zaman damgası `framePosition` ile yazılan kare sayacının başlangıç noktası (start catch-up) uyuşmuyor gibi → T-101. AvSync bu hatayla sesi geciktirmiyor (yalnızca erken sesi geciktiriyor).

**T-096 Otomatik aktarım:**
- İlk açılışta `transport_pref_migrated from=wifi to=auto`; kablo takılıyken `chosen=usb reason=usb_open`.
- Kablo çekilince Wi-Fi'ye kendiliğinden geçti.
- Yeniden takınca HarmonyOS USB modunu "yalnızca şarj"da bıraktığı için adb ve tünel kalkmadı. Kullanıcı "dosya aktarımı"nı seçince otomatik olarak USB'ye geçti.
- Öneri (tablet ayarı): Geliştirici seçenekleri → "Yalnızca şarj modunda ADB hata ayıklamasına izin ver" ya da "Varsayılan USB yapılandırması = Dosya aktarımı".
- Kalem ve tuş basılıyken geçiş henüz denenmedi.

**T-098:** `idle_gaps` / `state=idle` yolu çalışıyor. Ses başlangıcında hazırlık süresi kısaldı.

## 2026-10-01 ~22:45 — T-101 cihazda: ses uçtan uca ~41 ms

AAudio (exclusive MMAP), Mac'ten kısa sesler:
- `audio_ms=41`, `video_ms=40–43`, `av_offset_ms=0`;
- seviye tabanı 12–14 ms, `underruns`/`xruns` 0.

Önceki 470 ms gösterimi OutputClock eşleme hatasıydı. Artık AAudio'nun kendi `framesWritten`/`framesRead` sayaçları kullanılıyor.

| | ses | A/V farkı |
|---|---|---|
| AudioTrack (T-095) | ~170–190 ms | ~130 ms |
| AAudio (T-101) | ~41 ms | ~0 ms |

Panelde "Ses çıkışı: Düşük gecikme / Uyumlu" seçeneği var. `audio_clock_raw` debug seviyesinde olduğu için info log'unda görünmüyor.

## 2026-10-02 ~00:10 — T-108/T-109 cihazda; oyun modunda sürekli cızırtı

- **T-103:** Witcher 2'de görünmez duvar yok (kullanıcı). Oyun sırasında `input_session_end`: `cursor_adopted=2013 cursor_current=3309 cursor_lag_ignored=1169`, `cursor_query_avg_us≈5`.
- **Cızırtı, ilk analiz (T-108 öncesi):**
  - Jitter tamponunun güvenlik payı 5 ms'den başlıyordu; 5 dakikada 6 boşalma oldu.
  - T-108 sonrası pay 20 ms'den başlıyor. Yine de oyun modunda 3 boşalma oldu (00:27:04, 00:27:24, 00:29:14) ve pay 34 ms'ye çıktı.
  - Host temiz: `packets=100/s`, `dropped=0`.
- **Kullanıcı sesi "sürekli cızırtı" olarak tarif etti, tek tık değil.**
  - Hipotez: AAudio MMAP çıkış arabelleği 480 kare (10 ms), oyun yükünde yazıcı geç kalıyor, HAL `xruns=0` bildiriyor.
  - Deney: `--ei audio_buf_bursts 4` ile `buf=960` olan sürüm kuruldu. **Kullanıcıyla deneme sabaha kaldı.**
  - T-110 çıkış payını ölçüyor ve arabelleği uyarlamalı büyütüyor.

## 2026-10-02 ~00:50 — Dilimli (slice) kodlama değerlendirmesi: yapılmayacak

Araştırma (alt ajan; VideoToolbox SDK başlıkları, M6'da çalışma zamanı denemesi, tablet codec XML'leri; repo değişmedi).

**Mac, VideoToolbox:**
- Belgelenmiş tek dilim anahtarı `kVTCompressionPropertyKey_MaxH264SliceBytes`. Donanım kodlayıcı reddediyor (-12900, H.264 ve HEVC).
- HEVC dilim/tile anahtarı yok. Çıkış callback'i kare başına bir kez çağrılıyor; kısmi kare çıkışı yok.
- Özel `NumberOfSlices`:
  - normal kodlayıcıda 4–8 dilim üretiyor, kodlama süresi aynı (HEVC fast: 1 dilim 6,39 ms, 4 dilim 6,37 ms), callback yine 1;
  - düşük gecikmeli kodlayıcıda (`rtvc`) oturumu bozuyor (-12910).
- `NumberOfCores = 1`: M6'da tek kodlama motoru. Şeritlere bölünmüş paralel oturumlar toplam süreyi kısaltmıyor (4 şerit: ilk şerit 3,5 ms, tam kare 7–10 ms) ve boyutu büyütüyor.

**Tablet:**
- `OMX.hisi.video.decoder.hevc/avc`: yalnızca `adaptive-playback`, `can-swap-width-height`, `support-transcode`.
- **`partial-frame` yok, `low-latency` yok.** HEVC çözme: 720p 267 fps, 1080p 258 fps; kare başına ~3,7 ms sabit maliyet.

**Sonuç:** dilimli kodlama 0 ms kazandırır. Dilim dilim gönderme ve kısmi kare çözme iki cihazda da mümkün değil. Protokol değişikliği ve özel API riski de getirir. **Yapılmayacak.**

**Daha ucuz hedefler:**
1. Wi-Fi farkı (~16 ms):
   - Mac'i Ethernet'e bağlamak;
   - T-111 (kontrol bağlantısı BSD soket).
2. Ölçek: Performans/Oyun modu (%75/%66).
3. Kodlama süresi farkı (T-113): uygulama logunda `enc_ms` 9,4–9,8 ms. Aynı bayraklarla yalıtılmış bench 6,4 ms. ~3 ms olası kazanç; uygulama durdurulmuşken ölçülmeli.

## 2026-10-02 ~01:20 — T-113: `enc_ms` farkının kökü, VideoToolbox'un renk dönüşümü (−2,7 ms)

Uygulama durduruldu, Mac kilitsizdi, tablet ve adb'ye dokunulmadı. Ölçüm araçları:
- scratch prob (`t113/probe.swift`): ana ekrandan SCK ile 2800×1840 420f kare yakalıyor, tek değişkenli A/B;
- `--encode-bench --input-tags sck`;
- `--dump-video` (gerçek sanal ekran + SCK + `HEVCEncoder`).

**`enc_ms` neyi ölçüyor:** `FrameTrace.encUs = encodedUs − submittedUs`.
- `submittedUs`: `VTCompressionSessionEncodeFrame` çağrısından hemen önce.
- `encodedUs`: çıkış callback'inin başı.
- Slot ve kapı beklemesi (`hold`) dahil değil. VT içinde önceki karenin bitmesini bekleme dahil olurdu, ama etkisi yok (aşağıda).

**Elenen nedenler** (sentetik, HEVC `fast`, 60 tempo, p50):

| Değişken | Sonuç |
|---|---|
| `CompleteFrames` var/yok | 6,36 / 6,28 ms |
| Require/Enable HW | aynı |
| ExpectedFrameRate 60/120 | aynı |
| in-flight 1/2 | 6,3 / 6,4 ms |
| SCK yakalama aynı anda çalışıyor | 6,5 ms |

Uygulama logunda kare hızı 2/s iken `slot_wait=0` ve `enc` yine ~8,8 ms, yani kuyruk değil.

**Kök neden:**
- SCK (`colorSpaceName = sRGB`) 420f tamponlarına `ColorPrimaries=ITU_R_709_2`, **`TransferFunction=ITU_R_709_2`**, `YCbCrMatrix=ITU_R_709_2` ve sRGB `CGColorSpace` ekliyor.
- Oturum (STREAM_CONFIG ile tutarlı) `TransferFunction=IEC_sRGB` istiyor.
- VideoToolbox, etiketi oturumdan farklı her girdiyi kodlamadan önce oturumun renk uzayına **dönüştürüyor**.

Ölçüm (SCK içeriği, 60 tempo, p50):

| Tampon etiketi | Oturum etiketi | Kodlama |
|---|---|---|
| SCK | sRGB | 8,45 ms |
| etiket yok | sRGB | 6,1 ms |
| SCK, transfer → sRGB | sRGB | 6,1 ms |
| SCK | etiket yok | 6,1 ms |
| SCK | hepsi 709 | 6,1 ms |

- Kısmi etiket (yalnız matris) ya da yalnız `CGColorSpace` de dönüşümü tetikliyor: ~+1,4 ms.
- Etiketler tam eşleşince `CGColorSpace` önemsiz.
- Dönüşüm pikseli de değiştiriyor: neredeyse kayıpsız kodlamada (`Quality=1.0`) çözülen Y, kaynaktan ortalama **+8 seviye** (en çok 11), CbCr ~1 seviye farklı. Yani tablete giden görüntü Mac'tekinden biraz açık/soluktu (709 → sRGB gamma, zaten sRGB olan piksele uygulanıyor). Etiketler eşleşince fark 0.
- Kuyruk/throughput etkilenmiyor: `--encode-bench` max modda iki durumda da ~167 fps. Yalnız kare başına gecikme artıyor.

**Düzeltme (T-113):**
- `HEVCEncoder.encode`, yakalanan tamponun renk etiketlerini oturumunkilere yeniden yazıyor (`CVBufferSetAttachment`, piksel değişmez; `InputRetag`, Core'da birim testli).
- `MATEBRIDGE_INPUT_RETAG=0` eski davranışı geri getiriyor.
- Oturum başına bir `ev=input_retag from=ITU_R_709_2/ITU_R_709_2/ITU_R_709_2 to=ITU_R_709_2/IEC_sRGB/ITU_R_709_2` satırı yazılıyor.
- Bitstream VUI değişmedi: `--dump-video` "primaries=1 transfer=13 matrix=1 → matches STREAM_CONFIG".

**A/B, uygulamanın kodu ile:**

| Ölçüm | RETAG=0 | RETAG=1 |
|---|---|---|
| `--encode-bench --config fast --input-tags sck`, paced 60 | 9,3 ms | 6,6 ms |
| aynı, paced 120 `patch` | 8,7 ms | 6,0 ms |
| `--dump-video` (gerçek SCK, ~37 fps içerik) | 11,4 ms | 8,4 ms |

Uygulamanın 9,4–9,8 ms'si RETAG=0 bench'iyle örtüşüyor.

**Beklenen kazanç:** kare başına `enc` ve `cap_to_sent` p50 ~2,5–3 ms azalır. Renkler Mac'e daha sadık olur: tablet görüntüsü bir tık koyulaşır, yani doğru değere iner.

**Kalan fark:** düşük kare hızında (2–30 fps) kodlama daha yavaş: 2 fps'te 10,5 ms, 30 fps'te 7,4 ms, 120 fps'te 6,0 ms. Bunun nedeni muhtemelen kodlayıcının güç/frekans durumu. Ucuz bir düğmesi bulunmadı, ayrı kart gerektirmez.

## 2026-10-02 ~09:20 — Gecikme dökümü: görüntü ve ses (araştırma, kod değişmedi)

Canlı oturum (USB, panel 60 Hz, boşta masaüstü ~10 fps): `latency_us` ~18,9 ms, `video_ms` 51, `audio_ms` 70, `safety_ms` 31–32 (hatırlanan).

**Önceki oturumdan (T-114 sırasında, NOTES'a girmemişti):** oturum başına ~11 ses paketi 25–40 ms geç varıyor; host düzenli gönderiyor (`ring_ms_max=10`, 100 paket/s, `wire_dropped=0`). Her doğrulanmış alt taşma güvenlik payını +5 ms büyütüyor (tavan 40), değer `matebridge_audio` tercihlerinde saklanıyor.

**Görüntü (`video_ms` = `latency_us` + `pace_add` + 1 periyot, `AvSync.kt`):**

| aşama (60 Hz boşta) | ms |
|---|---|
| içerik → SCK teslimi | ~4 (tahmin) |
| SCK teslimi → sokete yazıldı (`cap_to_sent`) | 7,0 (ölçüm; enc 6,6) |
| USB + alım + şifre çözme | ~2,3 (türetilmiş) |
| çözme `dec_p50` | 12,8 (ölçüm; düşük fps'te DVFS etkisi, sürekli akışta 8,7–9,4) |
| çıkış → en erken slot (6 ms son an + vsync bekleme) | ~14 (türetilmiş) |
| kilit tutması `pace_add` | **16,7** (ölçüm; `d_us=16666`, tavanda) |
| tarama + OLED | ~9 (tahmin) |
| **toplam (ekran ortası)** | **~66–70** |

- Seyrek karelerde (yazı, imleç, hareketin ilk karesi) kilit her seferinde yeniden ediniliyor (`minimum = ideal + D`) ve D tavanda (bir periyot), çünkü boşluktan sonraki "soğuk" kareler 256 örneklik jitter geçmişini şişiriyor. Yani boşta her kareye **bilerek bir tam vsync** ekleniyor, akıcılığa katkısı yok.
- 120 Hz sürekli çizim ~38–40 ms, oyun modu (jitter 0, %66) ~28–32 ms (tahmin).
- Elenmiş kaldıraçlar tekrar önerilmedi: dilim kodlama, SurfaceControl, faz hizalama, H.264, yüksek bit hızı, son an/lead taraması, RealTime/LLRC, `setFrameRate` ile 120 Hz zorlama.

**Ses:**
- Host gönderimi düzenli. AUDIO_FRAME, kontrol bağlantısında ortak `dev.matebridge.session` kuyruğundan mühürlenip yazılıyor; aynı kuyruk gelen girdiyi de işliyor (`InputController.deliver` içinde `queue.sync`), bu bekleme ölçülmüyor.
- Tablet: kontrol okuyucu tek iş parçacığı, QUICKACK kontrol bağlantısında da açık, tablet tarafında Nagle yok.
- Boşluklar host yazımı ile tablet jitter tamponu arasında oluşuyor. `level_ms_floor` düşüşleri video fps=0 iken de görüldü → yalnız anahtar kare kuyruğu (USB 2.0, 480 Mb/s) açıklamıyor.
- Güvenlik payı yavaş küçülüyor: yalnız ses çalarken her 60 temiz pencerede −1 ms (40 → 20 ≈ 20 dk sürekli ses). Aralıklı masaüstü sesinde pratikte küçülmüyor → saklanan değer eski kötü oturumdan kalabiliyor.
- Alt taşmadan sonra yeniden dolum hedefi + son pencere aralığı; canlı logda seviye 75 ms'ye, `audio_ms` 113'e çıktı, PI denetleyici (en çok 5 ms/s) >10 s'de geri getirdi.
- Taban hesabı, güvenlik 20 ms'de bile: paketleme ~5 + zamanlayıcı ~2,5 + aktarım ~3 + seviye ~25–28 + AAudio tamponu 20 + cihaz ~4 ≈ **58 ms**.

**Ölçülmeyen:** paket başına varış aralığı ve tek yön gecikme (alan var: `capture_time_us` + `ClockSync`, log yok); host oturum kuyruğu gecikmesi.

## 2026-10-02 ~10:10 — T-115/T-116/T-117 cihazda (USB, kullanıcı çizim/kaydırma/yazı + 6,5 dk ses)

Kullanıcı sorun görmedi.

**Görüntü (T-115), saniyelik pencere ortalamaları, eski oturum (1011195598) → yeni (2611693067):**

| durum | `pace_add_ms` | `latency_us` (ms) | skip % | late_drops/s |
|---|---|---|---|---|
| 60 Hz boşta | 13,6 → **1,3** | 17,9 → 10,6 | 1,2 → 0,6 | 0,27 → 0,39 |
| 60 Hz hareket | 6,6 → 9,5 | 24,5 → 18,6 | 4,5 → 2,0 | 4,9 → 2,9 |
| 120 Hz boşta | 2,9 → 0,6 | 17,7 → 15,5 | 0,4 → 0,2 | 0,15 → 0,03 |
| 120 Hz hareket | 4,4 → 2,4 | 21,3 → 13,2 | 2,7 → 2,2 | 4,1 → 4,6 |

- `video_ms` boşta 51 → ~36. Akıcılıkta gerileme yok. Oturum açılışındaki ilk 120 Hz saniyelerinde 16–29 late_drop/s görüldü; sonra normale döndü.
- Yan bulgu: tablet loglarında `sid=` aynı oturumda ~20 sn'de bir `0` ile gerçek değer arasında gidip geliyor (yalnız log etiketi, oturum kopmuyor).

**Ses (T-116 + T-117), 387 s çalma:**
- Host temiz:
  - `write_int_ms_max` hiç 20'yi aşmadı (en çok 19,9);
  - `queue_lag` p50 0,02 / max 0,23 ms;
  - `partial_writes=0`, `gaps=0`, `send_gap` satırı yok.
  - `cap_to_write` p50 ~14 ms: 10 ms paketleme + 5 ms zamanlayıcı, beklenen.
- Tablet varışı:
  - `arr_int` p50 9,9 ms;
  - `owd` p50 5,7 / p95 7,5 ms (paket süresi hariç; yakalama→varış ≈ 15,7 ms);
  - `per_read` 1, `decrypt` < 1 ms (en çok 6,7).
- 6,5 dakikada **1 alt taşma**. O anda `audio_arrival_gap` `gap_ms=23 owd_ms=31 since_video_ms=20.9`, ardından `gap_ms=27 owd_ms=48 per_read=2`. Host o anda düzenli yazıyordu; paket aktarımda/tablet çekirdeğinde ~40 ms tutuldu, video okuyucu da aynı anda ~21 ms veri almamıştı. Bu, adb USB tüneli ya da tablet çekirdeği demek; ikisini ayırmak için Wi-Fi karşılaştırması gerekir.
- Diğer `audio_arrival_gap` satırları 20–30 ms, `owd` 14–28 ms; alt taşma yaratmadı.
- **Asıl maliyet: hatırlanan güvenlik payı.**
  - `safety_ms` 35–40 (açılışta saklı 40 ile başladı), `level_ms` ~42;
  - `audio_ms` ~80, `video_ms` ~36 → **`av_offset_ms` ~44** (ses geride);
  - küçülme dakikada −1 ms; tek alt taşma +5 ve 40'a geri.

## 2026-10-02 ~10:40 — T-118 cihazda; Apple Music ile ses+görüntü birlikte geç varıyor

- T-118: açılışta `safety_start stored=30 used=30` (eski 40). Kullanıcı: YouTube'da dudak senkronu iyi, takılma yok.
- Apple Music sırasında 1–2 dk'da bir küme hâlinde kesinti:
  - Tabletin aynı anda gördüğü:
    - `audio_arrival_gap` `gap_ms` 60–253, `owd_ms` 60–247, `per_read` 5–10 (toplu varış);
    - `MB/render` `net_p99_us` 130–270 ms, `latency_us` 127 ms;
    - ping RTT p95 143 ms.
  - Host o anlarda temiz: `write_int_ms_max` ≤ 18, `pending_bytes=0`, video 2–5 Mbps.
  - Yani iki bağlantı birlikte duruyor.
  - "Uyumlu" (AudioTrack) modda çok daha kötü duyuldu, çünkü güvenlik payı orada 5 ms'den başlıyor. Aynı donmalar daha çok alt taşma yaptı (13 alt taşma / 17 s).
- **Wi-Fi'de de aynı sıklıkta** (kullanıcı) → adb USB tüneli değil. Tablet logları Huawei'nin küçük logcat tamponunda kayboldu; `adb logcat -G 16M` ayarlandı.
- Panel hız değişimi (`display_rate`) ile zaman eşleşmesi yok. Mac birleşik logunda o anlarda Müzik uygulamasının USB/aygıt etkinliği görülmedi.
- Sıradaki: T-120 tablet donma dedektörü (süreç mi durdu, veri mi geç geldi).
- **Yan bulgu (T-119'u doğurdu):** APK kurulumu sonrası 0,4 s içinde iki kontrol bağlantısı + devir → `audio_unavailable reason=tap_create status=0` (noErr ama tap nesnesi yok). Ses bütün oturum boyunca Mac hoparlöründe kaldı.

## 2026-10-02 ~11:00 — Ses kesintilerinin kökü: keyframe fırtınası (T-120 ile)

- T-120 cihazda: `stall_stats` 200 tik/s, boşta `tick_late_max` < 20 ms.
- Kullanıcının duyduğu kesinti (USB, imleç hareketi, 120 Hz):
  - ses `gap_ms` 20–30 × 3, `owd` 13 → 41 ms, `tick_late_ms=0.1` → **tablet donmadı, veri geç geldi**;
  - hemen önce host 130 ms içinde 4 `keyframe_request` aldı (`reason=2,2,0,2` + `codec_config_resent`);
  - o saniye `sent_kbps` 38 879 (normal 2–5 Mbps), tablet `bytes` 0,48 → 4,87 MB, `drop=24`, `late_drops=46`.
- Önceki USB oturumundaki 160 ve 253 ms'lik boşluklar da aynı: 84628078–84628475 arası 4 istek, 84648980–84649638 arası 5 istek.
- Zincir:
  1. `FrameQueue.MAX_PENDING=2`: kısa bir yığılmada bekleyenlerin hepsi atılıyor ve keyframe isteniyor.
  2. Host her istekte yeni IDR zorluyor.
  3. Büyük IDR'ler bağlantıyı dolduruyor; ses ve video gecikiyor.
  4. IDR'ler yavaş çözülüyor, yeni taşma oluyor, yeni istek geliyor.
- Wi-Fi'de de aynı (kullanıcı) → bağlantı türünden bağımsız.
- Düzeltme kartları: T-121 (tablet: yığılmayı yut, istek sınırı), T-122 (host: istek birleştirme, IDR boyutu ölçümü).

## 2026-10-02 ~11:35 — T-121/T-122 cihazda: keyframe fırtınası bitti

**USB, ~14 dk** (Apple Music, imleç, 120 Hz çizim/kaydırma):
- `FRAMES_DROPPED` isteği **hiç yok**; `overflows=0`, `max_pending` çoğunlukla 1 (en çok 3).
- Ses varış boşlukları: > 20 ms 6 kez, > 50 ms **0**, en büyük 32,7 ms.
- 14 dakikada 1 alt taşma (33 ms boşluk, `tick_late_ms=0.1`). Kullanıcı kesinti duymadı.
- Önceki USB oturumu: 160–253 ms boşluklar, 6,5 dk'da 13 alt taşma.

**Host:**
- Açılıştaki istemci isteği `action=coalesced` (yeni tüketici IDR'si zaten zorlanmıştı).
- Arka plan/ön plan dönüşleri `reason=0 action=config_resent`; görüntü düzgün geri geldi.

**Wi-Fi, ~1–2 dk:**
- Kullanıcı kesinti duydu: 2 + 3 alt taşma.
- Fırtına yok: yalnız `src=reset` istekleri, `overflows=0`.
- Ses boşlukları 41–50 ms, `owd` 39–65 ms, `tick_late_ms` ~0.
- RTT p50 15–37 ms, p95 en çok 126 ms → saf Wi-Fi titreşimi.
- Güvenlik payı (USB'den hatırlanan 20–30 ms) Wi-Fi için yetersiz kalıyor.

T-120, T-121, T-122 done.

## 2026-10-02 ~12:05 — Kurulum betiği repoya alındı (`scripts/install-apk.sh`)

- Eski `install.sh` bir oturumun geçici klasöründeydi ve kayboldu. Aynı kurallarla yeniden yazıldı, bu kez repoda.
- Kurallar: yalnız paket + resource-id ile eşleşir, metinle asla. Yalnız iki düğmeye basılır:
  - `com.android.packageinstaller` `android:id/button1`;
  - `com.huawei.appmarket:id/hidden_card_install_button_continue`.
- AppGallery'de başka hiçbir şeye dokunmaz.
- Kurulumu `lastUpdateTime` ile doğrular, sonra MateBridge'i başlatır.
- Ekran ayrıştırma cihazda denendi; tam kurulum bir sonraki APK'da denenecek.

## 2026-10-02 ~12:45 — Wi-Fi ses kesintileri: iki kablosuz atlama, servis sınıfı, toplu varış

- Mac de Wi-Fi'de: `en1`, 802.11ax, kanal 52 (5 GHz DFS, 160 MHz), -48 dBm; Ethernet `en0` bağlı değil, `awdl0` etkin. Yani Mac → AP → tablet iki kablosuz atlama.
- Krita pinch (`off`, 3 dk):
  - 7 s boyunca 250–340 ms ses boşlukları (değerler ~250 ms'de kümeleniyor), RTT 275–300 ms;
  - o anda video yalnız 17–70 KB/s → bant genişliği değil, kablosuz duraksama/yeniden gönderim;
  - 13 alt taşma, pay 70'e çıktı.
- İkinci test (`off`, 3 dk): Mac'ten 100 ms aralıkla ping (AP ve tablet) temiz, en çok 56/63 ms. Ama uygulama `owd` en çok 80–100 ms, 8 alt taşma → ICMP'ye yansımayan, TCP/kuyruk kaynaklı gecikme.
- `MATEBRIDGE_SERVICE_CLASS=signaling` (kontrol/ses AC_VO, video AC_VI), 5,5 dk: 8 alt taşma, > 100 ms boşluk yok (en büyük ~75 ms). Kullanıcı: "sanki azaldı" → T-124 (varsayılan yap).
- Toplu varış: alt taşmadan sonra geciken paketler çalma yeniden başladıktan sonra geliyor ve seviye 134 ms'ye çıkıyor (`audio_ms` 187). T-118 kırpması yalnız çalma başlangıcında yapıldığı için devreye girmiyor → T-125.
- Kullanıcı ayrıca uygulama açılırken / ön plana gelirken tek seferlik kesinti duyuyor. Bu, oturumun yeniden kurulması (arka planda oturum kapanır, tasarım gereği). Ön plana gelişte yumuşak başlangıç ayrı bir konu.
- Önerilen en etkili adım: Mac'i Ethernet'e bağlamak (bir kablosuz atlamayı kaldırır).

## 2026-10-02 ~13:00 — Wi-Fi: ping temiz, TCP ses gecikiyor

- 20 dakika, 100 ms aralıklı ping (Mac → AP 192.168.1.1, Mac → tablet 192.168.1.105): 11 660 / 11 838 paket, **kayıp 0**.
- `signaling` testi sırasında (12:30:37–12:36:05) en çok 18 ms (AP) / 29 ms (tablet). Aynı anda ses `owd` 60–94 ms, 8 alt taşma.
- Sonuç: kablosuz bağlantı kopmuyor; gecikme TCP akışlarımızın içinde → T-126 (kontrol + video soketlerinin TCP durumunu logla).

## 2026-10-02 ~13:20 — Wi-Fi ses kesintilerinin kökü: videonun kablosuz kuyruğu doldurması (T-123..T-126 cihazda)

Wi-Fi, 5 dk; Krita pinch, uygulama değiştirme, Apple Music ön/arka plan.

**Tablet:**
- 13 alt taşma, `skip_trims` 12 → T-125 çalışıyor: kesinti sonrası ses hemen yetişiyor (kullanıcı: "daha iyi toparlıyor").
- T-123: Wi-Fi payı `stored=47`, USB'ye dönünce 20.
- Kesintiler uygulama değiştirirken (Krita kapatma, Apple Music ön/arka plan) ve pinch sırasında; ikisi de tam ekran değişimi.

**Host `ev=tcp` (T-126):**
- **Kontrol (ses) soketinde yeniden gönderim yok.**
- Ama kontrol `srtt` değeri, videonun havadaki verisiyle birlikte 20 → 60–100 ms'ye çıkıyor. Örnek: t=87–92, video `unacked` 78–148 KB, iki soketin `srtt`'si birlikte 49–83 ms.
- Video `snd_cwnd` 2–13 MB (sınırsız büyüyor), tek seferde 100–450 KB havada.
- Yani büyük video kareleri (tam ekran değişiminde) kablosuz kuyruğu dolduruyor ve ses, ayrı TCP bağlantısında ve AC_VO sınıfında olsa da arkasında bekliyor. Ping'in temiz kalması, kuyruğun yalnız patlama anlarında dolmasıyla uyumlu.

**Seçenekler** (ölçüme göre karar):
- Wi-Fi'de daha düşük bit hızı (panelden denenebilir, kod gerekmez);
- video gönderiminde havadaki veriyi sınırlama / pacing;
- Mac'i Ethernet'e almak (bir kablosuz atlama azalır; kullanıcı sonra deneyecek);
- Wi-Fi ses payını ~100 ms'ye çıkarmak (gecikme bedeli).

T-123, T-124, T-125, T-126 done.

## 2026-10-02 ~13:35 — Oturum sonu devir notu

- Durum: T-115..T-126 bitti, main = origin/main. Board'da inceleme bekleyen kart yok; T-127 (Wi-Fi video patlamaları) "ileride".
- Çalışan sürümler: host `build/MateBridge.app` varsayılan ayarlarla (`service_class=signaling`, `tcp_log=auto`); tablet APK 12:49 (T-125).
- Tablette log kaydı açık: `/data/local/tmp/mb.log*` (8 × 4 MB). `adb exec-out cat` ile alınır; gerekmezse `pkill logcat` ile durdurulur.
- Kullanıcıyla anlaşılan sıradaki konular (yeni oturumda önce konuşulacak):
  1. ~~Tablet ses düzeyi~~: kullanıcı yan tuşların zaten tablet sesini ayarladığını gördü, klavye kısayolu istenmiyor. Yerine: Mac ses düzeyi tap'e giden sesi etkiliyor mu, müzik çalarken `rms_dbfs` ile doğrula.
  1b. Kullanıcıya kısayollar anlatıldı: Ctrl+Shift+1–5 Mac'in Cmd+Shift kısayolları (Ctrl → Cmd, karar 0008); tablet yerel kısayolları Ctrl+Shift+6/7/8/9/0/Esc. Bir "kısayollar" yardım ekranı ya da README bölümü düşünülebilir.
  2. Mac uyku/kilit/uyanma sonrası toparlanma (PLAN Aşama 4 açık maddesi). Önce kullanıcıyla 5 dakikalık ölçüm.
  3. Uygulama ikonları (Android + Mac uygulama/menü çubuğu). Önce 2–3 taslak gösterilir, kullanıcı seçer.
  4. Temizlik: `.claude/worktrees` altındaki ~70 birleşmiş ajan kopyası silinecek.
- Bekleyen: Mac Ethernet denemesi (T-127); film modu fikri (şimdilik değil, 24 fps / 60 Hz takılması çözülemiyor).

## 2026-10-02 ~13:45 — Uyku/uyanma ölçümü (kullanıcıyla)

- **Tablet ekranı kapat/aç (~56 s):** tablet `BYE` → host `input_session_end released=0`, `display_grace_started seconds=10` → `display_teardown`. Ekran açılınca `handshake` → `video_streaming` **~170 ms**; kalem/klavye/ses çalışıyor. Grace 10 s'yi aştığı için sanal ekran yeniden oluşturuldu (pencere yerleşimi etkisi kullanıcıya soruldu).
- **Oturum açıkken `pmset sleepnow`:** ekran kapandı → Mac kilitlendi (kilit "hemen") → SCStream -3815 → T-081 `wake_display reason=capture_source_lost` (`UserIsActive "MateBridge: tablet session lost its display"`) → **sistem uykusu iptal**: pmset log'da yalnızca "Display is turned off/on", Sleep girdisi yok. Görüntü 1,2 s'de döndü, ses `audio_rebuild reason=wake`. Kullanıcı kilidi tablet klavyesiyle açtı. Yani MateBridge kasıtlı uykuyu engelliyor.
- Mac ayarları: `sleep 0`, `displaysleep 0` (hiç uyumuyor; MateBridge'den bağımsız), `womp 1`; Wi-Fi kartı `Wake On Wireless: Supported`. Tablette `nc` yok (toybox), WoL'u adb'den denemek mümkün değil.
- **Kullanıcı kararı:** uzun süre kullanılmayınca Mac uyusun (dakikayı kullanıcı macOS'ta kendisi ayarlar); tablet Mac'i Wake-on-LAN ile uyandırsın → T-128 (host: uykuya saygı, oturumda ekran uykusu yok, TXT `wol`), T-129 (tablet: magic packet). PROTOCOL.md §3.1'e TXT `wol` eklendi.

## 2026-10-02 ~14:45 — Gerçek uyku testi (T-128..T-131 kurulu, tablet Wi-Fi)

- `pmset sleepnow` (oturum açık): `ev=power state=will_sleep` → -3815 → `wake_display_suppressed reason=system_sleep` → pmset "Entering Sleep state due to 'Software Sleep'". **T-128 çalışıyor: kasıtlı uyku artık iptal olmuyor.**
- Ama oturum açık kaldı: TCP uykuda yaşadı; tablet 500 ms PING + 0,5 s'de bir video yeniden bağlanma (`video_open`/`video_closed`, vgen 165→177) → Mac `DarkWake ... wifibt ... E_RX_IP_PACKET` 14:42:19, 14:43:07, 14:43:55 (her biri 45 s). Host her karanlık uyanmada `display_create_failed` (uykuda ekran oluşmuyor). Tablet son karede dondu, `wol_start` hiç olmadı (oturum "ulaşılmış" sayıldı). Yani **gelen IP paketi Mac'i Wi-Fi üzerinden karanlık uyanmaya sokuyor** (magic packet olmadan bile).
- Kullanıcı uygulamadan çıkıp girdi → BYE → yeni oturum (karanlık uyanma penceresinde) → `power state=awake reason=session_started` → `wake_display reason=display_create_nil` → pmset "DarkWake to FullWake ... due to HID Activity" → `display_created` ~0,85 s. **T-128 karanlık uyanma düzeltmesi çalışıyor.** Kilit ekranı, şifre tablet klavyesiyle.
- Karar: host uykuya girerken `BYE(HOST_SLEEP)` (PROTOCOL BYE reason 6) → T-132; tablet "Mac uyku modunda", otomatik yeniden bağlanma yok, ön plana dönüşte/elle uyandırma + USB'de de `wol` öğrenme → T-133.
- Not: tablet USB taşımasında Bonjour keşfi çalışmıyor → `wol` hiç saklanmıyordu (test için tablet geçici olarak `transport=wifi`).

## 2026-10-02 ~15:05–15:21 — T-132/T-133 uyku testi ve uyandırma yöntemi deneyi

- **BYE(HOST_SLEEP) çalışıyor:** `host_sleep control=1 video=1` → `bye_sent reason=host_sleep` → `host_sleep_ack waited_ms=28 queue=ran flushed=true cut=0`; ses durdu. Tablet `bye_recv reason=6` → `host_sleep`, ~3,7 dk sessiz. Uyku boyunca 6 dk'da yalnız 1 karanlık uyanma (15:06:51, kaynağı bilinmiyor; önceki testte 2 dk'da 3).
- **Magic packet (WoL) bu Mac'i Wi-Fi'de uyandırmıyor:** tablet ön plana dönünce `wol_start reason=not_found macs=1 targets=3`, 3 bölümde 174 paket (255.255.255.255, alt ağ yayını, unicast :9) → pmset'te hiç Wake/DarkWake yok. Kullanıcı güç düğmesine bastı.
- **Deney (tablette `app_process` ile küçük prob, Mac `pmset sleepnow`, 15:16:46 uyku):**
  - ICMP ping 15:17:17: 5/5 cevap (Wi-Fi çipi uykuda cevaplıyor, RTT 4–62 ms), **uyanma yok**.
  - **TCP bağlantısı 192.168.1.106:47001 (host'un dinleyen kontrol portu) 15:18:32 → DarkWake 15:18:33 `E_RX_IP_PACKET`, connect 435 ms'de başarılı.**
  - Sonuç: tablet Mac'i **saklanan IP'ye doğrudan TCP bağlanarak** uyandırabilir; karanlık uyanmada oturum kurulursa T-128 `session_started` yolu Mac'i tam uyandırır (14:44 testinde doğrulandı).
- Yan bulgu: Mac güç düğmesiyle uyanınca tablet "Mac uyku modunda" durumunda beklediği için bağlanmadı; kullanıcı modu Otomatik'e alınca bağlandı (tasarım gereği; "Bağlan" yeterli olmalı).
- → T-134: uyandırma = saklanan IP:port'a doğrudan oturum bağlantısı (magic packet de kalır).

## 2026-10-02 ~15:47 — Uçtan uca uyku/uyandırma doğrulandı (T-132..T-134, Otomatik/USB)

- 15:47:10 `pmset sleepnow` → host `host_sleep_ack waited_ms=43 flushed=true` → tablet `bye_recv reason=6`, `host_sleep transport=usb` → 15:47:15 Sleep; **95 s boyunca hiç karanlık uyanma yok**.
- 15:48:46 kullanıcı tablet ekranını açtı → `host_sleep_clear reason=foreground` → USB denemesi (tünel yok) → `usb_lost` → Wi-Fi'de saklanan IP'ye `wake_connect attempt=1 result=ok ms=501` → Mac "Wake ... E_RX_IP_PACKET/HID Activity" 15:48:50 → host `power state=awake reason=session_started` + `wake_display` → görüntü ~2 s (kullanıcı). 15:48:54 `transport_migrate ok=1 to=usb`, `wol_refresh result=stored`.
- Kullanıcıdan: güç düğmesine gerek kalmadı. Magic packet hâlâ gönderiliyor (zararsız, Ethernet'te işe yarayabilir) ama uyandıran doğrudan TCP bağlantısı.

## 2026-10-02 ~17:25–17:35 — Tablet dosyaları (T-135/T-136) cihazda

- Kullanıcı tablette anahtarı açtı, "tüm dosyalara erişim" verdi; Mac menüsünden "Tablet dosyalarını aç" → `/Volumes/MatePad` (`http://127.0.0.1:47010/MatePad/`, `adb forward tcp:47010 tcp:47010`, yalnız USB). İlk bağlamada macOS ağ birimi izni sordu.
- Sürükle-bırak iki yönde çalıştı. Aktarım tavanı tutuyor: `bytes_out` ~19,8–20,0 MB/s, `throttled_ms` 2,5–3,5 s/s. **Kullanıcı: büyük dosya kopyalarken görüntüde takılma yok.**
- Sorun: bağlama her seferinde **tam ~90 s** (`mount result=ok ms=90187`, `ms=90120`); tablette 1 istek → 90 s sessizlik → normal trafik. → T-137.
- Olay: kablo bir ara kullanıcının telefonuna takılıydı; `install-apk.sh` artık HUAWEI olmayan cihaza kurmayı reddediyor (ecf7c9f).

## 2026-10-02 ~18:20 — T-137 sonrası: bağlama 0,17 s; Finder önizlemeleri tüm videoyu indiriyor

- Kök neden T-137: PROPFIND'daki quota özellikleri → webdavfs bağlama sırasında `WEBDAV_STATFS` sorusu, agent meşgul → 9×10 s = 90 s zaman aşımı (`webdav_sendmsg: sock_receive() timeout. vnop: 15`). Quota kaldırıldı → bağlama 172 ms (cihazda).
- Yeni sorun: 141 KB kopya "hazırlanıyor"da kaldı. Tablet dakikalarca ~20 MB/s gönderiyor (~4,4 GB); webdavfs önbelleğinde 2,7 GB dosya; Finder `showIconPreview=1` → video önizlemesi için webdavfs tüm dosyayı indiriyor ve küçük işler arkada bekliyor. → T-138.

## 2026-10-02 ~20:20 — T-139 cihazda doğrulandı (tablet dosyaları)

- Liste görünümü: İndirilenler'den 141 KB kopya hemen, çıkarma hemen.
- Simge görünümü (video önizlemesi tetiklenir): `bytes_out` ~20 MB/s kısa süre, `conn_overflow conns=9 limit=8 hard=12` bir kez, `conn_rejected`/`write_stalled` yok; küçük kopya hemen, çıkarma hemen (kullanıcı). Bağlama 107–163 ms.
- Not: araştırma ajanının takılan test bağlaması kullanıcının Finder'ını sistem genelinde yavaşlatmıştı (ilgisiz uygulama kopyası); ajan prompt'larına "takılı bağlama bırakma, ≤60 s, çıkışta ayır, arayüz açma" kuralı eklendi.

## 2026-10-02 ~20:40 — Oturum sonu devir

- Bu oturumda bitti: T-128..T-134 (uyku/uyandırma: BYE HOST_SLEEP, doğrudan TCP ile uyandırma), T-130/T-131 (ikon C), T-135..T-139 (tablet dosyaları USB/WebDAV, bağlama ~0,1 s, bağlantı sınırı 8+4). Hepsi main'de, push edildi; worktree'ler temizlendi.
- Açık / ileride: T-127 (Mac Ethernet ile Wi-Fi yeniden değerlendirme), film modu fikri, USB 3 kablo denemesi (tablet şu an 480 Mbit/s; USB 3 çıkarsa "hızlı aktarım" ayarı mantıklı), Finder'da 5+ büyük video aynı klasörde (webdavfs kendi sınırı).
- Host build/ içinden çalışıyor, tablet APK güncel (T-139), tablet taşıma modu Otomatik.

## 2026-10-02 ~21:30 — Faz 0 (güç/fps/120 Hz): tablet CPU dağılımı ve Huawei AGP yenileme kuralı

- **CPU (USB, 120 Hz, 70–100 fps akış):** toplam ~%157/800. İstemci %55–65, surfaceflinger %15, grafik HAL %9, media.codec %10, adbd %12 (USB tüneli), logd+logcat ~%4, Huawei/OS arka planı ~%10–13. Arka plandaki uygulamalar (YouTube, tarayıcı…) CPU 0, RAM dolu (278 MB boş, swap 719 MB). 10–25 fps akışta istemci %26–34. İstemci iş parçacıkları (93 fps): ana %11,6, MediaCodec_loop %8,7, CodecLooper %6,6, mb-decoder-out %5,9, mb-ctl-read %4,3, mb-audio %4,2. Ana iş parçacığı oturum boyunca her vsync'te uyanıyor (`MainActivity.vsyncCallback`).
- **Çözücü tavanı** (`/vendor/etc/media_codecs_performance.xml`, OMX.hisi HEVC): 1080p 258 fps, 4K 71 fps (~540–590 Mpx/s) → 2800×1840 ≈ 110 fps, %90 ≈ 135, %80 ≈ 170, %66 ≈ 240. AVC 1080p yalnızca 149 → HEVC daha hızlı.
- **Huawei yenileme kuralı** (`/hw_product/etc/xml/agp_config.xml`, AGPService FrameRateManager, native `libagp.so`): paketimiz strateji `60120` (dinamik, boşta 60). `JudgeFinalLcdFps` dokunma ya da animasyon/sahne oyu yokken stratejinin `idle` değerini seçiyor, `sfFps 120` olsa bile. Tüm uygulama türleri ve oyun varsayılanı (strateji 10) boşta 60. Ayar anahtarı `secure hw_screen_freq` (2 = akıllı); hiçbir modda boşta 120 yok.
- **Denendi, işe yaramadı:** `settings put system min_refresh_rate/peak_refresh_rate 120` (60 sn; dokunmasız anlarda yine 60 Hz, geri alındı). Önceden: `Surface.setFrameRate`, `preferredDisplayModeId`.
- **Kapalı yollar (dex/native incelemesi, cihazda tetiklenmedi):** sahne API'si (`com.huawei.hwaps.HwApsManagerEx` → `setSceneInfoToAgp`, `TARGET_FPS_120HZ`) hiddenapi engelli ve sunucu tarafı uid 1000 istiyor; AGP ayrıcalıklı çağrıları `ACCESS_SURFACE_FLINGER` ile koruyor (adb shell de geçemez); Oyun Alanı'na ekleme sistem imzası istiyor ve oyun stratejisi de boşta 60. Çözücü başlarken gelen `AGP-3rd: set news video event` 60'a çeken bir yol ("news video scene").
- **Açık aday (çıkarım, cihazda denenmeli):** uygulama içinde çalışan `android.view.DynamicRefreshRateHelper` (hwEmui.jar), normal kaydırma/animasyonların 120'ye çıkardığı "animasyon oyu"nu (AGP işlem 107) izinsiz gönderiyor. Akış hızlıyken sürekli bir animasyon (görünmez 1×1 View'u geçersiz kılan sonsuz ValueAnimator) boşta 120'yi tutabilir. Olmazsa yansımayla `DynamicRefreshRateHelper.setRefreshRate(...)`. Başarı ölçütü: dokunmasız anda `AGPService ... animFps 120` / `lcd_fps_scence current_fps:120`.
- Ölçüm araçları scratch'te: `mbmon.sh` (1 Hz panel hızı, sıcaklık, frekans, CPU payları; `/data/local/tmp/mbmon.txt`), `an.py` (pencere özeti, `MB/decoder recv` ve AGP dokunma olaylarıyla).

## 2026-10-02 ~22:45 — T-140 deneyi: animasyon oyu dokunmasız 120 Hz vermiyor

- Kurulum: USB, oyun modu, kullanıcı oyunda dokunmadan (klavye/gamepad). Ölçüm `mbmon.sh` + AGP logları.
- Animasyon yolu (sonsuz ValueAnimator + 1×1 View) ve yansıma yolu (`DynamicRefreshRateHelper.setRefreshRate`, hiddenapi reddetmedi) 60'ar sn kesintisiz açıkken panel %100 60 Hz. AGP `animFps -1`, animasyon kaydı yok. **Uygulama içinden dokunmasız 120 Hz yolu yok**; kalan yollar root ister (NOTES ~21:30).
- Yan bulgu: panel 60 Hz iken DISPLAY_RATE geri bildirimi host'u 60 fps'e indiriyor. Oyun modunda dokunmasız oyun fiilen 60 fps. Dokunma, BT fare ve trackpad paneli 120'ye çıkarıyor (T-051), klavye ve gamepad çıkarmıyor.
- Maliyet: durgun ekranda (kare yok) istemci ~%20 tek çekirdek, toplam ~%70–80/800. Oyunda (60 fps) istemci ~%100, surfaceflinger %15, codec %15, toplam ~%210–240/800. 5 dk oyunda SoC ~37 °C, frekans düşüşü yok.

## 2026-10-02 ~23:40 — T-141 cihazda: durgun ekranda istemci CPU yarıya indi

- Durgun ekran (USB): istemci ~%8–10 tek çekirdek (önce ~%19–21). Ana iş parçacığı %1,5, surfaceflinger 2 → 0. Toplam sistem ~56–78/800 (önce 66–79). Kalanlar: `mb-audio` %1,9, `mb-stall` %1,5 (200 uyanma/s), decoder/codec ~%2, `mb-session` %0,6.
- `idle state=on` ~1,4 s sonra geliyor. Host durgunken ~30 s'de bir kare gönderiyor (döngü kısa uyanıp tekrar uyuyor).
- Kullanıcı: yazıda duraklama sonrası ilk harf ve kaydırma/sürükleme "gayet iyi", sorun yok. `latency_us` 6–17 ms, `detach_slow` ve `gl_draw_failed` yok. `display_rate` dokunmada 60↔120 doğru geçiyor.
- Sıradaki aday: `mb-stall` (T-120 teşhisi) açılış parametresine bağlanabilir.
