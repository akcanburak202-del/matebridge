---
id: T-320
title: Fling boost'u benimseme — pil ve ısı bedeli, skip_pct etkisi, hangi modlarda açık (karar + kullanıcı onayı)
status: todo
phase: 7
owner: orchestrator
depends_on: [T-319]
decisions: []
files:
  - docs/research/2026-10-08-ddr-clock.md
  - docs/decisions/
  - docs/NOTES.md
  - backlog/tasks/T-320-fling-boost-adoption.md
---

## Amaç

T-319 cihaz sonucu: görünmez `OverScroller.fling` (1 sn) dokunmasız DDR'ı 1536 MHz'e, GPU'yu 404 MHz'e çıkarıyor. 60 fps'te çözme −3,7 ms, `cap_dec` −5 ms, tablet işlemci süresi yarıdan az.

Benimsemeden önce:
1. **Pil ve ısı:** aynı sahne, şarjsız, sabit parlaklık, `fling` açık ve kapalı ×15 dk (`Charge counter`, `temperature`).
2. **`skip_pct`:** fling kolları dalgalıydı. Pace trace ile 3 dk ×2; çözme hızlanınca zamanlayıcı fazı mı kayıyor?
3. **Kapsam önerisi:** Oyun modunda açık (gamepad, düşük gecikme). Günlük/Çizim'de kapalı, ya da panelde bir anahtar. Dokunma zaten yükseltiyor; Çizim'de gerek yok.
4. **Karar kaydı ve kullanıcı onayı:** genel API ama güç davranışını değiştiriyor.

## Plan

## Handoff

## Open questions

## Not (2026-10-10, T-330)

C1 önerisi (`docs/research/2026-10-10-optimization.md`):
- Fling 2–3 sn aralıkla atılsın; DDR tutma süresi ölçülsün.
- Uyarlamalı olsun: yalnız `dec_p50 > ~13 ms` ya da `skip_pct` yüksekken açık, Çizim 120'de ve dokunmada kapalı.
- Bluetooth trackpad/fare girdisinin DDR'ı yükseltip yükseltmediği ölçülsün.
- Pil kolu T-332 ile birlikte koşabilir.
