---
id: T-245
title: Client — experimental "2800×1840 (deneysel)" game resolution, offered only in Oyun 60
status: todo
phase: 6
owner: android-client-dev
depends_on: []
decisions: [0029, 0030]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/decisions/0030-modes-daily-drawing-game.md
  - backlog/tasks/T-245-client-game-native-2800-option.md
---

## Amaç

Kullanıcı 2026-10-05: Oyun modunda daha yüksek çözünürlük. Ölçüm (NOTES 2026-10-05 ~14:30): Oyun 60'ta 2800×1840 çözme 13,8–14,2 ms (60 fps bütçesinin ~%85'i), SDR akıcı, HDR'de sunum atlaması daha fazla (Wi-Fi'de ölçüldü). Kullanıcı deneysel seçenek istedi.

## Bağlam

- Bugün oyun çözünürlüğü seçenekleri 1848×1214 ve 2240×1472 (0030; prefs `game_resolution`). Yeni seçenek "2800×1840 (deneysel)": STREAM_PREFS `display_*` = 2800×1840 (host 0029 doğrulaması `w ≤ screen_width` ile kabul eder; 1x ekran = noktalar pikseller, oyunlar için).
- **Yalnız Oyun 60'ta** gösterilir/geçerlidir. Oyun 120'ye geçince ya da 120 seçiliyken 2800 seçimi etkin olarak 2240×1472'ye düşer (kayıtlı seçim korunur, 60'a dönünce geri gelir); panelde satır 120'de gri "(yalnız 60 fps)".
- Host değişikliği yok (önce doğrula: 0029 kuralları 2800×1840'ı kabul ediyor mu, `game_display_failed` riski var mı; host kodunu okuyup Handoff'a yaz, gerekiyorsa Açık sorular).
- 0030'a kısa ek (deneysel seçenek, yalnız Oyun 60) — karar dosyası `files:` içinde, metni ajan önerir.

## Kabul kriterleri

- [ ] [JVM] Seçenek listesi fps'e göre; 120'de etkin çözünürlük 2240 düşüşü; kayıtlı seçim korunur; STREAM_PREFS `display_*` doğru.
- [ ] [JVM] Panel satırı etiketi ve gri durumu.
- [ ] `./scripts/check.sh` geçer. APK kurma/adb yok.

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
