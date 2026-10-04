---
id: T-234
title: Client — idle dim then screen-off per decision 0031 (panel setting 2/5/10/15/off, first input only wakes, paused in game mode)
status: in-progress
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

- [ ] [JVM] Süre dolunca dim, +60 sn off; basılı girdi varken sayaç durur; Oyun modunda aşama yok; Kapalı ayarında aşama yok; ayar değişince sayaç yeniden başlar.
- [ ] [JVM] Kısılmışken: dokunma DOWN..tüm UP yutulur; kalem temas..kalkış yutulur; tuş down + up yutulur; kısmadan önce basılmış ve gönderilmiş bir tuşun up'ı yutulmaz (gönderilir).
- [ ] [JVM] Wake'ten sonra sayaç sıfırlanır, `FLAG_KEEP_SCREEN_ON` geri gelir (bağlama katmanı için arayüz testi).
- [ ] `./scripts/check.sh` geçer; `ev=idle` docs/LOGGING.md'de.
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

_(Ajan bitirince doldurur.)_
