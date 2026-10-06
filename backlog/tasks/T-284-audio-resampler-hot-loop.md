---
id: T-284
title: İstemci — ses örnekleyici sıcak döngüsü (roundToInt yorumlayıcıda; ses çalarken mb-audio %35–39)
status: todo
phase: 6
owner: android-client-dev
depends_on: [T-282]
decisions: []
files:
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/CubicResampler.kt
  - client-android/app/src/main/kotlin/dev/matebridge/client/audio/PlayoutCore.kt
  - client-android/app/src/test/kotlin/dev/matebridge/client/audio/
  - backlog/tasks/T-284-audio-resampler-hot-loop.md
---

## Amaç

T-282 ölçümü (`docs/research/2026-10-07-perf-profile.md` §Sıcak noktalar 1): ses çalarken `mb-audio` tek çekirdeğin %34–39'u. Örneklerin %93'ü `CubicResampler.process`, bunun %51'i `kotlin.math.roundToInt` (örnek × kanal başına, 96 000/s). Yığın JIT kodundan yorumlayıcıya düşüyor (`artQuickToInterpreterBridge`, `MterpInvokeStatic`). Protokol değişmez.

## Kabul

1. `process` iç döngüsünde stdlib yardımcı çağrısı (`roundToInt`, `coerceIn`) kalmaz. Yuvarlama ve kırpma satır içi yazılır. Çıktı **bit bit aynı**: `roundToInt` = `Math.round(float)` (yarım yukarı, `floor(x + 0.5)`). Mevcut `CubicResamplerTest` geçer. Yeni test eski formülle karşılaştırır: rastgele ve uç girişler (±32768 civarı, .5 sınırları), en az 10⁵ örnek, sıfır fark.
2. `PlayoutCore.render` içinde örnek başına çağrılan başka stdlib yardımcısı varsa aynı şekilde ele alınır. Profilde görünmeyene dokunulmaz.
3. Gerçek zamanlı yolda ayırma, kilit, log yok (mevcut kural).
4. Cihaz ölçümü (orkestratör yapar, kullanıcı sesli video açar): T-282 yöntemiyle 60 sn. Hedef `mb-audio` ≤ %10 tek çekirdek; simpleperf'te `roundToInt`/`artQuickToInterpreterBridge` `mb-audio` örneklerinin %5'inin altında. Hedef tutmazsa nedeni (hangi çağrı hâlâ yorumlayıcıda) Handoff'a yazılır.

## Plan

## Handoff

## Open questions
