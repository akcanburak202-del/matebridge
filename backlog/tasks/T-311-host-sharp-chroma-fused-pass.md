---
id: T-311
title: Host — Keskin renk Metal geçişi tek dispatch (HA2), Metal süresi ayrı iz aşaması (HA1), iki Metal geçişinin ortak kurulumu (A8)
status: done
phase: 7
owner: mac-host-dev
depends_on: [T-302]
decisions: [0033]
files:
  - host-mac/Sources/MateBridgeHost/Video/ChromaConverter.swift
  - host-mac/Sources/MateBridgeHost/Video/PackedChromaPacker.swift
  - host-mac/Sources/MateBridgeHost/Video/HEVCEncoder.swift
  - host-mac/Sources/MateBridgeCore/Video/
  - host-mac/Tests/MateBridgeCoreTests/Video/
  - backlog/tasks/T-311-host-sharp-chroma-fused-pass.md
---

## Amaç

T-298 HA1/HA2 (`docs/reviews/2026-10-08/agents/opt-a-host.md`) ve T-297 A8 (`docs/reviews/2026-10-08/agents/simp-a-host-video.md`). Kullanımın %87'si `sharp_nearest` modunda.
- Bu modda `hold`/`gate_wait` p50 ~3 ms görünüyor; bu aslında Metal geçişi (`chroma_stats conv_ms` p50 3,15–3,21 ms, GPU 2,73 ms).
- Geçiş iki compute encoder kullanıyor ve kaynağı iki kez okuyor. LUT `device` belleğinde, `reach()` piksel başına 6–10 `rebuilt()` çağırıyor.

## Kabul

1. **HA1:** `FrameTrace`'e `convertedUs` ve `ev=latency`'ye `gpu` (ya da `convert`) aşaması eklenir; `gate_wait` artık Metal'i içermez. `latency.csv`'ye `convert`, `bytes` ve `key` sütunları eklenir. Önerilen LOGGING metni Handoff'a.
2. **HA2:** `sharp_nearest` için tek dispatch: her 2×2 blok için bir iş parçacığı, 4 pikseli bir kez okur, CbCr yazar, 4 luma araması yapar. Ara bariyer yok, chroma geri okuma yok.
   - EOTF LUT `constant` adres uzayında.
   - `mathMode = .safe` kalır. **CPU referansına göre bit-exact testler (`SharpYUVTests`) geçer.**
   - Eşzamanlı `waitUntilCompleted` kalır (sıralama).
3. **A8:** ChromaConverter ile PackedChromaPacker'ın ortak Metal kurulumu (cihaz, kuyruk, derleme, havuz, doku, zamanlama, etiket) tek yardımcıya taşınır. Paketli tam renk yolunun çıktısı değişmez (`PackedChromaLayoutTests`).
4. **Ölçüm (Handoff):** mümkünse `--sharpness-bench` ya da `EncodeBench` ile GPU süresi önce/sonra. Pencere açmayan ve sanal ekran gerektirmeyen bir yol yoksa orkestratör cihazda ölçer (`chroma_stats gpu_ms/conv_ms`, yeni `gpu` aşaması).
5. Protokol değişmez.

## Plan

1. `sharp_fused` (SharpYUVKernel): bir iş parçacığı = bir 2x2 blok; 4 pikseli bir kez okur, CbCr yazar, 4 luma kodunu aynı iş parçacığında hesaplar; LUT `constant`. Eski iki kernel kaynağı testlere (`LegacyTwoPassKernel`) referans olarak taşınır; bit-exact eşitlik testi.
2. A8: `MetalShared` (cihaz + kuyruk + derleme) ve `MetalPassSupport` (doku önbelleği, havuz, doku sarma, zamanlı senkron dispatch, etiketler) ChromaConverter.swift'te; ChromaConverter ve PackedChromaPacker bunları kullanır.
3. HA1: `FrameTrace.convertedUs` (Metal geçişinin duvar süresi), `ev=latency` `gpu` aşaması, `gate_wait` = hold - slot_wait - gpu; latency.csv'ye `convert_us,bytes,key`.

## Handoff

