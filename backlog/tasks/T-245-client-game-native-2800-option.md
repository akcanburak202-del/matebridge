---
id: T-245
title: Client — experimental "2800×1840 (deneysel)" game resolution, offered only in Oyun 60
status: in_progress
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

1. `stream/GameResolution.kt`: yeni giriş `R2800("2800x1840", 2800, 1840)`, `experimental = true`. Saf yardımcılar:
   `availableAt(fps)` (deneysel olan yalnız 60'ta), `effectiveAt(fps)` (120'de `R2240`'a düşer), `panelLabel(gameFps: Int?)`
   ("2800×1840 (deneysel)" / 120'de "2800×1840 (yalnız 60 fps)" / Oyun dışı, Oyun fps'i bilinmezken "2800×1840 (deneysel, yalnız 60 fps)"),
   `panelSelected(stored, gameFps)` (Oyun 120'de etkin 2240 seçili görünür). `parse("2800x1840")` artık R2800.
2. `stream/GameMode.kt`: `display(mode)` kayıtlı seçimi Oyun'un kare hızına göre etkin boyuta çevirir (STREAM_PREFS, toast,
   profile log hepsi buradan okur; kayıtlı seçim değişmez). `selectGameResolution` etkin boyut değişmediyse null döner.
   60↔120 geçişinde `selectFrameRate` zaten tam STREAM_PREFS gönderir → `fps` ve `display_*` tek mesajda değişir.
3. `settings/SettingsCatalog.kt`: `SettingItem.Option`'a seçenek başına `enabled` (varsayılan true); oyun çözünürlüğü
   satırında etiket/gri durum/seçili id yukarıdaki saf fonksiyonlardan; gri seçeneğe dokunma hiçbir şey yapmaz.
   `settings/SettingsViews.kt`: buton `isEnabled`/alpha = satır && seçenek.
4. MainActivity'ye dokunulmaz (kapsam dışı): panel Oyun dışında Oyun'un kare hızını bilmez → orada etiket iki koşulu birden yazar.
5. JVM testleri: GameResolutionTest, SettingsCatalogTest (+ gerekiyorsa StreamModeTest). 0030'a kısa ek.
6. Host doğrulaması (kod okuma): `GameDisplayPolicy.accepts` 2800×1840'ı kabul eder; Handoff'a yazılır.

## Handoff

_(Ajan bitirince doldurur.)_
