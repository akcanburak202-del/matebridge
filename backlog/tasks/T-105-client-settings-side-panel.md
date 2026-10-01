---
id: T-105
title: Tablet — akış sırasında sağ yan ayarlar paneli (Ctrl+Shift+6, SETTINGS_OPEN), bit hızı seçimi
status: in_progress
phase: 4
owner: android-client-dev
depends_on: [T-104]
decisions: [0013, 0008]
files:
  - client-android/app/src/main/
  - client-android/app/src/test/
  - backlog/tasks/T-105-client-settings-side-panel.md
---

## Amaç

Karar 0013: akış sürerken ayarlara bağlantı paneline dönmeden ulaşılır. Sağda yarı saydam bir yan panel açılır; video ve ses arkada sürer.

## Kabul kriterleri

- [ ] **Açma:**
  - Ctrl+Shift+6 (scan code ile, mevcut yerel kısayol mekanizması `KeyTracker` üzerinden) paneli açar. Tuşlar Mac'e gitmez; DOWN/UP eşleşmesi korunur.
  - Kontrol bağlantısından gelen `SETTINGS_OPEN` (0x08), akış görünürken paneli açar. Panel zaten açıksa bir şey olmaz; akış yoksa yok sayılır.
  - HELLO'da bit9 `SETTINGS_PANEL` gönderilir.
