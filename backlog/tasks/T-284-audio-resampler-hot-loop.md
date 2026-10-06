---
id: T-284
title: İstemci — ses örnekleyici sıcak döngüsü (roundToInt yorumlayıcıda; ses çalarken mb-audio %35–39)
status: review
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

1. `CubicResampler.process`: `roundToInt().coerceIn()` yerine satır içi (`internal inline fun toS16`) yuvarlama + kırpma. `Math.round(float)` ile bit bit aynı olması için `y + 0.5f` kullanılmaz (float'ta 0.49999997f + 0.5f = 1.0f hatası); `t = y.toInt()`, `d = y - t` (tam), yarım yukarı kuralı `d` ile karşılaştırılır. Kırpma önce: `y >= 32766.5f` -> 32767, `y < -32768.5f` -> -32768.
2. `PlayoutCore.render` incelendi: örnek başına stdlib çağrısı yok (yalnız burst başına `minOf`/`synchronized`); `AudioRamp.apply` da temiz. Dokunulmadı.
3. Test `CubicResamplerRoundingTest`: `toS16` vs eski formül (yarım sınırlar, ulp komşuları, +-Inf, 10^6 rastgele) ve `process` vs eski sürüm kopyası (4 adım oranı, 4x10^5 çıkış karesi x 2 kanal, uç değerli girdi): sıfır fark.

## Handoff

- Commit: `git log task/T-284-audio-resampler-hot-loop` (T-284 commit'i).
- Dosyalar: `client-android/app/src/main/kotlin/dev/matebridge/client/audio/CubicResampler.kt`, `client-android/app/src/test/kotlin/dev/matebridge/client/audio/CubicResamplerRoundingTest.kt`, bu kart. `PlayoutCore.kt` değişmedi (örnek başına stdlib çağrısı yok).
- `./scripts/check.sh`: ALL OK (yeni test 3/3 geçti, mevcut `CubicResamplerTest` dahil hepsi geçti).
- Varsayımlar: `Math.round(float)` anlamı (yarım yukarı, tam hesap) `roundToInt` ile aynı; NaN artık atmaz, 0 döner (girdiler sonlu s16, NaN üretilemez). `process` içinde kalan `System.arraycopy(w, ...)` (6 float, ~48 000/s) ve `floor` (burst başına) bilerek bırakıldı; profilde görünmüyordu.
- Test EDİLMEDİ (cihaz): kabul 4. Tabletle 60 sn simpleperf, hedef `mb-audio` <= %10 tek çekirdek; `roundToInt`/`artQuickToInterpreterBridge` < %5. Hâlâ yorumlayıcıdaysa `process` kendisi JIT'lenmiyor demektir (debuggable çalışma zamanı tahmini); bu durumda sıradaki aday `System.arraycopy` ve `process`'in tek büyük metot oluşu.

## Open questions
