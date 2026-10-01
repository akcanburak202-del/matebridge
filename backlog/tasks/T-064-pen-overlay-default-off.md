---
id: T-064
title: Yerel kalem izi/noktası varsayılan kapalı
status: review
phase: 5
owner: android-client-dev
depends_on: [T-056]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/Settings.kt
  - client-android/app/src/test/
  - backlog/tasks/T-064-pen-overlay-default-off.md
---

## Amaç

Kullanıcı (2026-10-01 sabah): Krita'da çizim akıcı, yerel kalem izi gereksiz. Kalem izi (`penTrail`) ve kalem noktası (`penDot`) **varsayılan kapalı** olsun; bağlantı panelindeki anahtarlarla açılabilir kalır.

## Kabul kriterleri

- [x] `Settings.penTrail()` / `penDot()`: kayıtlı değer yoksa `false` (yalnızca `"1"` açık). Kayıtlı `"0"`/`"1"` aynen.
- [x] Test: varsayılan kapalı, açık/kapalı kalıcılığı.
- [x] `./scripts/check.sh` geçiyor.

## Plan

`!= "0"` → `== "1"`; KDoc güncellenir.

## Handoff

- **Commit:**
- **Dokunulan dosyalar:** Settings.kt, SessionSupportTest.kt, bu kart
- **Varsayımlar:** Kayıtlı "0" kullanıcılar kapalı kalır; kayıtlı "1" açık; kaydı olmayan (yeni/eski kurulum) artık kapalı.
- **Test edilmeyenler / cihazda doğrulanacaklar:** Temiz kurulumda kalem izi/noktası görünmüyor; bağlantı panelinden açılınca görünüyor.
- **Açık sorular:**
