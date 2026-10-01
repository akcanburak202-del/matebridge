---
id: T-083
title: Araştırma — Mac yakalama fazını tablet vsync'ine hizalamak (ortalama ~4 ms bekleme kazancı)
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

Mac sanal ekranı (CGVirtualDisplay, 120 Hz) ile tablet paneli bağımsız saatlerle tıklıyor; kare tablete panel vsync'ine göre rastgele fazda varıyor → hazır→slot beklemesi ortalama ~yarım periyot fazla (120 Hz'te ~4 ms). Ayrıca 2026-10-01 bulgusu: SCK PTS/`displayTime` geri çağrıdan 6,6 ms ileride.

## Plan (orkestratör)

1. Kare izinden (`tools/pacing`, trace7/trace8) hazır zamanının panel vsync'ine göre fazını ve bunun hazır→slot beklemesine katkısını ölç.
2. Mac tarafında yakalama zamanını kaydırmanın yolu var mı: CGVirtualDisplay yenileme/faz ayarı, SCK `minimumFrameInterval`, içerik güdümlü yakalamada kodlamayı geciktirip tablet vsync'ine göre göndermek (host'un tablet vsync fazını bilmesi gerekir → protokol: tablet faz bildirimi). Kazanç ve karmaşıklığı karşılaştır, karar kaydı gerekirse yaz.
3. Saat kayması (120 Hz) açık konusu da burada.
