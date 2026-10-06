---
id: T-289
title: Host — HDR çalışma anı kodlayıcı hatasında SDR'ye düş; pipeline yeniden denemesi tek seferlik kalmasın
status: todo
phase: 6
owner: mac-host-dev
depends_on: []
decisions: [0032]
files:
  - host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift
  - host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-289-hdr-runtime-sdr-fallback.md
---

## Amaç

Astra incelemesi 2026-10-07, bulgu 3 (`docs/reviews/2026-10-07/astra-review.md`). Main10 başarıyla kurulduktan sonra kodlayıcı üst üste `failureLimit` kez hata verirse `onPipelineFailed` aynı HDR ayarlarıyla **bir kez** yeniden kuruyor (`pipelineRetried`). SDR'ye düşme (`fallBackFromHDR`) yalnız başlatmadaki `HDRSetupError` ile çalışıyor; PROTOCOL.md 0x05 ise SDR'ye düşmeyi vaat ediyor. Ayrıca ikinci bir hatadan sonra oturum boyunca yeniden deneme yok. Cihazda görülmedi.

## Kabul

1. Hata, olayda türüyle taşınır; `"\(error)"` metni yetmez. HDR pipeline'ında çalışma anı kodlayıcı hatası olursa önce bir kez aynı ayarlarla yeniden denenir. O da sınırlı süre içinde yine düşerse mevcut `fallBackFromHDR` akışıyla SDR'ye geçilir: yeni `config_id`, `STREAM_CONFIG`, `hdr_fallback` logu.
2. `pipelineRetried` mantığı oturum başına tek seferlik olmaktan çıkar ve sınırlı bir politikaya döner (saf, test edilebilir; ör. pencere başına N deneme ve geri çekilme). Sonsuz döngü olmaz.
3. T-200 (ekranı medya hatasında koruma) ile çakışma: bu kart ekran ömrünü değiştirmez. Ekran sahipliği mevcut haliyle kalır.
4. Birim testleri politika ve sınıflandırma üzerinde yazılır. Cihazda tetiklenemiyorsa Handoff'ta "test edilmedi" yazılır.
5. Birleştirme öncesi `./scripts/codex-review.sh main task/T-289-...` (orkestratör).

## Plan

## Handoff

## Open questions
