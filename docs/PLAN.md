# MateBridge — Sade Plan (LITE v2)

**Tarih:** 2026-09-29
**Kaynak:** `docs/archive/PLAN-V2.1.md` (referans olarak duruyor)
**Hedef kullanıcı:** Tek kişi, kendi evi/masası. Dağıtım, mağaza, başka cihaz yok.

| Donanım | Durum |
|---|---|
| Mac mini, Apple M6, macOS 27.0.1 | ✅ doğrulandı. Şu an 1920×1080 bir monitör bağlı. |
| Huawei MatePad Pro, HarmonyOS 4.3 | Android APK çalışır. Google Play yok. Model/çözünürlük: **?** |
| Huawei klavye + trackpad, M-Pencil | Aşama 0'da probe ile ölçülecek |

---

## 1. Ne yapıyoruz? (tek cümle)

Ev ağında MatePad'i açınca Mac mini'nin ekranı tabletin OLED ekranında **tabletin kendi çözünürlüğünde, net ve akıcı** görünsün. M-Pencil ile Mac'te **basınç ve eğim hassasiyetli tasarım/çizim** yapabileyim, tabletin klavyesi ve trackpad'iyle de Mac'i günlük olarak kullanabileyim.

## 2. Neden kendimiz yazıyoruz? (hazır çözüm araştırması, 2026-09-29)