- [ ] **Kapatma:** Esc (panel açıkken yerel, Mac'e gitmez), Ctrl+Shift+6 tekrar, video alanına dokunma, kapat düğmesi. Uygulama arka plana geçerse ya da akış biterse panel kapanır.
- [ ] **Girdi güvenliği:**
  - Panel açılırken önce `RELEASE_ALL(USER)` gönderilir.
  - Panel açıkken hiçbir girdi Mac'e gitmez: kalem, dokunma, touchpad, klavye. Pointer capture bırakılır ki panele dokunulabilsin.
  - Kapanınca capture ve girdi yönlendirmesi eski hâline döner.
  - Panel açılıp kapanırken basılı tuş, düğme ya da kalem takılı kalmaz (birim testleri).
- [ ] **Görünüm:** sağda yarı saydam yan panel, kaydırılabilir.
  - Bölümler: Bağlantı / Görüntü / Ses / Girdi / Diğer.
  - Video alanı yeniden boyutlanmaz; panel videonun üstüne biner.
  - Views kullanılır, Compose yok (karar 0004).
- [ ] **İçerik.** Bağlantı panelindeki ayarlarla **aynı kaynak** kullanılır: kalıcılık ve uygulama mantığı iki kez yazılmaz, iki panel aynı kontrol kurucusunu ya da aynı ayar modelini paylaşır.
  - Bağlantı: Otomatik/USB/Wi-Fi; mevcut bağlantı yeni seçime uymuyorsa T-096 mantığıyla geçiş. "Bağlantıyı kes": BYE gönderir, bağlantı paneline döner.
  - Görüntü: mod (Netlik/Akıcı/Performans) ve **bit hızı** (Otomatik / 15 / 30 / 60 / 100 Mbps).
    - Bit hızı `Settings`'te kalıcıdır. `STREAM_PREFS.bitrate_kbps` ile gider; Otomatik = 0.
    - Değişince `STREAM_PREFS` hemen gönderilir.
    - Panelde host'un uyguladığı değer gösterilir: `STREAM_CONFIG.bitrate_kbps`, örn. "Uygulanan: 60 Mbps".
  - Ses: aç/kapa, çıkış (Düşük gecikme/Uyumlu).
  - Girdi: imleç hızı (mevcut adımlar), parmak dokunmasını kapat, kalem izi, kalem noktası.
  - Diğer: pano paylaşımı, istatistik katmanı.
  - Kısayol listesine Ctrl+Shift+6 eklenir.
- [ ] **Bağlantı paneline de bit hızı seçimi** eklenir (aynı kaynak).
- [ ] Log: `ev=settings_panel open|close via=shortcut|host|...` (karakter ya da metin loglanmaz).
- [ ] Testler: kısayolun eşlenmesi, açma/kapama ve girdi kapısı (release-all sırası), bit hızı kalıcılığı ve `STREAM_PREFS` kodlaması.
- [ ] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (tek seferde, kullanıcıyla).

## Plan

**Saf mantık (JVM testli):**
1. `input/KeyTracker.kt`: `LocalAction.SETTINGS`; Ctrl+Shift+6 = evdev scan `7` (fiziksel konum, diğer rakam kısayolları gibi).
2. `settings/SettingsPanelState.kt` (yeni): açık/kapalı durumu, `open(via, streaming)` / `close(via)` (değişmediyse no-op), `ev=settings_panel open|close via=…` logu; `inputAllowed(base)`; `keyWhileOpen(KeyFrame)` → `CLOSE` (Esc ya da Ctrl+Shift+6, repeat 0), `LOCAL(action)` (diğer Ctrl+Shift kısayolları), `CONSUME` (kapanış tuşunun tekrarları/UP'ı, BACK), `PASS` (Android'e, panelde gezinme). Panel açıkken `capture.onKey` hiç çağrılmaz → Mac'e tuş gitmez.
3. `settings/SettingsCatalog.kt` (yeni): iki panelin **ortak** kontrol tanımı. `SettingsHost` arayüzü (MainActivity uygular, kalıcılık + uygulama burada bir kez yazılır) ve bölümler Bağlantı / Görüntü / Ses / Girdi / Diğer; öğe tipleri Choice / Toggle / Stepper / Action / Info. "Bağlantıyı kes" ve "Uygulanan: N Mbps" yalnız akış panelinde. Kısayol listesine Ctrl+Shift+6.
4. `stream/Bitrate.kt` (yeni): seçenekler Otomatik(0)/15/30/60/100 Mbps, etiketler, "Uygulanan" biçimi. `StreamMode.toPrefs(bitrateKbps)`. `Settings.bitrateKbps()` / `setBitrateKbps()` (yalnız geçerli seçenekler, değilse 0).
5. `session/TransportSwitch` (AutoTransport.kt yanına): yeni seçim mevcut bağlantıya uyuyorsa yeniden bağlanma yok (AUTO her zaman uyar; USB/Wi-Fi yalnız aynı taşıyıcıdaysa).
6. `SessionMachine`: `SettingsOpen` ACCEPTED/STREAMING'de `Action.OpenSettings`; `SessionController` → `SessionListener.onSettingsOpen()`; `setStreamPrefs(prefs)`; ctor'a başlangıç bit hızı; `stream_prefs_sent` logu bit hızını yazar.

**Android (Views):**
7. `settings/SettingsViews.kt` (yeni): katalogu bir `LinearLayout`'a çizer (bölüm başlığı, segment düğmeleri, ±, aç/kapa), `refresh()`. Bağlantı paneli ve yan panel aynı sınıfı kullanır.
8. `layout/activity_main.xml`: bağlantı paneli `ScrollView` içine; XML'deki taşıyıcı/istatistik düğmeleri kalkar (katalogdan gelir). Yan panel: root'un en üstünde tam ekran saydam katman + sağda yarı saydam, kaydırılabilir panel (başlık + Kapat). Video yeniden boyutlanmaz.
9. `MainActivity`: `SettingsHost` uygulaması; `syncInputActive` panel açıkken kapalı (→ `InputCapture.setActive(false)` = önce `RELEASE_ALL(USER)`, sonra pointer capture bırakılır); açma: kısayol / `SETTINGS_OPEN` (yalnız akış görünürken); kapama: Esc, kısayol, video alanına dokunma (ACTION_UP'ta, yarım jest sızmaz), Kapat, geri, `onPause`, akış bitişi. "Bağlantıyı kes": BYE + otomatik bağlanma durur, "Bağlan" ile devam. HELLO bit9.

**Testler:** KeyTracker Ctrl+Shift+6 eşlemesi; `SettingsPanelState` aç/kapa + tuş kararları; InputCapture ile kapı: açılışta bırakmalar → `RELEASE_ALL(USER)` sırası, açıkken hiçbir şey gitmez, kapanınca eşleşmemiş UP gitmez; bit hızı kalıcılığı; `STREAM_PREFS` kodlaması (bitrate) ve SessionMachine gönderimi; `SETTINGS_OPEN` → `OpenSettings` (yalnız kabul edilmiş oturum); katalog bölüm sırası/öğeleri; TransportSwitch.

## Handoff
