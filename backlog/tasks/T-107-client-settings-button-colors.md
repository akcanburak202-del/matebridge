---
id: T-107
title: Tablet — ayar panelinde seçili olmayan seçenekler beyaz kutu, yazı görünmüyor
status: review
phase: 4
owner: android-client-dev
depends_on: [T-105]
decisions: [0013]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/test/
  - backlog/tasks/T-107-client-settings-button-colors.md
---

## Amaç

Kullanıcı bulgusu (2026-10-01, cihazda): yan panelde seçili olmayan seçenek düğmeleri beyaz kutu olarak görünüyor ve yazıları okunmuyor. Seçilince (mavi, kalın) yazı görünüyor.

Teşhis: `SettingsViews.button()` sistem düğme arka planını/tint'ini (HarmonyOS'ta açık renk) kullanıyor, metin rengi beyaz kalıyor. Seçili olmayanlarda `baseTint` geri yükleniyor.

## Kabul kriterleri

- [x] Paneldeki bütün düğmelerin (seçenek, aç/kapa, eylem, −/+) arka plan ve metin rengi açıkça verilir; sistem temasına bırakılmaz.
  - Seçili olmayan: koyu gri zemin (örn. `#3A3A42`), beyaz metin.
  - Seçili: mavi (`SELECTED_COLOR`), beyaz, kalın.
  - Basılı durumda görünür bir geri bildirim olur.
- [x] İki panel de aynı stili kullanır (bağlantı paneli ve yan panel; ikisi de `SettingsViews`).
- [x] Bağlantı panelinin arka planı açık renkse kontrast yine yeterlidir; gerekirse panel zemini de koyu yapılır.
- [x] `./scripts/check.sh` geçiyor. Görsel kontrol orkestratörde, cihazda.

## Plan

1. `settings/SettingsButtonPalette.kt` (saf Kotlin): normal `#3A3A42`, basılı `#55555F`, seçili `SELECTED_COLOR` `#2E7DFF`, seçili+basılı `#1F5FCC`, metin beyaz; `colorFor(selected, pressed)` + JVM testi.
2. `SettingsViews.button()` ve yan paneldeki "Kapat": `StateListDrawable` (pressed/selected/default, yuvarlak köşe) arka plan, `backgroundTintList = null`, beyaz metin, `stateListAnimator = null`. Seçim `isSelected` + kalın ile; `baseTint` kaldırılır.
3. Bağlantı paneli zemini zaten `#000000` (activity_main.xml); kontrast yeterli, layout'a dokunulmaz.

## Handoff

- Commit: `6128c1c` (plan: `5701b4c`), branch `task/T-107-client-settings-button-colors`, base `e293477`.
- Dosyalar:
  - `client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsButtonPalette.kt` (yeni, saf Kotlin renk tablosu)
  - `client-android/app/src/main/kotlin/dev/matebridge/client/settings/SettingsViews.kt` (`styleSettingsButton()`; `baseTint`/`SELECTED_COLOR` kaldırıldı)
  - `client-android/app/src/test/kotlin/dev/matebridge/client/settings/SettingsButtonPaletteTest.kt` (4 test: kart renkleri, basılı ≠ duran, beyaz metin kontrastı ≥3:1, durum sırası)
- Ne yapıldı: paneldeki her düğme (seçenek, aç/kapa, eylem, −/+ ve yan paneldeki "Kapat") `StateListDrawable` arka plan alır (8dp yuvarlak köşe): normal `#3A3A42`, basılı `#5A5A66`, seçili `#2E7DFF`, seçili+basılı `#1F5FCC`; metin her zaman beyaz; `backgroundTintList = null`, `stateListAnimator = null` (tema gölgesi yok). Seçim `isSelected` + kalın yazı ile; renk sistem temasına bırakılmıyor. Min yükseklik 44dp, padding 14/8dp.
- Varsayım: bağlantı paneli zemini `activity_main.xml`'de zaten `#000000`; kontrast yeterli, layout'a dokunulmadı.
- `./scripts/check.sh`: ALL OK.
- Test edilmedi (cihaz): görsel görünüm.
- Tablette kontrol:
  1. Bağlantı ekranındaki ayarlar: seçili olmayan seçenekler koyu gri zemin + okunur beyaz yazı; seçili olan mavi + kalın.
  2. Yayın sırasında yan panel: aynı stil; "Kapat" düğmesi de koyu gri/beyaz.
  3. Bir düğmeye basılı tutunca renk belirgin değişiyor (gri→açık gri, mavi→koyu mavi).
  4. Aç/kapa, eylem ve −/+ düğmeleri de koyu gri/beyaz; seçim değişince eski seçili düğme griye dönüyor.
  5. Düğme yüksekliği/dokunma alanı makul (44dp), yatay kaydırmalı seçenek satırları hâlâ kayıyor.

### Open questions

- `activity_main.xml`'deki bağlantı ekranı düğmeleri (ör. Bağlan) bu kartın `files:` kapsamı dışında; hâlâ sistem temasını kullanıyorlar. Aynı sorun varsa ayrı kart gerekir.