| Çözüm | Neden yetmiyor |
|---|---|
| Parsec (şu an kullanılan) | Mac host'ta 4:4:4 yok. Kalem desteği yalnızca Windows ve Wacom için. Android'den basınç gelmiyor. |
| Jump Desktop | Ücretli. Kalem basıncı yalnızca Mac/Windows istemcilerden geliyor, Android'den değil. |
| Duet Display | Basınç, eğim ve hover özellikleri iPad + Apple Pencil için. Android'de zayıf. |
| Moonlight + Sunshine | Oyun odaklı. Sunshine'ın Mac desteği zayıf, Mac'e basınç aktarmıyor. |
| [android-display](https://github.com/LukeLogix/android-display) (açık kaynak, Apache-2.0) | Küçük bir proje (~4.900 satır, Go + ObjC). Klavye ve trackpad desteği yok. **Referans kod olarak çok değerli:** sanal ekran, VideoToolbox ve tablet olayı enjeksiyonu için çalışan örnekler içeriyor. |

**Sonuç:** Android'den Mac'e basınçlı kalem + net görüntü + klavye/trackpad üçünü birlikte veren hazır bir çözüm yok. MateBridge tam bu boşluğu dolduracak.

## 3. V2.1'den neyi aldık, neyi attık?

**Korunanlar:**

- Riskli şeyleri küçük deneylerle doğrula, sonra üstüne kur.
- Video (donanım H.264/HEVC) temel yol. Tile/region motoru yok.
- Kuyruklar sınırlı: **en yeni kare kazanır**.
- Bağlantı koparsa **basılı tuş/tık/kalem durumu mutlaka bırakılır**.
- Girdi olayları görüntü trafiğinin arkasında beklemez.
- Ekran üstünde FPS/gecikme göstergesi. "Hızlı mı?" sorusu sayıyla cevaplanır.

**V2.1'e göre değişenler:**

- **Yerel ağ (Wi-Fi) birinci öncelik.** USB (`adb reverse`) aynı kodla gelen yedek "kablolu mod" oluyor.
- **Kalem basıncı ve eğimi çekirdek özellik.** V2.1'de M6'daydı, burada Aşama 2'de.
- **Sanal ekran çekirdek özellik.** Tablet tam çözünürlüğünde, Mac'e ayrı bir ekran olarak bağlanır. Netlik için şart. Dummy plug gerekmez.

**Atılan / ertelenen:** ADR'ler, 16 maddelik varsayım kaydı, ajan kuralları, CI, benchmark altyapısı, `PEN_DISPLAY`, interaction-aware scheduling, tile/adaptive motor, internet erişimi, installer, imzalama/notarization.

## 4. Mimari

```text
┌──────────────────── Mac mini M6 (host, Swift) ────────────────────┐
│ CGVirtualDisplay: tabletin çözünürlüğünde sanal ekran (HiDPI)      │
│   → ScreenCaptureKit → VideoToolbox HEVC/H.264 (low-latency)       │
│   → Video kanalı                                                   │
│ Girdi kanalı → CGEvent: klavye, fare/trackpad, tablet (basınç/eğim)│
│ Kontrol: Bonjour ile keşif, eşleştirme, ayarlar, heartbeat          │
│ Menü çubuğu uygulaması: durum, ayarlar, izinler                    │
└────────────────────────────────────────────────────────────────────┘
             ▲  Wi-Fi (ev ağı)  — veya —  USB: adb reverse
             ▼
┌────────────── MatePad Pro (client, Kotlin / Android) ─────────────┐
│ Video → MediaCodec (donanım decode) → SurfaceView, tam ekran        │
│ M-Pencil: basınç, eğim, hover, kalem tuşu, geçmiş örnekler → Girdi │
│ Klavye (scan code) + trackpad (pointer capture) + dokunma → Girdi  │
│ İstatistik katmanı: FPS, bitrate, gecikme                           │
└────────────────────────────────────────────────────────────────────┘
```

**Kanallar:**

- **Kontrol + girdi:** TCP, `TCP_NODELAY`. Sıralı ve kayıpsız, çünkü tuş bırakma olayı asla kaybolmamalı.
- **Video:** Önce TCP ile başlanır, çünkü en basiti. Wi-Fi'de gecikme sıçramaları görülürse UDP'ye geçilir: kare parçalama, kayıpta yeni keyframe isteği. Paket formatı bu geçişe hazır tasarlanır. android-display bu UDP yolunu zaten uygulamış, oradan örnek alınır.

**Protokol:** Uzunluk önekli basit ikili mesajlar: `[tip:1][uzunluk:4][veri]`. İlk mesaj `HELLO` (sürüm, tablet çözünürlüğü/DPI, codec desteği, kalem yetenekleri). `docs/PROTOCOL.md` tek sayfa kalır.

## 5. Önemli tasarım kararları

1. **Klavye / Türkçe Q:** Tablet karakter göndermez, fiziksel tuş konumunu gönderir (Android scan code → macOS keycode). Türkçe karakterleri ve kısayolları, Mac'te seçili "Türkçe Q" giriş kaynağı çözer. Ctrl↔Cmd eşlemesi ayarlardan değiştirilebilir.
2. **Kalem:** Android `MotionEvent`'ten basınç, eğim (`AXIS_TILT` + `AXIS_ORIENTATION` → tiltX/tiltY), hover, kalem tuşu ve **geçmiş örnekler** (`getHistorical*`) alınır. Mac'te bunlar proximity + tablet-point olayları olarak enjekte edilir (android-display'deki yöntem). Çizim akıcılığı için ara örnekler atılmaz, gruplanıp gönderilir.
3. **Görüntü netliği (OLED + tasarım):**
   - Sanal ekran tabletin tam piksel çözünürlüğünde, HiDPI (Retina) modunda.
   - HEVC, LAN'da yüksek bitrate (ör. 30–80 Mbps, ölçülerek ayarlanır).
   - Renk alanı etiketleri doğru (sRGB/Display P3), renk kayması olmasın.
   - 4:4:4 renk (yazı saçaklanmasını tamamen önler) Aşama 5'te bir deney olarak ele alınır. Tabletin donanım decoder'ı desteklemeyebilir.
4. **Güvenlik (ev ağı için yeterli):** Mac ilk bağlantıda "MatePad bağlanmak istiyor → İzin ver" onayı ister ve cihazı hatırlar. Onaylanmamış cihaz ne görüntü alır ne girdi gönderebilir. Şifreleme Aşama 4'te gelir.
5. **İzinler ve imza:** Screen Recording + Accessibility izinleri gerekiyor. Uygulama her derlemede aynı Apple Development sertifikasıyla imzalanır, yoksa macOS izinleri sıfırlar.
6. **Ağ tavsiyesi:** Mac mini mümkünse kabloyla (Ethernet) modeme bağlı olmalı, tablet 5/6 GHz Wi-Fi'de.

## 6. Aşamalar

Her aşamanın sonunda **çalışan** bir şey olur. "Bitti" kontrol listesi geçmeden sonraki aşamaya geçilmez.

### Aşama 0 — Hazırlık ve keşif

**Araç kurulumu (Mac):**
- [ ] **Xcode** (App Store). Şu an yalnızca Command Line Tools var.
- [ ] **Android Studio.** Android SDK, `adb` ve JDK'yı birlikte getirir.

**Tablet hazırlığı (MatePad):**
- [ ] Model ve ekran çözünürlüğü kaydedilir.
- [ ] Geliştirici seçenekleri açılır: Ayarlar → Tablet hakkında → Yapı numarasına 7 kez dokun. Ardından USB hata ayıklama açılır.
- [ ] Gerekirse "Saf mod" (Pure mode) kapatılır, yoksa APK kurulumu engellenebilir.

**Doğrulamalar:**
- [x] `CGVirtualDisplay` macOS 27.0.1'de mevcut (2026-09-29).
- [ ] Mac'te test sanal ekranı oluşturulur, Sistem Ayarları → Ekranlar'da görünüyor ve ScreenCaptureKit ile yakalanabiliyor.
- [ ] **Girdi probu (küçük Android uygulaması):** Tek ekran. Kalem, klavye ve trackpad olaylarını ekrana ve dosyaya yazar.
  - Kalem: basınç aralığı, eğim/yön, hover, kalem tuşu, silgi, örnekleme hızı, geçmiş örnek sayısı
  - Klavye: scan code'lar, Türkçe tuşlar, Ctrl/Alt/Fn/Huawei tuşu, sistemin yuttuğu kısayollar
  - Trackpad: `requestPointerCapture()` ile göreli hareket, iki parmak kaydırma, sağ tık
- [ ] Bulgular `docs/NOTES.md`'ye yazılır.

**Bitti:** Araçlar kurulu, tablete APK yüklenebiliyor, kalem/klavye/trackpad'in ne verdiği biliniyor, sanal ekran yakalanabiliyor.

### Aşama 1 — Görüntü (Wi-Fi üzerinden sanal ekran)

- [x] Repo iskeleti (bkz. §7), iki uygulama derleniyor.
- [x] Mac: tablet çözünürlüğünde sanal ekran → ScreenCaptureKit → VideoToolbox → ağ.
- [x] Android: Bonjour ile Mac'i bulur → bağlanır → MediaCodec → tam ekran.
- [x] Mac'te bağlantı onayı (bkz. §5.4).
- [x] En yeni kare kazanır: her aşamada kuyruk en fazla 1–2 kare.
- [x] İstatistik katmanı: FPS, bitrate, kodlama ve ağ süresi.
- [x] Bağlantı kopunca "Bağlantı yok" gösterilir, ağ geri gelince yeniden bağlanır.
- [ ] TCP ve UDP video karşılaştırması. Kazanan yol seçilir. (Ertelendi: USB ve Wi-Fi ölçümlerinde ağ tarafı darboğaz değil; akıcılık Faz 5.)
- [x] Aynı kodla USB modu (`adb reverse`) çalışıyor.

**Bitti:** Tablet Mac'in ikinci ekranı olarak 60 FPS'e yakın çalışıyor. Yazılar tabletin OLED'inde net. 30 dakika boyunca bellek şişmiyor, donma yok.

**Durum (2026-09-30):** Tamamlandı. Kanıt: NOTES 2026-09-29/30. Akıcılık iyileştirmesi Faz 5'e taşındı.

### Aşama 2 — Kalem ve dokunma (projenin asıl farkı)

- [ ] Girdi kanalı ve `docs/PROTOCOL.md`.
- [ ] Koordinat dönüşümü: tablet pikseli ↔ sanal ekran noktası. Tek bir yerde tanımlanır.
- [ ] Kalem: yakınlık (proximity) giriş/çıkış, uç down/up, basınç, eğim, hover, geçmiş örnekler.
- [ ] Kalem tuşu → sağ tık veya ayarlanabilir eylem. Silgi (varsa).
- [ ] Avuç içi reddi: kalem yakındayken dokunma yok sayılır.
- [ ] Dokunma: tek dokunuş = tık, sürükleme; iki parmakla kaydırma.
- [ ] Bağlantı koparsa kalem/tık durumu bırakılır.
- [ ] Uygulama testleri: **Krita** (ücretsiz, basınç testi için ideal) + kullandığın tasarım uygulamaları. Sonuçlar `NOTES.md`'de tabloya yazılır.
- [ ] Kalem gecikmesi ölçülür. Gerekirse tablette yerel imleç/hover noktası çizilir.

**Bitti:** Krita'da basınçla kalınlaşan/incelen fırça ve eğim çalışıyor. 15 dakikalık çizimde kopuk çizgi veya takılı kalan tık olmuyor.

### Aşama 3 — Klavye ve trackpad

- [ ] Klavye: tuş down/up, scan code → macOS keycode tablosu, değiştiriciler. Tekrar macOS'a bırakılır.
- [ ] Türkçe Q, Cmd kısayolları, Ctrl↔Cmd ayarı.
- [ ] Trackpad: göreli imleç, sol/sağ tık, sürükle-bırak, piksel hassasiyetinde dikey/yatay kaydırma.
- [ ] Dokunmatik ekranda **iki parmakla yakınlaştırma** (pinch → macOS büyütme hareketi; Krita'da tuval yakınlaştırma). Kullanıcı isteği, 2026-09-30. Protokolde bugün iki parmak için yalnızca `SCROLL` var; yeni bir hareket mesajı ve fixture gerekir (protokol değişikliği, orkestratör).
- [ ] Uygulama arka plana geçince veya klavye kapağı çıkınca tüm tuşlar bırakılır.

**Bitti:** Harici klavye/fare olmadan 1 saat kod yazılıp tasarım yapılabiliyor. Türkçe karakterler, kısayollar, kaydırma ve sürükleme sorunsuz.

### Aşama 4 — Günlük kullanım cilası

- [ ] Mac: menü çubuğu uygulaması, oturum açılışında otomatik başlama.
- [ ] Tablet uygulaması açılınca kendiliğinden bağlanır, ekran uyumaz.
- [ ] Mac kilit/uyku/uyanma sonrası toparlanır. Sanal ekran yeniden oluşturulur.
- [ ] Ayarlar: çözünürlük/ölçek, FPS, bitrate, codec, Ctrl↔Cmd, kalem tuşu eylemi.
- [ ] Mod seçimi: tablet = ikinci ekran / tablet = ana ekran (monitörsüz) / ekran yansıtma.
- [ ] Oturum şifrelemesi (eşleşmede paylaşılan anahtar).
- [ ] Log dosyası (`~/Library/Logs/MateBridge/`) ve menüde "logları aç".

**Bitti:** Bir hafta boyunca günlük iş için kullanılıyor, "yeniden başlatmam gerekti" türünden sorun kalmıyor.

### Aşama 5 — İsteğe bağlı iyileştirmeler (ihtiyaç oldukça)

- **Akıcılık: kare zamanlaması (frame pacing).** Kullanıcı kararı, 2026-09-29. Faz 1 sonunda Mac 60,0 fps düzenli gönderiyor, USB'de geç kare çoğu saniye 0. Ama iki bağımsız 60 Hz saat (Mac sanal ekranı ve tablet paneli) yüzünden periyodik takılma kalıyor. Kullanıcıya göre **Parsec aynı tablette daha az takılıyor**, yani iyileştirme payı var. Hedef: Parsec'le göz karşılaştırmasında en az eşit. Denenmiş olanlar: T-016 (zamanlı `releaseOutputBuffer`), T-018 (GL yolu), T-019 (GL titreşim tamponu, park edildi). Bulgular NOTES 2026-09-29.
- 4:4:4 renk deneyi (yazı/ince çizgi netliği)
- Tabletin yüksek yenileme hızı (90/120 Hz). Engeller: HarmonyOS video ve GL yüzeyini 60 Hz'de tutuyor, decoder kapasitesi "4K@60" (2800×1840'ta kabaca ~90 fps), Mac'te kare başına kodlama ~13–15 ms. Önce 60 fps akıcılığı. Kalem için 120 Hz gerekmez (kalem 330 Hz örnekleniyor ve ekran hızından bağımsız gönderiliyor).
- Kalem için tahmini ink (local prediction)
- **Wi-Fi'de kalem örneklerini zamana yayma (host).** Kullanıcı kararı, 2026-09-30: acelesi yok, en sona. Ölçüm (NOTES aynı tarih): USB'de kalem olayları Mac'e 2,8 ms aralıkla düzgün ulaşıyor; Wi-Fi'de aynı ~362 olay/sn öbekleniyor (aralık medyan 0,5–1,1 ms, %95 ~10 ms, en çok 10–14 ms) ve Krita'da hızlı eğriler köşeli görünüyor. Çözüm fikri: host örnekleri tabletin zaman damgasına göre enjekte eder (Wi-Fi'de tahminen 8–12 ms ek gecikme, USB'de ~0; kalem kalkışı ve release-all beklemeyi anında boşaltır). Kullanıcı çizim ve oyun için USB kullanacağını söyledi.
- Ses aktarımı, pano paylaşımı
- Kısayol çubuğu (tasarım uygulamaları için ekranda tuşlar: geri al, fırça boyutu vb.)

## 7. Repo yapısı ve çalışma şekli

- Repo yapısı: `README.md` → *Layout*.
- Ajan kuralları: `AGENTS.md`. Roller, paralellik ve Codex kullanımı: `docs/WORKFLOW.md`.
- İşler: `backlog/tasks/` altındaki görev kartları, durum özeti `backlog/BOARD.md`.
- Kararlar: `docs/decisions/`. Bulgular: `docs/NOTES.md`. Log kuralları: `docs/LOGGING.md`.
- Ölçüm basit tutulur: ekran üstü FPS/gecikme, gerektiğinde telefon kamerasıyla slow-motion gecikme testi.
- android-display'den kod alınırsa Apache-2.0 gereği kaynak belirtilir.

## 8. Başarı tanımı

> MatePad'i açıyorum, birkaç saniye içinde Mac mini'nin ekranı tabletin OLED'inde net şekilde beliriyor. M-Pencil ile Krita'da/tasarım uygulamamda basınç hassasiyetiyle çiziyorum. Klavyesi ve trackpad'iyle Türkçe yazıp kod yazıyorum. Wi-Fi bir an koparsa kaldığım yerden devam ediyorum.
