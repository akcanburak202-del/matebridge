---
id: T-289
title: Host — HDR çalışma anı kodlayıcı hatasında SDR'ye düş; pipeline yeniden denemesi tek seferlik kalmasın
status: review
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

1. Core: `PipelineFailureKind` (`encoder` / `other`) ve saf `PipelineRetryPolicy` (`failed(kind:hdr10:nowUs:) -> retry | fallBackToSDR | giveUp`). Kayan 60 s pencere, pencerede en fazla 3 yeniden kurma, geri çekilme 1/2/4 s; HDR10 + encoder hatası pencerede ikinci kez olursa SDR'ye düşme (sonra bütçe sıfırlanır). Pencere dolunca bütçe yenilenir; oturum başında `reset()`.
2. Host: `VideoPipeline.failureKind(_:)` hatayı türüyle sınıflar (`VideoEncoderError` = encoder); `.pipelineFailed` olayı `kind` taşır, `pipeline_failed` logu `kind=` yazar.
3. `StreamCoordinator`: `pipelineRetried` kalkar, `retryPolicy` gelir. `onPipelineFailed` politikaya göre ya aynı ayarlarla (backoff sonrası) ya SDR ayarlarıyla yeniden kurar ya da vazgeçer (`pipeline_retry_exhausted`). SDR yolu mevcut `fallBackFromHDR`'in duyuru yarısını (`announceHDRFallback`: yeni `config_id`, `STREAM_CONFIG`, `hdr_fallback`) paylaşır; ekran sahipliği ve T-200 davranışı değişmez.
4. Birim testleri politika üzerinde (`PipelineRetryPolicyTests`).

## Handoff

- Commit: bkz. `git log task/T-289-hdr-runtime-sdr-fallback` (tek commit, `T-289: ...`).
- Dosyalar: `host-mac/Sources/MateBridgeCore/Video/PipelineRetryPolicy.swift` (yeni), `host-mac/Tests/MateBridgeCoreTests/Video/PipelineRetryPolicyTests.swift` (yeni, 13 test), `host-mac/Sources/MateBridgeHost/Session/StreamCoordinator.swift`, `host-mac/Sources/MateBridgeHost/Video/VideoPipeline.swift`, bu kart.
- `./scripts/check.sh`: ALL OK.
- Davranış: çalışma anı hata `kind` ile taşınır (`encoder` = `VideoEncoderError.*`, diğer hepsi `other`). SDR pipeline'da ve HDR + `other` hatada: 60 s pencerede en fazla 3 yeniden kurma (1 s, 2 s, 4 s), sonra `pipeline_retry_exhausted` ve vazgeçme (istemci video yeniden bağlanınca `onVideoAttached` yine kurmayı dener; pencere dolunca bütçe yenilenir). HDR10 + encoder hatası: ilk hata aynı ayarlarla yeniden kurulur, pencerede ikincisi `hdr_fallback reason=encoder_rejected detail=runtime_encoder` + yeni `config_id` + `STREAM_CONFIG` ile SDR'ye düşer (HDR süreç boyunca kapanır, mevcut `HDRFallback` kuralı). Oturum başında bütçe sıfırlanır (eski `pipelineRetried = false` yerine).
- Varsayımlar: pencere/üst sınır/backoff sabitleri benim seçimim (60 s, 3, 1-2-4 s); `PipelineRetryPolicy` içinde tek yerde. Yalnız encoder hatası SDR'ye düşürür; HDR yakalama (`other`) çalışma anı hataları aynı ayarlarla yeniden denenir (kartın kapsamı encoder). Yeni log olayları (`pipeline_retry_scheduled`, `pipeline_retry_exhausted`, `pipeline_failed kind=`) `docs/LOGGING.md`'ye eklenmedi, çünkü dosya kartın `files:` listesinde değil; orkestratör eklemeli.
- Test edilmedi: cihazda HDR encoder hatası tetiklenemedi; `StreamCoordinator` akışı (backoff uykusu, SDR yeniden kurma, `config_id` yeniden duyurusu, tabletin yeni STREAM_CONFIG'i alıp video bağlantısını yenilemesi) yalnız derlendi, birim testi yok (Host hedefinde test yok). Gerçek donanımda doğrulanacak: HDR akarken kodlayıcıyı iki kez düşürmek tabletin SDR'ye geçtiğini göstermeli.
- Codex incelemesi düzeltmeleri (ikinci commit): (1) `giveUp` sonrası tabletin kendiliğinden video yeniden bağlanması artık bütçeyi aşmaz: `PipelineRetryPolicy.nextAllowedUs(nowUs:)` (pencerede en fazla 3 başarısızlık kalana kadar bekleme, yani en eski başarısızlığın pencereden çıkışı). `onVideoAttached` pipeline yokken ve bütçe doluyken bağlantıyı tutar (iptal etmez; tablet döngüye girmez), `pipeline_rebuild_deferred wait_ms=` bir kez loglar ve süre dolunca `.rebuildDue(token:)` olayıyla `onVideoAttached`'i yeniden çalıştırır. Oturum bitişi, yeni oturum, kapanış veya pipeline'ın zaten var olması ertelemeyi iptal eder (bağlantı kapatılır); yeni gelen bağlantı tutulanı değiştirir. Kalıcı ölü video yok. (2) Başarısızlık geçmişi artık `hdr10` tutar; yalnız önceki HDR10 encoder hataları SDR'ye düşmeye sayılır (SDR encoder hatası + HDR hatası dizisi ilk HDR yeniden denemesini atlamaz; testli). Yeni testler: `PipelineRetryPolicyTests` (19 test). Ertelenen yeniden kurma akışı (zamanlayıcı, tutulan bağlantı) cihazda/koordinatörde test edilmedi.
- Birleştirme öncesi: `./scripts/codex-review.sh main task/T-289-hdr-runtime-sdr-fallback` (orkestratör).

## Open questions
