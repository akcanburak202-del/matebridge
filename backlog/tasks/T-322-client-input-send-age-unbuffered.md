---
id: T-322
title: Tablet — girdi gönderim yaşı istatistiği (EN1) ve parmak/trackpad/fare için tamponsuz dağıtım anahtarı (EN3)
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/input/
  - client-android/app/src/main/kotlin/dev/matebridge/client/session/
  - client-android/app/src/main/kotlin/dev/matebridge/client/MainActivity.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/
  - backlog/tasks/T-322-client-input-send-age-unbuffered.md
---

## Amaç

T-298 `docs/reviews/2026-10-08/agents/opt-c-e2e.md` EN1 ve EN3. Wi-Fi'de host `input_age` p50: işaretçi 16,4 ms, tuş 12,8 ms. RTT ~5 ms çıkarılınca 8–10 ms tablet ya da host'ta. Trackpad yaşı p50 15,4 ms (2026-10-08). Tamponsuz dağıtım bugün yalnız kalemde (`UnbufferedPenDispatch`).

## Kabul

1. **EN1:** `MB/input ev=stats` satırına sınıf başına (kalem, işaretçi, tuş, kaydırma) `send_age_ms_p50/p95/max` eklenir: soket yazımının döndüğü an − `eventTime`, tablet saatiyle. Yalnız sayı ve süre; koordinat ya da karakter yok. Önerilen LOGGING metni Handoff'a.
2. **EN3:** `--es unbuffered_src off|touch|all` (varsayılan `off`, `--ez dev true` arkasında).
   - `touch`: `SOURCE_TOUCHSCREEN` için `requestUnbufferedDispatch`.
   - `all`: ek olarak `SOURCE_MOUSE | SOURCE_TOUCHPAD` (ve pointer capture'daki göreli kaynak).
   - Kalem davranışı değişmez. Etkin kaynaklar `ev=unbuffered` logunda görünür.
3. **Girdi güvenliği:** bırakma yolları ve `SendQueue` birleştirme (`POINTER_REL` coalescing) değişmez. Olay sayısı artarsa kuyruk sınırlı kalır; testle göster.
4. **Testler:** yaş istatistiği (yüzdelikler, sınıf ayrımı), anahtar ayrıştırma ve kaynak maskesi.
5. **Cihaz A/B (orkestratör):** trackpad 30 sn `off` / `all`, host `input_age pointer_p50` ve yeni `send_age`.

## Plan

## Handoff

## Open questions
