---
id: T-250
title: Client — allow 2800×1840 game resolution in Oyun 120 too (drop the 60-only rule)
status: review
phase: 6
owner: android-client-dev
depends_on: [T-245, T-249]
decisions: [0029, 0030]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-250-client-2800-at-oyun-120.md
---

## Amaç

Karar 0030 "Ek (2026-10-05, T-250)": çözücü 2800×1840'ı 120 fps'te taşıyor (T-248/T-249). T-245'in "yalnız Oyun 60" kuralı kalkar.

## Bağlam

- `stream/GameResolution.kt`: `R2800` `experimental` + `EXPERIMENTAL_FPS`/`EXPERIMENTAL_FALLBACK`, `availableAt`/`effectiveAt`, `panelLabel` (gri "(yalnız 60 fps)" metinleri); `stream/GameMode.kt` (~172, ~239 civarı: 120'de 2240'a düşme, "stored but sends nothing"); `settings/SettingsCatalog.kt` (~181, ~301) ve `settings/SettingsViews.kt` (~77 gri seçenek).
- Yeni davranış: 2800×1840 her Oyun kare hızında geçerli ve gönderilir; panelde her durumda "2800×1840 (deneysel)" (etiket kalır, cihaz doğrulaması sonra kaldırır). Geri düşme ve gri düğme yolu kalkar; kullanılmayan yardımcılar silinir (genel gri-seçenek altyapısı başka yerde kullanılıyorsa kalsın).
- 60↔120 geçişinde artık `display_*` değişmez (yalnız `fps`); ilgili testler buna göre güncellenir.
- Varsayılan 1848×1214 değişmez. Tel biçimi ve host değişmez.

## Kabul kriterleri

- [ ] Oyun 120'de 2800×1840 seçilebilir ve STREAM_PREFS `display_*` = 2800×1840 gider; Oyun 60 ile aynı.
- [ ] Panel metni her durumda "2800×1840 (deneysel)"; "(yalnız 60 fps)" metni yok.
- [ ] Birim testleri güncel; `./scripts/check.sh` geçer.

## Plan

`GameResolution`: `availableAt/effectiveAt/EXPERIMENTAL_FPS/FALLBACK/ONLY_60_TEXT/panelEnabled/panelSelected` silinir, `panelLabel` parametresiz özellik ("(deneysel)" etiketi kalır). `GameModeSettings.display` saklanan boyutu doğrudan verir. Katalogda `gameFps` ve `Option.enabled` (başka yerde kullanılmıyordu) ile SettingsViews'taki gri-seçenek yolu silinir. Testler güncellenir.

## Handoff

- Commit: son commit `task/T-250-2800-oyun-120` dalında (`T-250: ...`).
- Dosyalar: `stream/GameResolution.kt`, `stream/GameMode.kt`, `settings/SettingsCatalog.kt`, `settings/SettingsViews.kt`, `GameResolutionTest.kt`, `SettingsCatalogTest.kt`, bu kart.
- Varsayım: `SettingItem.Option.enabled` yalnız T-245 için vardı, kaldırıldı (satır düzeyindeki `Choice.enabled` duruyor).
- check.sh: ALL OK.
- Tablette: Oyun 120'de panelde "2800×1840 (deneysel)" seçilebilir (gri değil, "yalnız 60 fps" yok); seçince STREAM_PREFS display=2800x1840, fps=120 gider; 60↔120 geçişinde çözünürlük değişmez. 2800×1840 @120'de akış, gecikme ve kare düşmesi gözlenmeli.

## Open questions
