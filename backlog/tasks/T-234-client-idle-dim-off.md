---
id: T-234
title: Client — idle dim then screen-off per decision 0031 (panel setting 2/5/10/15/off, first input only wakes, paused in game mode)
status: review
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0031]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/idle/
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/res/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-234-client-idle-dim-off.md
---

## Amaç

Decision 0031'i uygula. Kural ve gerekçe kararda; burada tekrar edilmez.

## Bağlam

- `FLAG_KEEP_SCREEN_ON`: `MainActivity.kt:383`. Ekran kapanınca onStop → release-all + BYE, uyandırma zinciri T-128..T-134 (dokunma).
- Mantığı saf bir sınıfta tut (`idle/IdleDimPolicy` gibi: zaman, girdi olayları, basılı durum, mod, ayar → aşama ve "bu olayı yut" kararı) ve JVM'de test et. MainActivity yalnız bağlar: girdi yolu (InputCapture / trackers) her yerel olayı politikaya bildirir, politika "yut" derse olay Mac'e gitmez.
- Yutma kuralı (0031): kısılmışken gelen ilk hareketin tamamı yutulur; daha önce gönderilmiş bir basışın bırakması asla yutulmaz. Input state never stuck (AGENTS.md).
- Panel: Günlük/Çizim'de "Boşta karart" satırı (2/5/10/15/Kapalı, varsayılan 5), kalıcı prefs. Oyun modunda sayaç durur (satır görünür ama "Oyun modunda kapalı" notu ya da gri, planda seç).
- Kısma parlaklığı: pencere `screenBrightness` (ör. 0.02–0.05; planda seç). Kısma ve geri dönüş anlık olabilir; animasyon gerekmez.
- Log: `ev=idle stage=dim|off|wake reason=… swallowed=<n>` (karakter/tuş içeriği yok).
- T-231 (renk düğmeleri) ve T-229 aynı anda MainActivity'ye dokunabilir: değişikliği küçük ve ayrık tut.

## Kabul kriterleri

- [x] [JVM] Süre dolunca dim, +60 sn off; basılı girdi varken sayaç durur; Oyun modunda aşama yok; Kapalı ayarında aşama yok; ayar değişince sayaç yeniden başlar.
- [x] [JVM] Kısılmışken: dokunma DOWN..tüm UP yutulur; kalem temas..kalkış yutulur; tuş down + up yutulur; kısmadan önce basılmış ve gönderilmiş bir tuşun up'ı yutulmaz (gönderilir).
- [x] [JVM] Wake'ten sonra sayaç sıfırlanır, `FLAG_KEEP_SCREEN_ON` geri gelir (bağlama katmanı için arayüz testi).
- [x] `./scripts/check.sh` geçer; `ev=idle` docs/LOGGING.md'de.
- [ ] [device, orkestratör] 2 dk ayarıyla: kısma, +1 dk sonra ekran kapanması, açınca Mac'in uyanıp bağlanması; ilk dokunuşun Mac'e tıklama olarak gitmemesi.

## Plan

1. **`idle/IdleTimeout.kt`**: `IdleTimeout` enum (2/5/10/15 dk, Kapalı; varsayılan 5) + `IdleTimeoutStore(KeyValueStore)` (anahtar `idle_dim`, `reset()`). `session/Settings.kt` kartta yok: T-191 sıfırlamasında MainActivity `idleStore.reset()` çağırır.
2. **`idle/IdleDimPolicy.kt`** (saf, JVM): aşama `ACTIVE → DIM → OFF`, `IdleWindow` arayüzü (`setDimmed`, `setKeepScreenOn`) ile bağlanır.
   - `tick(now)`: basılı kanal varsa sayaç durur; `timeout` dolunca DIM, DIM'den 60 sn sonra OFF. Kapalı ayarında ya da Oyun modunda aşama yok (DIM/OFF iken geçilirse anında geri döner).
   - `setTimeout` / `setGameMode`: sayaç yeniden başlar. `restart(now)` (onStart): ACTIVE, bayrak ve parlaklık geri.
   - `onInput(now)`: kapıdan geçmeyen yerel olay (panel, bağlantı ekranı, sistem tuşları): etkinlik sayılır, kısılmışsa yutmadan uyandırır.
   - `admit(ch, engaged, pressed, release, now)`: Mac'e gidecek her olay. Kurallar: (a) kanal yutuluyorsa yut, `engaged=false` olunca yutma biter; (b) bırakma olayı ya da gönderilmiş basışın devamı **her zaman geçer**; (c) yeni hareket: bu olay uyandırdıysa ya da başka bir kanal hâlâ yutuluyorsa yutulur (kalem yutulurken avuç, avuç yutulurken kalem tıklamasın); (d) yoksa geçer. Yutulan basışların bırakması da yutulur; yutulmamış basışın bırakması asla.
   - `forgetGestures()`: release-all / oturum sıfırlama (izleyiciler de unutur; sonraki öksüz bırakmaları zaten yok sayıyorlar).
   - Log: `ev=idle stage=dim|off reason=timeout`, uyandırma satırı yutulan hareket bitince tek satır: `ev=idle stage=wake reason=touch|pen|key|pad|mouse|gesture|ui|setting|game|start swallowed=<n> held_ms=<n>`.
