---
id: T-345
title: İstemci — CURSOR_STATE `rel_ack_time_us` ile tahmin (geri sıçrama yok)
status: todo
phase: 7
owner: android-client-dev
depends_on: []
decisions: [0036]
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/
  - client-android/app/src/test/
  - backlog/tasks/T-345-client-cursor-rel-ack.md
---

## Amaç

Karar 0036 v3 eki; PROTOCOL.md §4 CURSOR_STATE "Onay grubu". Dal tabanı: `task/0036-cursor-ack-integration`.

## Kapsam

1. **Çözme:** `CURSOR_STATE` 22 bayt (grup yok) ya da ≥30 bayt (`rel_ack_time_us`). 23–29 bayt protokol hatası. Fixture testleri: `cursor_state_ack`, `invalid_cursor_state_ack_partial`.
2. **Tahmin:** `CursorPredictor` halkası her deltanın gönderildiği `POINTER_REL.time_us` değerini de tutar (birleştirilen mesajlarda gönderilen değer).
   - Onaylı durum gelince delta `time_us ≤ rel_ack_time_us` ise durumun içinde sayılır, değilse üstüne eklenir. Saat farkı ve tek yön tahmini bu karar için kullanılmaz.
   - T-343 yerleşme süresi yalnız onaylanmayan ama host'un yok saydığı deltalar için yedek kalır.
   - Grup yoksa (eski host) bugünkü davranış bit bit aynı.
3. **Ölçüm:** `cursor_stats` `pred_err`/`hold_err` tanımı aynı kalır; ek bir sayaç `ack_n` (onaylı durum sayısı) eklenebilir (LOGGING.md'ye uygun).
4. **Değişmeyenler:** gönderilen mesajlar, girdi yolu, askıya alma kuralları.

## Kabul

- Birim testleri:
  - fixture'lar;
  - benzetim: RTT 40 ms, titreşim 40–100 ms, ev Wi-Fi'ı 15 ms + ara ara 60 ms sıçrama. Onaylı durumlarla çizilen imlecin geri sıçraması ≤ 1 pt, `pred_err` p95 ≈ 0.
  - onaysız (eski host) yolun çıktısı değişmemiş.
- `./scripts/check.sh` geçer. Swift fixture kapsamı T-344 birleşene kadar düşebilir; handoff'ta yaz.
- Cihaz testi orkestratörde.

## Plan

## Handoff

## Açık sorular
