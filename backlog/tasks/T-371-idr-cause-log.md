---
id: T-371
title: Host — her zorunlu IDR için neden günlüğü (ev=idr_forced cause=...)
status: review
phase: 7
owner: mac-host-dev
depends_on: [T-369]
decisions: []
files:
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeCore/Video/KeyframeRequestCoalescer.swift
  - host-mac/Sources/MateBridgeCore/Video/VideoSender.swift
  - host-mac/Tests/MateBridgeCoreTests/
  - docs/LOGGING.md
  - tools/measure/mblog.py
  - tools/measure/game_ab.py
  - tools/measure/selftest.sh
  - tools/measure/testdata/
  - backlog/tasks/T-371-idr-cause-log.md
---

## Amaç

`docs/research/2026-10-23-forced-idr-chain.md` §5 madde 2. Bugün host kaynaklı IDR yalnız `net ev=stats idr=` sayısı olarak görünüyor; T-370 A/B'sinde hangi IDR'nin neden çıktığı ayırt edilemiyor.

## Kabul

1. Host her IDR zorlamasında (gerçekten kodlayıcıya `ForceKeyFrame` giden karar; birleştirilen/bastırılan istekler ayrı sayılır) tek satır: `video ev=idr_forced view=main|aux cause=queue_overflow|transport_refused|client_request|periodic|consumer|other` ve mümkünse `since_last_ms=`. Saniyede çok IDR'de log seli olmasın: saniyelik özet satırı (`ev=idr_causes queue_overflow=N ...`) veya hız sınırı; seçim Plan'da gerekçelenir.
2. Davranış değişmez (yalnız gözlem). Birim test: her yol doğru `cause` üretir.
3. `mblog.py` izin listesi yeni satırı tanır (sıkı desen); `game_ab.py` olay penceresi ve kol özetinde IDR'leri nedene göre sayar; selftest sentetik veriyle.
4. LOGGING.md güncel.
5. `./scripts/check.sh` geçer. Çalışan uygulamaya dokunma, Mac'te pencere açma, cihaz testi yok.

## Plan

- Neden kaydı `KeyframeRequestCoalescer` içinde (saf, test edilebilir): her zorlama yolu (`request`, `internalForce(cause:)`, `evaluateHost`, `reset`) ve zorlanmamış keyframe yazımı (`periodic`) `recordForce` çağırır. Böylece her yol birim testle doğrulanır ve çağıran tarafta cause atlanamaz.
- `KeyframeGate` (VideoPipeline) kilidi bıraktıktan sonra notları `video ev=idr_forced` olarak yazar; akış başına 10 satır/sn sınırı.
- Günlük seli: koalesör zaten ~3 IDR/sn ile sınırlı, ama güvenlik için satır hız sınırı + kesin sayılar stats satırında `idr_cause_*` (satır sınırından bağımsız). Ayrı `ev=idr_causes` satırı yok: `StreamCoordinator` dosya listesinde değil; sayaçlar mevcut `takeKeyframeWindow()` üzerinden stats satırına biner.
- Bastırılanlar: `idr_coalesced` (istemci), `idr_deferred` (kuyruk düşüşü ertelendi).
- Araçlar: mblog izin listesi + `cause` kalıbı, game_ab kol/olay sayımı, selftest sentetik veri.

## Handoff

- Commit: tek commit `T-371: IDR cause log ...` on `task/T-371-idr-cause-log` (SHA: son mesajda / `git log`).
- Dosyalar: `KeyframeRequestCoalescer.swift` (IdrCause, ForceNote, CauseWindow, StatsWindow, recordForce), `VideoPipeline.swift` (KeyframeGate loglar, `internalForce(cause: .transportRefused)`, `takeKeyframeWindow()` artık `StatsWindow` döner; `StreamCoordinator` yalnız `.logFields` kullandığı için değişmedi), `IdrCauseTests.swift` (11 test), `LOGGING.md`, `mblog.py`, `game_ab.py`, `selftest.sh`, testdata.
- Varsayımlar: `periodic` = kimsenin zorlamadığı keyframe yazımı (300 sn güvenlik aralığı ya da kodlayıcı başlangıcında pending'siz ilk IDR); gerçek bir host kararı değil, yazım anında sayılır. Yardımcı akışın stats satırı yok, onun zorlamaları yalnız `idr_forced view=aux` satırlarında. Ayrı `ev=idr_causes` satırı yok (gerekçe Plan'da).
- check.sh: swift build/test OK, protokol/crypto/selftest OK. Android gradle adımı kırmızı: DecoderWaitTest, OutputParkTest, AacDecodeWorkerTest (4 test) = bilinen T-367 zamanlama kırılganlığı, bu görevin dosyalarıyla ilgisiz.
- Gerçek donanımda doğrulanmadı: canlı hostta satırların görünmesi, stall-inject altında neden dağılımı (T-370 A/B ile birlikte). Çalışan uygulamaya dokunulmadı.

## Open questions
