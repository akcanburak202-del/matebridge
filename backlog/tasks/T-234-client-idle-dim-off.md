---
id: T-234
title: Client — idle dim then screen-off per decision 0031 (panel setting 2/5/10/15/off, first input only wakes, paused in game mode)
status: todo
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

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
