---
id: T-241
title: Client — "Keskin renk kenarları" panel toggle and STREAM_PREFS.chroma (decision 0033)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-238]
decisions: [0033]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/protocol/
  - client-android/app/src/main/kotlin/dev/matebridge/client/stream/
  - client-android/app/src/main/kotlin/dev/matebridge/client/settings/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - docs/LOGGING.md
  - backlog/tasks/T-241-client-chroma-pref.md
---

## Amaç

Decision 0033'ün istemci tarafı. Protokol ve fixture'lar `task/T-239-chroma-protocol` dalında; **bu dalın üzerine kur** (`git checkout -b task/T-241-client-chroma task/T-239-chroma-protocol`). Protokolü değiştirme.

## Bağlam

- Codec: grup `reserved` → `chroma`; yazma kuralı `dynamic_range ≠ 0 || chroma ≠ 0`; fixture'lar (`stream_prefs_sharp_chroma` yeni, `stream_prefs_hdr` alan adı).
- Panel: Görüntü bölümünde "Keskin renk kenarları" (Kapalı/Açık), varsayılan Kapalı, kalıcı (prefs), bütün modlarda; HDR10 uygulanırken (`STREAM_CONFIG.transfer == 16`) gri ve "(HDR açıkken etkisiz)" notu. "Varsayılanlara dön" kapatır. Değişince `STREAM_PREFS` yeniden gönderilir (T-238'in `GameModeSettings.prefs(mode)` yolu).
- Log: `ev=profile`'a `chroma=0|1`.

## Kabul kriterleri

- [ ] [JVM] Fixture'lar; prefs → `chroma` alanı ve grup yazma kuralı (yalnız chroma=1 iken 14 bayt, ikisi 0 iken 8/12 bayt aynı).
- [ ] [JVM] Panel satırı (görünürlük, HDR'de gri, reset).
- [ ] `./scripts/check.sh` istemci kısmı geçer (host fixture testi T-240'ta).

## Plan

_(Ajan kodlamadan önce doldurur.)_

## Handoff

_(Ajan bitirince doldurur.)_
