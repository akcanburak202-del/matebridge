---
id: T-329
title: Review — gpt-6-astra (xhigh), T-283'ten (0ff7b86b) bu yana + riskli bölgeler
status: in_progress
phase: 7
owner: orchestrator
depends_on: [T-283]
decisions: []
files:
  - docs/reviews/
  - docs/NOTES.md
  - backlog/tasks/T-329-astra-xhigh-review.md
---

## Amaç

Kullanıcı onayı (2026-10-10 ~00:45): Codex `gpt-6-astra`, `model_reasoning_effort=xhigh`, salt okunur kod incelemesi, "özellikle incelenmesi gereken kısımlara". Önceki: `docs/reviews/2026-10-07/astra-review.md` (`0ff7b86b`). O günden beri ~11,6k satır eklendi (T-284..T-328).

## Kapsam

1. `0ff7b86b..7bf1765e` değişiklikleri, öncelik sırasıyla:
   - T-325 coordinator watchdog, sınırlı teardown, "girdi tutulmuyorsa yeniden başlat";
   - T-293 host breaker + T-294 istemci backoff/manual_resume;
   - T-327/T-328 Wi-Fi uyarlamalı bit hızı (knob kapalı ama kod yolu derleniyor), T-326 DSCP;
   - T-295 legacy/poll fallback kaldırma, T-299..T-313 sadeleştirme partileri (davranış kaybı?);
   - T-284/T-286/T-292 dec_wait event_in, aead direct; T-287 AAudio 60 sn pause; T-309 imleç örnekleyici; T-312/T-317 park;
   - T-288/T-289 düzeltmelerinin gerçekten kapandığı.
2. Değişmemiş olsa da yüksek maliyetli bölgeler: girdi durumu (takılı tuş/kalem), oturum/yeniden bağlanma/uyku-uyanma, sınırlı kuyruklar, `VirtualDisplay` sınırı, WebDAV/dosya güvenliği, kimlik doğrulama/AEAD.

## Kabul

1. `codex exec -m gpt-6-astra -s read-only -c 'model_reasoning_effort="xhigh"' -o <scratch>/astra-out.md`, özel istem (scratch `astra-prompt.txt`).
2. Çıktı aynen `docs/reviews/2026-10-10/astra-review.md`, üstüne orkestratör triyajı.
3. Her P1/P2 kod okunarak doğrulanır; gerçekse kart açılır.
4. Onay yalnız bu çalıştırmayı kapsar (başarısızsa bir kez yeniden).

## Plan

Kabul 1–3. Kullanıcı sabaha kadar yok; kod değişikliği yapılmaz, yalnız kartlar.

## Handoff

## Open questions
