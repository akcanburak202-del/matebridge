---
id: T-223
title: Client — three modes (Günlük / Çizim / Oyun), per-mode frame rate setting, 2240×1472 game resolution
status: review
phase: 6
owner: android-client-dev
depends_on: [T-215, T-222]
decisions: [0030, 0029, 0014]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/StreamMode.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameMode.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/GameResolution.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsCatalog.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsViews.kt  # eklendi (orkestratör onayı): "Kare hızı" satırı Çizim'de gizlenir
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/InputCaptureTest.kt  # eklendi (orkestratör onayı): Çizim geçişinde takılı girdi testleri
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/FingerPolicy.kt  # eklendi (Codex P2-2, orkestratör onayı)
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/TouchTracker.kt  # eklendi (aynı)
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/InputCapture.kt  # eklendi (aynı)
  - client-android/app/src/test/kotlin/dev/matebridge/client/input/FingerPolicyTest.kt  # eklendi (aynı)
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/res/values/strings.xml
  - client-android/app/src/test/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/test/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/session/
  - docs/KNOBS.md
  - docs/LOGGING.md
  - backlog/tasks/T-223-client-modes-daily-drawing-game.md
---

## Amaç

Karar 0030'u uygulamak: beş mod (Netlik, Akıcı, Performans, Oyun 120, Oyun 60) yerine üç mod — **Günlük**, **Çizim**, **Oyun** — ve ayrı bir "Kare hızı: 60 / 120" ayarı (Günlük ve Oyun'da, mod başına hatırlanır; Çizim hep 120). Oyun çözünürlüğü listesine 2240×1472 eklenir. Performans kalkar.

## Bağlam

- `StreamMode` enum'u bugün fps + ölçek tablosu; `GameModeSettings` (0014 §3 geçici katman: bit hızı 60 Mbps, düşük gecikmeli ses, kalem izi/noktası kapalı) `isGame` ile bağlanıyor.
- Çizim katmanı aynı mekanizmayla (geçici, kayıtlı ayarların üstüne biner, moddan çıkınca geri döner): parmakla dokunma kapalı (`finger_off`), Otomatik bit hızıysa 60 Mbps.
- Kare hızı: Günlük varsayılan 120, Oyun varsayılan 60; ayar anahtarları ör. `fps_daily`, `fps_game` (T-191 sıfırlaması `USER_KEYS` ile kapsar).
- Kayıtlı `stream_mode` geçişi (0030 §5): `clarity`→Günlük 60, `smooth`→Günlük 120, `performance`→Günlük 120, `game`→Oyun 120, `game60`→Oyun 60 (eski `performance144` → Günlük 120).
- STREAM_PREFS: Günlük/Çizim `scale_permille = 1000`, `display_* = 0`; Oyun `scale_permille = 1000`, `display_* = oyun çözünürlüğü`. Tel biçimi ve host değişmez. Oyun + eski host: 0029 geri düşüşü (doğal ekran) — `scale 1000` ile tam boyut; kabul.
- Ctrl+Shift+7 döngüsü üç mod; panel ve toast metinleri (ör. "Oyun: 60 fps, 1848×1214", "Günlük: 120 fps", "Çizim: 120 fps").
- `ev=profile mode=` yeni kimlikler (`daily|drawing|game`) ve `fps=`; LOGGING/KNOBS güncellenir. Performans'a bağlı dev yolu kalırsa KNOBS'ta belirtilir.

## Kapsam dışı

- Host, protokol, pacer, 0029 ekran kurulumu.

## Kabul kriterleri

- [ ] [JVM] Üç mod; Günlük/Oyun kare hızı ayarı mod başına hatırlanır (Günlük 120 / Oyun 60 varsayılan); Çizim her zaman 120.
- [ ] [JVM] Kayıtlı eski mod kimlikleri 0030 §5'e göre eşlenir; bilinmeyen değer Günlük 120.
- [ ] [JVM] Çizim katmanı: girince parmak kapalı + (Otomatik ise) 60 Mbps; çıkınca kayıtlı değerler aynen geri gelir (0014 §3 kuralları).
- [ ] [JVM] STREAM_PREFS baytları: Günlük 120 = (120, 1000, auto, 0×0); Oyun 60 1848×1214 = (60, 1000, 60000, 1848, 1214); 2240×1472 geçerli seçenek.
- [ ] [JVM] Ctrl+Shift+7 üç mod arasında döner; ayar sıfırlama yeni anahtarları kapsar.
- [ ] [device] Her mod girişinde beklenen `ev=profile`; Günlük 60↔120 değişimi bir kez ekran yeniden kurulumu; Çizim'de avuç teması tıklamıyor, kalem çiziyor; Oyun'da 2240×1472 seçilebiliyor ve oyunda görünüyor.