- **Commit:** `git log task/T-311-fused-chroma -1`.
- **Dosyalar:** `Core/Video/SharpYUVKernel.swift`, `Core/Video/LatencyTrace.swift`, `Host/Video/ChromaConverter.swift`, `Host/Video/PackedChromaPacker.swift`, `Host/Video/HEVCEncoder.swift` (yalnız Metal süresini trace'e taşıma); testler: `SharpYUVTests.swift`, `LegacyTwoPassKernel.swift` (yeni, eski kernel kaynağı), `LatencyTraceTests.swift`.
- **HA2:** tek dispatch (`sharp_fused`), tek komut tamponu/tek encoder, ara bariyer ve chroma geri okuma yok, LUT `constant`, `mathMode = .safe` aynı, eşzamanlı `waitUntilCompleted` aynı. `testFusedKernelIsBitExactWithTwoPassKernels`: eski iki geçişli kernel ile **bayt bayt aynı** (Y ve CbCr; çift/tek boyutlar 1x1..256x144, gürültü + ikon/doygunluk köşeleri, plain ve nearest). CPU referansından sapma eskisiyle aynı (testte max 0; sınır ≤1 korundu). Paketli yolun testleri değişmeden geçer.
- **Ölçüm (pencere yok, sanal ekran yok; `testBenchFusedVersusTwoPass`, 2800x1840, GPU süresi medyanı, bu Mac):** masaüstü benzeri içerik iki geçiş 780 us -> fused 665 us (-%15); tam gürültü (en kötü) 1550 us -> 1395 us (-%10). Cihazdaki ~2,7 ms GPU bu sentetik içerikten çok daha ağır (gerçek IOSurface, saat/yük, gerçek içerik); kazanç mütevazı: ağırlık luma aramasında, bariyer/okuma tasarrufu küçük. Gerçek `chroma_stats gpu_ms/conv_ms` önce/sonra karşılaştırmasını orkestratör cihazda yapmalı.
- **HA1:** `FrameTrace.convertedUs` (Metal geçişi duvar süresi; paketli yolda paketleyici süresi), `LatencyWindow.stageNames` içinde `gate_wait`'ten sonra `gpu`; `gate_wait = hold - slot_wait - gpu` (hold değişmez, Metal'i içerir). `latency.csv` sonuna `convert_us,bytes,key`.
- **Önerilen LOGGING.md metni (ben dokunmadım):** "`ev=latency`: aşamalar `sck_lag, hold, gate_wait, gpu, slot_wait, enc, conv, queue, write, cap_to_sent`. `gpu`: kodlayıcıya göndermeden önceki Metal geçişinin (keskin renk dönüşümü ya da paketleyici) duvar süresi; `hold = gate_wait + gpu + slot_wait`. `420`/`444` modlarında geçiş yoktur, `gpu` 0. `latency.csv`: son üç sütun `convert_us` (aynı süre, µs), `bytes` (VIDEO_FRAME yükü), `key` (1 = anahtar kare); ilk 13 sütun aynı sırada."
- **A8:** ortak kurulum `MetalShared` + `MetalPassSupport`; iki geçiş artık tek cihaz/kuyruk paylaşır (önceden ayrı `MTLCreateSystemDefaultDevice`/kuyruk). Hata türü `MetalSetupError` (`ChromaKernels.SetupError` typealias olarak kaldı).
- **Varsayım:** geçişler aynı iş parçacığından sıralı çağrılır (mevcut sözleşme), tek kuyruk paylaşımı bunu bozmaz.
- **Cihazda doğrulanacak:** gerçek `conv_ms/gpu_ms` p50 (önce 3,15-3,21 / 2,73 ms); `ev=latency gpu` aşaması `hold`'a yakın, `gate_wait` ~0; görüntüde fark yok (bit-exact); paketli tam renk yolu çıktısı. `ev=latency` anahtar sırası değişti (`gpu` eklendi): bunu ayrıştıran dış betik varsa güncellenmeli.
- **Test edilmedi:** gerçek tablet; HEVCEncoder canlı hattı (trace alanı yalnız yazılır); uygulama çalıştırılmadı.

## Open questions
