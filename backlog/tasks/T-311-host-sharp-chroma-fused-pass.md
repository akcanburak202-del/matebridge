---
id: T-311
title: Host — Keskin renk Metal geçişi tek dispatch (HA2), Metal süresi ayrı iz aşaması (HA1), iki Metal geçişinin ortak kurulumu (A8)
status: todo
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

## Handoff

## Open questions
