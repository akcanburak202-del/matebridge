---
id: T-107
title: Tablet — ayar panelinde seçili olmayan seçenekler beyaz kutu, yazı görünmüyor
status: todo
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

- [ ] Paneldeki bütün düğmelerin (seçenek, aç/kapa, eylem, −/+) arka plan ve metin rengi açıkça verilir; sistem temasına bırakılmaz.
  - Seçili olmayan: koyu gri zemin (örn. `#3A3A42`), beyaz metin.
  - Seçili: mavi (`SELECTED_COLOR`), beyaz, kalın.
  - Basılı durumda görünür bir geri bildirim olur.
- [ ] İki panel de aynı stili kullanır (bağlantı paneli ve yan panel; ikisi de `SettingsViews`).
- [ ] Bağlantı panelinin arka planı açık renkse kontrast yine yeterlidir; gerekirse panel zemini de koyu yapılır.
- [ ] `./scripts/check.sh` geçiyor. Görsel kontrol orkestratörde, cihazda.

## Plan

(ajan doldurur)

## Handoff
