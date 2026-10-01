---
id: T-084
title: Deney — SurfaceControl/ASurfaceControl ile doğrudan sunum (HarmonyOS'ta compositor gecikmesi)
status: todo
phase: 5
owner: orchestrator
depends_on: [T-071]
decisions: []
files:
  - docs/NOTES.md
  - backlog/tasks/
---

## Amaç

Bugün MediaCodec çıktısı `releaseOutputBuffer(idx, ts)` ile SurfaceView'a gidiyor; sunum zamanlaması SurfaceFlinger'ın kuyruk/mandal davranışına bağlı (son an 6 ms ampirik). API 29+ `SurfaceControl.Transaction.setBuffer/desiredPresentTime` (ya da NDK `ASurfaceTransaction`) daha doğrudan sunum ve gerçek sunum geri bildirimi verebilir. HarmonyOS 4.3 (API 31) desteği bilinmiyor.

## Plan (orkestratör)

1. Cihazda API kullanılabilirliğini küçük bir deneme APK'sı/anahtarla doğrula (deneme `--es present sc`).
2. Kazanç ölçümü: hazır→ekran (SF `--latency` gerçek sunum) ve tekrar oranı; çizimde A/B.
3. Karmaşıklık yüksekse ve kazanç < ~3 ms ise bırak.