3. **`input/IdleGestures.kt`** (saf): kare → (kanal, engaged, pressed, release). Dokunma: kalan parmaklar (UP'ta acting çıkar, CANCEL boş). Kalem: temas = pressed; hover = engaged (yutma kalem menzilden çıkana ya da kalkana kadar sürer, hover sayacı durdurmaz); UP/CANCEL/HOVER_EXIT bırakma ve yutmayı bitirir. Touchpad: parmak ya da düğme. Fare: düğme; hareket/teker tek seferlik. Tuş: (cihaz, tuş kimliği) down/up. Kalem çift dokunma: tek seferlik.
4. **`InputCapture`**: opsiyonel `idleGate`; her `onPen/onTouch/onPad/onMouse/onKey/onGestureKeyDown` girişinde (accepting iken) önce sorulur; yutulan olay izleyicilere ve kalem izi katmanına gitmez (tuş: `consumed=true`, yerel kısayol yok). `forget()` kapıyı da unutturur. Bırakma yolları (`releaseAll`, `onPointerCaptureLost`, cihaz çıkarma) kapıdan geçmez.
5. **MainActivity** (küçük, ayrık blok): politika + `IdleWindow` (`screenBrightness` 0.03 / `BRIGHTNESS_OVERRIDE_NONE`, `FLAG_KEEP_SCREEN_ON` ekle/kaldır); dispatch* sonunda `idle.onInput`; `inputTicker` içinde `idle.tick`; `onStart` → `restart`; mod değişince `setGameMode(streamMode.isGame)`; sıfırlamada varsayılan.
6. **Panel**: Görüntü bölümünün sonunda `idle_dim` "Boşta karart" seçimi (2 dk/5 dk/10 dk/15 dk/Kapalı); Oyun modunda başlıkta " (Oyun modunda kapalı)" işareti, satır görünür kalır.
7. **Testler**: `IdleDimPolicyTest` (zaman/aşama/ayar/oyun/basılı/yutma kuralları/pencere arayüzü), `IdleGestureCaptureTest` (InputCapture üzerinden: kısılmışken dokunma, kalem, tuş tamamen yutulur, Mac'e mesaj gitmez; kısmadan önce gönderilen tuşun UP'ı gider), SettingsCatalogTest güncellemesi. `docs/LOGGING.md`'ye `ev=idle`.

Bağlam dışı: bağlantı ekranı ve ayar panelindeki Android görünümlerine giden ilk dokunuş yutulmaz (yalnız uyandırır ve görünüme de gider); karar yalnız Mac'e giden girdiyi kapsıyor.

## Handoff

- **Commit:** `00e498d` (uygulama), plan `a04fd67`; dal `task/T-234-idle-dim-off`.
- **Dokunulan dosyalar:** `idle/IdleDimPolicy.kt` (yeni: aşamalar, sayaç, yutma kuralları, `IdleWindow`, `IdleChannel`), `idle/IdleTimeout.kt` (yeni: seçenekler + `IdleTimeoutStore`, prefs anahtarı `idle_dim`), `input/IdleGestures.kt` (yeni: kare → kanal), `input/InputCapture.kt` (`idleGate`, her girişte önce sorulur; `forget()` kapıyı da unutturur), `MainActivity.kt` (pencere bağlama, dispatch*, ticker, onStart, mod, panel, sıfırlama), `settings/SettingsCatalog.kt` (`idle_dim` satırı, `SettingsHost.idleTimeout`/`selectIdleTimeout`), testler `idle/IdleDimPolicyTest.kt` (25), `input/IdleGateCaptureTest.kt` (9), `settings/SettingsCatalogTest.kt`, `docs/LOGGING.md`.
- **check.sh:** `ALL OK`. İlk tam koşuda `swift test (host-mac)` bir kez FAIL verdi (host'a dokunulmadı); tek başına yeniden koşuda 814 test geçti, ikinci tam koşu `ALL OK`. Muhtemelen paralel yükte zamanlamaya bağlı bir host testi; ayrıntı kayboldu.
- **Seçimler / varsayımlar:**
  - Kısma parlaklığı pencere `screenBrightness = 0.03`; geri dönüş `BRIGHTNESS_OVERRIDE_NONE`. Sistem parlaklığına dokunulmaz.
  - Panel satırı "Boşta karart" Görüntü bölümünün sonunda (yan panelde "Uygulanan"dan sonra). Oyun modunda satır görünür, başlıkta " (Oyun modunda kapalı)" yazar.
  - Sayaç uygulama ön plandayken her ekranda çalışır (bağlantı ekranı dahil). Yutma yalnız Mac'e giden girdide: bağlantı ekranı ya da ayar panelindeki Android görünümlerine giden ilk dokunuş yalnız uyandırmaz, görünüme de gider.
  - Kalem: yutma ilk kalem olayından (hover dahil) kalem kalkana kadar sürer. Android dokunmadan hemen önce HOVER_EXIT gönderdiği için hover yutması 1 sn sessizlikte biter (kalem menzilden çıktı). Hover sayacı durdurmaz, temas durdurur.
  - Çapraz kanal: yalnız kalem yutulurken başlayan dokunmatik hareketi de yutulur (TouchTracker'ın avuç kapısı yutulan kalemi görmez). Avuç uyandırdıysa kalem çizgileri normal gider. Başka kanallar bağımsızdır: tuş A ile uyandırıp B'ye basmak B'yi gönderir.
  - Uyandırma log satırı uyandıran hareket bitince yazılır (`swallowed`, `held_ms` ile). Ek satır: `stage=config` (ayar/oyun değişimi).
  - `session/Settings.kt` kartta yok: anahtar `IdleTimeoutStore`'da tutuluyor, T-191 sıfırlamasında MainActivity ayrıca `idleStore.reset()` çağırıyor (`settings_reset keys=` sayısına dahil değil).
- **Girdi durumu:** release yolları (`releaseAll`, `onPointerCaptureLost`, `onDeviceRemoved`) kapıdan geçmez. Kapı yalnız basışı yuttuğu kanalın bırakmasını yutar; bırakma olayları ve gönderilmiş basışın devamı her zaman geçer. Bir şey basılıyken sayaç durduğu için basılı tuş varken kısma olmaz. Kapının görmediği basışın bırakması da kısılmışken gider (`IdleGateCaptureTest.aKeyPressedBeforeTheDimIsReleasedOnTheMac`).
- **Test edilmedi (tablet gerekli):** gerçek parlaklık görünümü, bayrak kalkınca ekranın kapanma süresi, HOVER_EXIT→DOWN sırası ve 1 sn bekleme süresinin yeterliliği, ekran açılınca uyanma zinciri.
- **Tablette kontrol (orkestratör):**
  1. Yan panelde "Boşta karart: 2 dk" seç (Günlük ya da Çizim). Dokunmadan 2 dk bekle: ekran çok koyu ama görünür olmalı, video ve ses sürmeli. Log: `MB/input ev=idle stage=dim`.
  2. 1 dk daha bekle: `ev=idle stage=off`, ardından tabletin kendi zaman aşımıyla ekran kapanmalı, sonra `activity_stop` ve release-all/BYE gelmeli. Açınca Mac uyanıp bağlanmalı, ekran tam parlaklıkta olmalı (`stage=wake reason=start`).
  3. Kısılmışken parmakla bir simgeye dokun: ekran aydınlanmalı, Mac'te tıklama olmamalı (`stage=wake reason=touch swallowed=<n>`). İkinci dokunuş tıklamalı.
  4. Kısılmışken kalemle dokun (tap): Mac'te tıklama/çizgi olmamalı; kalemi kaldırınca sonraki çizgi çizmeli. Kalemi yaklaştırıp uzaklaştırınca 1 sn sonra parmak dokunuşları normal olmalı.
  5. Oyun moduna geç: 2 dk+ sonra kısma olmamalı, panelde "(Oyun modunda kapalı)" görünmeli. "Kapalı" seçeneğinde de kısma olmamalı.

## Open questions

- `Settings.USER_KEYS`'e `idle_dim` eklemek daha temiz olur (kart dışı dosya); şimdilik MainActivity sıfırlamada ayrıca siliyor.
- Bağlantı ekranı / ayar paneli görünümlerine giden ilk dokunuşu yutmak istenirse ayrı iş (karar yalnız Mac'e giden girdiyi kapsıyor).
