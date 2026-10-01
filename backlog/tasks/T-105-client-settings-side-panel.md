---
id: T-105
title: Tablet — akış sırasında sağ yan ayarlar paneli (Ctrl+Shift+6, SETTINGS_OPEN), bit hızı seçimi
status: done
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

- [x] **Açma:**
  - Ctrl+Shift+6 (scan code ile, mevcut yerel kısayol mekanizması `KeyTracker` üzerinden) paneli açar. Tuşlar Mac'e gitmez; DOWN/UP eşleşmesi korunur.
  - Kontrol bağlantısından gelen `SETTINGS_OPEN` (0x08), akış görünürken paneli açar. Panel zaten açıksa bir şey olmaz; akış yoksa yok sayılır.
  - HELLO'da bit9 `SETTINGS_PANEL` gönderilir.
- [x] **Kapatma:** Esc (panel açıkken yerel, Mac'e gitmez), Ctrl+Shift+6 tekrar, video alanına dokunma, kapat düğmesi. Uygulama arka plana geçerse ya da akış biterse panel kapanır.
- [x] **Girdi güvenliği:**
  - Panel açılırken önce `RELEASE_ALL(USER)` gönderilir.
  - Panel açıkken hiçbir girdi Mac'e gitmez: kalem, dokunma, touchpad, klavye. Pointer capture bırakılır ki panele dokunulabilsin.
  - Kapanınca capture ve girdi yönlendirmesi eski hâline döner.
  - Panel açılıp kapanırken basılı tuş, düğme ya da kalem takılı kalmaz (birim testleri).
- [x] **Görünüm:** sağda yarı saydam yan panel, kaydırılabilir.
  - Bölümler: Bağlantı / Görüntü / Ses / Girdi / Diğer.
  - Video alanı yeniden boyutlanmaz; panel videonun üstüne biner.
  - Views kullanılır, Compose yok (karar 0004).
- [x] **İçerik.** Bağlantı panelindeki ayarlarla **aynı kaynak** kullanılır: kalıcılık ve uygulama mantığı iki kez yazılmaz, iki panel aynı kontrol kurucusunu ya da aynı ayar modelini paylaşır.
  - Bağlantı: Otomatik/USB/Wi-Fi; mevcut bağlantı yeni seçime uymuyorsa T-096 mantığıyla geçiş. "Bağlantıyı kes": BYE gönderir, bağlantı paneline döner.
  - Görüntü: mod (Netlik/Akıcı/Performans) ve **bit hızı** (Otomatik / 15 / 30 / 60 / 100 Mbps).
    - Bit hızı `Settings`'te kalıcıdır. `STREAM_PREFS.bitrate_kbps` ile gider; Otomatik = 0.
    - Değişince `STREAM_PREFS` hemen gönderilir.
    - Panelde host'un uyguladığı değer gösterilir: `STREAM_CONFIG.bitrate_kbps`, örn. "Uygulanan: 60 Mbps".
  - Ses: aç/kapa, çıkış (Düşük gecikme/Uyumlu).
  - Girdi: imleç hızı (mevcut adımlar), parmak dokunmasını kapat, kalem izi, kalem noktası.
  - Diğer: pano paylaşımı, istatistik katmanı.
  - Kısayol listesine Ctrl+Shift+6 eklenir.
- [x] **Bağlantı paneline de bit hızı seçimi** eklenir (aynı kaynak).
- [x] Log: `ev=settings_panel open|close via=shortcut|host|...` (karakter ya da metin loglanmaz).
- [x] Testler: kısayolun eşlenmesi, açma/kapama ve girdi kapısı (release-all sırası), bit hızı kalıcılığı ve `STREAM_PREFS` kodlaması.
- [x] `./scripts/check.sh` geçiyor. Cihaz testi orkestratörde (tek seferde, kullanıcıyla).

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

- **Commit:** `2c33b20` (kod + testler), review düzeltmeleri `6d9cafa`, plan `c7ff1a8`; dal `task/T-105-client-settings-side-panel` (main `0a329b5` üstünde).
- **check.sh:** geçti (`check.sh: ALL OK`; client-android assembleDebug + testDebugUnitTest dahil). Yeni testler: `SettingsPanelGateTest` 10, `SettingsCatalogTest` 8, `BitrateSettingTest` 7, `MigrationCancelTest` 3, `CoalescedPostTest` 5, hepsi geçti.
- **Dokunulan dosyalar** (hepsi `client-android/app/src/`):
  - yeni: `main/.../settings/{SettingsPanelState,SettingsCatalog,SettingsViews,CoalescedPost}.kt`, `main/.../stream/Bitrate.kt`;
  - değişen: `MainActivity.kt`, `input/KeyTracker.kt`, `session/{AutoTransport,SessionController,SessionMachine,Settings}.kt`, `stream/StreamMode.kt`, `res/layout/activity_main.xml`, `res/values/strings.xml`;
  - testler: `test/.../input/SettingsPanelGateTest.kt`, `test/.../settings/{SettingsCatalogTest,CoalescedPostTest}.kt`, `test/.../session/{BitrateSettingTest,MigrationCancelTest}.kt`.
- **Yapı:**
  - `SettingsCatalog` (saf): bölümler Bağlantı / Görüntü / Ses / Girdi / Diğer, öğeler Choice / Toggle / Stepper / Action / Info. `SettingsHost` arayüzünü `MainActivity` **bir kez** uygular (kalıcılık + uygulama). İki panel aynı katalogdan `SettingsViews` ile çizilir; her değişiklik ikisini de yeniler. Yalnız yan panelde: "Bağlantıyı kes", "Uygulanan: N Mbps".
  - Bağlantı paneli artık `ScrollView`; XML'deki Otomatik/USB/Wi-Fi ve istatistik düğmeleri kalktı (katalogdan segment düğmeleri olarak geliyor; seçili olan mavi + kalın).
  - Yan panel (`SettingsSidePanel`): root'un en üstünde tam ekran saydam katman + sağda 460 dp, ~%85 opak, kaydırılabilir panel (başlık "Ayarlar" + "Kapat"). Video yeniden boyutlanmaz.
- **Girdi kapısı:**
  - `syncInputActive` = `SettingsPanelState.inputAllowed(...)`. Açılınca önce `InputCapture.setActive(false)` çalışır → doğal bırakmalar + `RELEASE_ALL(USER)`; sonra pointer capture ve unbuffered dispatch bırakılır, panel gösterilir.
  - Panel açıkken fiziksel klavye olayları `KeyTracker`'a hiç gitmez (`SettingsPanelState.keyWhileOpen`): Esc (BACK olarak gelse de) ve Ctrl+Shift+6 kapatır; tekrarları, UP'ları ve her BACK tüketilir; diğer Ctrl+Shift kısayolları çalışır; geri kalanı Android'e (panelde gezinme). Kalem/dokunma/touchpad/fare olayları capture pasif olduğu için view'lara gider.
  - Kapanış tuşlarının UP'ları kapanıştan sonra tracker'a ulaşır ama DOWN'ları gönderilmediği için gönderilmez (testli). Kapanınca pointer capture hemen yeniden istenir.
  - Videoya dokunma kapanışı ACTION_UP'ta yapılır: jestin tamamı katmanda kalır, yarım jest Mac'e sızmaz.
- **Kapatma yolları:** Esc, Ctrl+Shift+6, video alanına dokunma, Kapat, sistem geri, `onPause` (arka plan), akışın bitmesi (`render`), "Bağlantıyı kes". Log (key=value, docs/LOGGING.md): `ev=settings_panel action=open|close via=shortcut|host|esc|back|tap_outside|close_button|background|stream_end|disconnect`; akış yokken gelen açma isteği `ev=settings_panel action=ignored via=host reason=not_streaming`.
- **SETTINGS_OPEN:** `SessionMachine` yalnız kabul edilmiş oturumda `Action.OpenSettings` üretir → `SessionListener.onSettingsOpen` → `CoalescedPost` (AtomicBoolean: UI kuyruğunda en çok bir bekleyen runnable, çalışırken temizlenir) → UI, akış görünürse açar. HELLO'da bit9 `SETTINGS_PANEL` artık gönderiliyor.
- **Bit hızı:** `Settings.bitrateKbps()` (anahtar `bitrate_kbps`; yalnız 0/15000/30000/60000/100000, başka değer 0 = Otomatik). `SessionController` artık `initialPrefs: StreamPrefs` alıyor ve `setStreamMode` yerine `setStreamPrefs(prefs)` var. Mod ya da bit hızı değişince `STREAM_PREFS(fps, scale, bitrate)` hemen gider (aynı değerse gitmez). Log: `stream_prefs_sent ... bitrate_kbps=N`, her STREAM_CONFIG'te `ev=stream_config_bitrate bitrate_kbps=N wanted_kbps=M`.
- **Bağlantı seçimi:** `TransportSwitch.keepsSession` kabul edilmiş oturumda seçime uyuyorsa bağlantıyı korur (Otomatik her zaman uyar; USB/Wi-Fi yalnız aynı taşıyıcıdaysa). Uymuyorsa eski davranış (stop + applyTransport), panel `stream_end` ile kapanır. Log `ev=transport_select mode=… keep=0|1`.
  - Review düzeltmesi: AUTO dışı her seçim süren AUTO geçişini iptal eder (`SessionController.cancelMigration()` → `SessionMachine.Event.CancelMigration`: aday kapanır, sonuç `ok=0 reason=cancelled`, geç gelen ACCEPTED yok sayılır). İptal geç kalıp aday yine de terfi ederse `onMigrationResult` sonucu seçili moda göre denetler (`TransportSwitch.onMigrated`): uymuyorsa `ev=transport_migrate_rejected` ve seçili modla yeniden bağlanır. Korunan oturumda bekleyen prob/geçiş sonucu gelmeyeceği için `AutoUsbPolicy` NEUTRAL ile serbest bırakılır.
- **"Bağlantıyı kes":** BYE (`controller.stop()`), bağlantı paneli, durum "Bağlantı kesildi. Yeniden bağlanmak için Bağlan'a dokun.". NSD, USB probu ve AUTO tikçisi durur; "Bağlan" (boş adresle) seçili modu yeniden uygular. Bağlantı seçimi ya da yeni `onStart` da bayrağı temizler.
- **Varsayımlar:**
  - Ctrl+Shift+6 evdev scan `7` ile eşlenir (rakam satırı, fiziksel konum; diğer rakam kısayolları gibi).
  - Panel genişliği sabit 460 dp (tablette ~1100+ dp genişlik varsayıldı).
  - Bağlantı panelindeki Otomatik seçeneğinin metni kısaldı ("Otomatik (USB varsa USB, yoksa Wi-Fi)" → "Otomatik").
- **Test edilmeyenler (cihaz gerekli):** gerçek tablette hiçbir şey denenmedi. Görünüm/yerleşim, HarmonyOS'un Ctrl+Shift+6'yı uygulamaya iletip iletmediği, panel açıkken touchpad imleciyle tıklama, kapanınca pointer capture'ın geri gelmesi, host tarafı `SETTINGS_OPEN` (T-106 gerekli) ve host'un bit hızını uygulaması (T-106) doğrulanmadı.
- **Tablette kontrol edilecekler:**
  1. Akış sırasında Ctrl+Shift+6: sağda yarı saydam panel açılıyor, video arkada sürüyor ve boyutu değişmiyor; Mac'te Cmd/Shift takılı kalmıyor (ör. ardından Mac'te bir tuşa basınca kısayol tetiklenmiyor).
  2. Panel açıkken kalem/parmak/touchpad/klavye Mac'e gitmiyor; panel kalemle, parmakla ve touchpad imleciyle kullanılabiliyor, kaydırılabiliyor.
  3. Kapatma: Esc, Ctrl+Shift+6, videoya dokunma, Kapat, sistem geri hareketi; sonra touchpad hemen Mac imlecini sürüyor (pointer capture geri geldi), kalem/klavye normal.
  4. Bit hızı 60 Mbps seç: `adb logcat -s 'MB:*' | grep -E 'stream_prefs_sent|stream_config_bitrate|settings_panel'` → `bitrate_kbps=60000` gidiyor; T-106 olmadan "Uygulanan" host varsayılanını gösterir. Uygulama yeniden açılınca seçim duruyor; bağlantı panelinde de aynı seçim görünüyor.
  5. "Bağlantıyı kes": bağlantı paneline dönüyor ve kendiliğinden yeniden bağlanmıyor; "Bağlan" ile geri bağlanıyor. Wi-Fi'deyken yan panelden "Yalnız Wi-Fi"/"Otomatik" seçmek akışı kesmiyor; "Yalnız USB" (USB yoksa) yeniden bağlanmayı başlatıyor.

### Open questions

- Yok (Codex review'daki iki P2 ve log biçimi düzeltildi).