## Plan

1. `StreamMode` -> üç değer (`DAILY daily`, `DRAWING drawing`, `GAME game`, bu sırayla; Ctrl+Shift+7 döngüsü). Kare hızı enum'dan çıkar: `defaultFps` (Günlük 120, Çizim 120, Oyun 60), `hasFpsSetting` (Çizim hariç), `resolveFps` (Çizim hep 120, geçersiz değer varsayılan), `toPrefs(fps, bitrate)` hep `scale_permille = 1000`. Eski kimlikler (`clarity|smooth|performance|performance144|game60`) `LegacyModes` ile 0030 §5'e göre eşlenir; bilinmeyen = Günlük.
2. `Settings`: `fps_daily` / `fps_game` anahtarları (`modeFps(mode)`, `setModeFps`), `USER_KEYS`'e eklenir (T-191 sıfırlaması kapsar). Tek seferlik geçiş `migrateModesOnce()` (bayrak `modes_migrated`, sıfırlamada korunur, T-096 gibi): eski `stream_mode` yeni kimliğe ve `fps_*` değerine yazılır (ör. `game` -> Oyun 120, `game60` -> Oyun 60). Getter eski kimlikleri de tolere eder.
3. `GameModeSettings` (isim korunur, "mod katmanı" olur): `Values`'a `fingerOff` eklenir; katman moda göre kurulur: Oyun = 0014 §3 (60 Mbps/ses/kalem), Çizim = parmak kapalı + Otomatik ise 60 Mbps (ses ve kalem kayıtlı kalır). Oyun<->Çizim geçişi katmanı baştan kurar (ENTER). `onModeChanged` artık `Transition(change, mode)` döner; `prefs(mode)` kare hızını `Settings.modeFps`'ten alır; `selectFrameRate`. Log: `ev=mode_layer mode= action= overrides= ...`.
4. `SettingsCatalog`/`SettingsHost`: mod listesi üç düğme; yeni "Kare hızı" (60/120) seçimi (`frameRate`, `selectFrameRate`), Çizim'de başlığı "(Çizim: hep 120)" olur ve seçim etkisizdir (gizleme `SettingsViews.kt` ister, kart dışı: Açık sorular). `gameDefaultsActive` -> `modeLayer: StreamMode?`; işaretler ayar bazında ("(oyun modu)" / "(çizim modu)"; parmak kapalı Çizim'de işaretlenir). Oyun çözünürlüğü listesine 2240×1472.
5. `MainActivity`: katman parmak durumunu da uygular (`capture.setFingersDisabled` ancak `gameSettings.fingerOff`'tan), açılış/sıfırlama/mod değişimi, `selectFrameRate`, `migrateModesOnce()` en başta, profil `mode=` yeni kimlik, toast metinleri.
6. JVM testleri: StreamModeTest, GameModeTest (katman), GameResolutionTest, SettingsCatalogTest, SettingsResetTest, BitrateSettingTest/SessionMachineTest uyarlaması, yeni geçiş testleri. Sonra docs/KNOBS.md ve docs/LOGGING.md.

## Handoff

- **Commit:** `b05dc6c` (dal `task/T-223-client-modes-daily-drawing-game`; plan `781f6d8`). `./scripts/check.sh`: ALL OK.
- **Dokunulan dosyalar:** `stream/StreamMode.kt` (üç mod, `LegacyModes`), `stream/GameMode.kt` (`GameModeSettings` mod katmanı: Oyun + Çizim, `Transition`, `selectFrameRate`), `stream/GameResolution.kt` (+2240×1472), `session/Settings.kt` (`fps_daily`/`fps_game`, `migrateModesOnce`), `settings/SettingsCatalog.kt` ("Kare hızı" seçimi, `modeLayer`, ayar bazlı işaretler), `MainActivity.kt`, testler (`stream/`, `settings/`, `session/`: StreamModeTest, GameModeTest, GameResolutionTest, SettingsCatalogTest, SettingsResetTest, BitrateSettingTest, SessionMachineTest), `docs/KNOBS.md`, `docs/LOGGING.md`. `strings.xml`'e gerek olmadı (metinler kodda, mevcut desen).
- **Varsayımlar:**
  - Eski kimlikler tek seferlik `Settings.migrateModesOnce()` ile (bayrak `modes_migrated`, "Varsayılanlara dön" bunu silmez) yeni mod + `fps_*` değerine yazılır; `game` yeni Oyun kimliğiyle aynı olduğu için bayrak gerekti (yeni Oyun 60 seçimi eski Oyun 120 sanılmasın). Getter eski kimlikleri de Günlük/Oyun'a çevirir.
  - Katman Oyun ↔ Çizim geçişinde baştan kurulur (`ENTER`); Günlük'e dönüş `EXIT`. Çizim katmanı yalnız parmak ve (Otomatik ise) bit hızını ezer; ses ve kalem izi/noktası kayıtlı kalır. Oyun katmanı parmak anahtarına dokunmaz.
  - Log olayı `ev=game_mode` yerine `ev=mode_layer mode= action= overrides= ... fingers=all|gestures|off` (eski olay LOGGING'de hiç belgelenmemişti); yeni `ev=modes_migrated`. `ev=profile` `mode=daily|drawing|game`, `fps=` zaten STREAM_CONFIG değeri, `scale_permille` hep 1000. `ev=stats stream_mode=` yeni kimlikler.
  - Toast: "Günlük: 120 fps", "Çizim: 120 fps", "Oyun: 60 fps, 1848×1214". Panelde mod düğmeleri yalın etiket ("Günlük", "Çizim", "Oyun"); "Kare hızı (Günlük|Oyun)" başlığı hangi modun hızını değiştirdiğini gösterir. Katman işaretleri: "(oyun modu)" / "(çizim modu)", ayar bazlı (parmak kapalı yalnız Çizim'de işaretlenir).
  - `protocol/fixtures/stream_prefs_game_display` eski Oyun 120'nin (120, 660) baytları; fixture'a dokunulmadı, testte yalnız bit hızı + `display_*` kuyruğu karşılaştırılıyor, fps/ölçek ayrıca doğrulanıyor.
- **Test edilmeyenler / cihazda doğrulananlar:** Hepsi JVM'de test edildi (üç mod, mod başına fps, eski kimlik geçişi, katman giriş/çıkış, STREAM_PREFS baytları, 2240×1472, Ctrl+Shift+7 döngüsü, sıfırlama anahtarları). Cihazda bakılacak:
  1. Ctrl+Shift+7 üç mod arasında döner; her girişte `ev=mode_layer` ve `ev=profile mode=` beklenen kimlikte (Günlük: `fps=120`, Çizim: `fps=120` + `fingers=gestures`, Oyun: `fps=60` + `display=1848x1214`).
  2. Günlük'te Kare hızı 60 ↔ 120: bir kez ekran yeniden kurulumu; Oyun'a geçince kendi hızını (varsayılan 60) hatırlıyor, Günlük'e dönünce Günlük'ünü.
  3. Çizim'de avuç teması / tek parmak tıklamıyor ve sürüklemiyor, kalem çiziyor; iki parmakla sıkıştırma ve kaydırma (tuval yakınlaştırma/kaydırma) çalışıyor; Çizim'den Günlük'e dönünce tek parmak eski haline (kayıtlı değer) dönüyor. Çizim açıkken "Parmak dokunmasını tamamen kapat"ı açmak her şeyi kapatır, yalnız katmanda kalır (kayda yazılmaz).
  4. Oyun'da Oyun çözünürlüğü listesinde 2240×1472 seçilebiliyor ve oyunda görünüyor (`display_applied=1`).
  5. Eski sürümden güncelleme: kayıtlı `game`/`game60`/`clarity`/`smooth` ilk açılışta doğru mod + hıza dönüşüyor (`ev=modes_migrated`).
- **Takip (orkestratör onayı):**
  - "Kare hızı" satırı Çizim'de gizlenir: `SettingItem.Choice.hidden` (katalogda `!streamMode.hasFpsSetting`), `SettingsViews` satırı `GONE` yapar (her yenilemede yeniden okur). `SettingsViews.kt` ve `InputCaptureTest.kt` `files:` listesine eklendi. JVM testi: `SettingsCatalogTest.frameRateChoiceIsPerModeAndFixedInDrawing` (Çizim'de hidden, Günlük/Oyun'da değil, başka satır hiç gizli değil). Gerçek görünürlük (View) cihazda bakılır.
  - Takılı girdi kontrolü (dokunma yolu okundu): kod değişikliği gerekmedi. `InputCapture.setFingersDisabled(true)` → `TouchTracker.setDisabled(true)` → `forceRelease`: sürükleme/basılı parmak için `PointerAbs buttons=0`, iki parmak kaydırma için `Scroll.CANCELLED`, sıkıştırma için `Pinch.CANCELLED` aynı çağrıda gönderilir (gate: sahibi dokunma olduğundan geçer), sonra tracker sıfırlanır. Parmak hâlâ camdayken gelen sonraki MOVE/UP'lar IDLE'da yok sayılır (sahte tıklama yok). Çizim'den çıkış (`setDisabled(false)`) bir şey göndermez; çünkü kapalıyken başlayan dokunuş hiç basılmadı, borç yok, ve o dokunuşun MOVE/UP'ı yok sayılır; yeni DOWN normal çalışır. Mod katmanı `applyGameLayer` içinde bu yolu çağırır (panel anahtarı ve Ctrl+Shift+7 aynı yol). Eklenen testler (`InputCaptureTest`): sürükleme sırasında Çizim'e giriş (host'ta düğme kalkar, sonrası yok sayılır), kaydırma sırasında giriş (`Scroll.CANCELLED`), Çizim'den çıkış sırasında parmak hâlâ aşağıdayken (sahte basış yok, yeni dokunuş çalışır). Mevcut `TouchTrackerTest`/`PinchTest` aynı geçişi tracker düzeyinde zaten kapsıyordu.
- **Codex incelemesi (2 × P2), düzeltildi:**
  - **P2-1, katmanın ezmediği ayar geçici olmasın:** `GameModeSettings` ayar yazıcıları (`setBitrateKbps/AudioOut/PenTrail/PenDot/FingerOff`) artık yalnız ayar o katmanın `overridesOf(mode)` listesindeyse katmana yazar; değilse normal kaydeder ve katmanın kopyası da güncellenir. Oyun'da parmak anahtarı, Çizim'de ses/kalem izi/noktası artık kalıcı. Bit hızı iki katmanda da geçici kalır. Testler (`GameModeTest`): `fingerSwitchChangedInGameIsStoredAndSurvivesTheModeChange` (mod değişimi + yeniden başlatma), `audioAndPenOverlayChangedInDrawingAreStoredAndSurviveTheModeChange`, `bitrateIsTemporaryInBothLayers`, iki katmanın ezdiği ayarların yalnız katmana yazıldığı testler.
  - **P2-2, Çizim sıkıştırmayı öldürmesin:** yeni `FingerPolicy { ALL, GESTURES_ONLY, OFF }` (`input/FingerPolicy.kt`). `TouchTracker.setPolicy`/`InputCapture.setFingerPolicy`; `setDisabled`/`setFingersDisabled` OFF/ALL olarak çalışmaya devam eder (kullanıcının "tamamen kapat"ı eskisi gibi her şeyi kapatır). `GESTURES_ONLY`: tek parmak hiçbir şey göndermez (`pressNow` sessiz, parmak PENDING'de izlenir; ikinci parmak gelince iki parmak sıkıştırma/kaydırma normal başlar). Çizim katmanı kayıtlı değer `OFF` değilse `GESTURES_ONLY` kurar (kayıtlı "tamamen kapat" Çizim'de de her şeyi kapalı tutar). Geçiş kuralları: `ALL→GESTURES_ONLY` iken basılı tek parmak sürüklemesine tek bir düğme-kalktı gönderilir (parmak sessiz izlenir); **açık sıkıştırma/kaydırma iptal edilmez**, olağan ENDED ile biter (seçilen basit yol); `→OFF` hepsini iptal eder/bırakır; `GESTURES_ONLY→ALL` iken sessiz bekleyen parmak lockout ile unutulur (yoksa tick'te basışa dönerdi). Sessiz parmağın kayıp UP'ı için `PRESS_STALE_MS` sonrası unutulur. Log alanı `finger_off=` → `fingers=all|gestures|off`. Testler: `FingerPolicyTest` (17: tek dokunuş/sürükleme sessiz, kaydırma ve sıkıştırma geçer, sürüklemenin ortasında giriş tek düğme-kalktı, sıkıştırma/kaydırma geçişte iptal edilmez, OFF hepsini iptal eder, çıkışta sahte basış yok, capture üzerinden host görünümü) ve `GameModeTest` katman değerleri.
- **Codex --high yeniden incelemesi (P2), düzeltildi:** sessiz parmağın bayatlık koruması `downMs`'ten sayıyordu; MOVE onu yenilemediği için 10 sn hareket eden tek parmak unutuluyor, ikinci parmak yeni tek parmak sayılıp sıkıştırma/kaydırma gitmiyordu. Artık koruma teması son olayından sayar (`pressEventMs`: DOWN, her PENDING MOVE ve POINTER→PENDING geçişinde yenilenir). Varsayılan politikada (ALL) anlam değişmedi: ALL'da PENDING en çok 40 ms sürer ve `pressNow` `pressEventMs`'i zaten kendisi yazar; basılı parmağın `PRESS_STALE_MS` kuralı (son olaydan sayar) aynen kaldı ve bunu bir test sabitliyor. Yani aynı "son olaya göre" kuralı her iki durumda da doğru, yalnız sessiz parmak için eksikti. Testler (`FingerPolicyTest`, 21): hareket eden sessiz parmak > `PRESS_STALE_MS` sonra ikinci parmakla sıkıştırma geçer, aynısı kaydırma için, son olaydan sonra susan parmak yine unutulur, ALL'da basılı parmak kuralı değişmedi.
- **Codex --high 3. inceleme (P2), kökten düzeltildi:** sessiz temas zaman aşımı IDLE'a düşüp lockout bırakmıyordu (Çizim'de 10 sn duran parmak → Oyun'a geçiş → ikinci parmak → 40 ms sonra istenmeyen LEFT). Kök çözüm `TouchTracker.down`: tracker hiçbir temas sahiplenmezken (IDLE) gelen yeni DOWN karesinde başka bir parmak zaten aşağıdaysa (`f.fingers` içinde `actingId` dışında parmak), yeni temas ilk parmak sayılmaz: basış da iki parmak hareketi de başlamaz, tüm parmaklar kalkana kadar lockout (mevcut lockout temizleme kuralı). İki parmak hareketi doğal olarak çıkmadı, lockout seçildi. Zaman aşımı, politika değişimi, reddedilen/bırakılan parmak yolları aynı kuralla kapsanır; zaman aşımı kodunda ayrıca lockout yok (setPolicy'nin PENDING-only lockout'u kaldı: o durumda tracker IDLE değil ve parmak sahipli). **Dikkat, mevcut bir testin beklentisi değişti:** `InputHardeningTest.aSecondFingerLandingWhileTheFirstIsStaleStartsASinglePressNotAScroll` (releaseAll+resume sonrası parmak 1 hâlâ camdayken ikinci parmak "taze basış" sayılıyordu) artık `...StartsNeitherAScrollNorAPress`: kaydırma yok (eskisi gibi), basış da yok; tüm parmaklar kalkınca yeni dokunuş basar. Gerekçe aynı kural ("camda kalan parmak yüzünden bir sonraki dokunuş sol tıklama olmasın", `TouchTracker` belgesi); orkestratör farklı isterse bu testi ve `down`daki uzlaştırmayı birlikte yeniden değerlendirin. Yeni testler (`FingerPolicyTest`, 24): zaman aşımı → politika değişimi → ikinci parmak → LEFT yok ve tüm parmaklar kalkınca taze dokunuş basar; ALL'da basılı parmak bayatlayıp bırakıldıktan sonra ikinci parmak → LEFT yok; tek başına ilk parmak normal basar.
- **Açık sorular:**
  - `SessionController.kt`, `SessionMachine.kt`, `DevKnobs.kt` `StreamMode.DEFAULT.toPrefs()` ile derleniyor (Günlük 120 → aynı baytlar), dokunulmadı.
  - Çizim katmanında ses/kalem ezilmiyor (karar 0030 yalnız parmak + bit hızı diyor); farklı isteniyorsa `GameModeSettings.defaults` tek yerden değişir.
